// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeAccounting} from "./LPFeeAccounting.sol";

/// @title DarliLiquidityVault
/// @notice The canonical USDarli / quote pool's liquidity, in one Uniswap v4 position with a fixed range around par
///         (`docs/SPEC.md` D4, V6). Nobody manages it: the range, the pool and the reward token are fixed at construction
///         and a different range is a different vault. Holders' shares are liquidity units. Swap fees are collected into
///         the vault and shared per share in each token; reward tokens paid in are streamed over fixed weekly epochs; a
///         newcomer gets no part of earlier fees and a leaver keeps what he earned; principal is never mixed into the fee
///         books. No management or performance fee.
///         Payouts (V7): each token on its own, to a recipient the holder names. What the vault owes in the pool's two
///         tokens it keeps as ERC-6909 claims inside the PoolManager, never as token balances, and a payout moves the token
///         from the PoolManager straight to the recipient. A token that refuses a transfer to or from some address -- the
///         holder's, the recipient's, even the vault's own -- therefore blocks only payouts of that token to that
///         recipient: never a withdrawal of shares, never another token, never another holder.
/// @dev    Deposits are refused while the pool price is outside the vault's range. That keeps liquidity from entering
///         outside the band; it is not protection against a price pushed inside it. The protection is each depositor's own
///         price bounds and maximum amounts, as for any swap. The core never learns this contract's address (D3).
///         External calls: the PoolManager (unlock, modifyLiquidity, sync, settle, mint, burn, take, extsload), the two
///         pool tokens (a depositor's payment, straight to the PoolManager) and the reward token.
contract DarliLiquidityVault is LPFeeAccounting, IUnlockCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    uint160 private constant Q96 = 2 ** 96;

    IPoolManager public immutable poolManager;
    Currency public immutable currency0;
    Currency public immutable currency1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    uint160 public immutable sqrtPriceLower;
    uint160 public immutable sqrtPriceUpper;
    IERC20 public immutable rewardToken;

    /// principal withdrawn and not yet paid, per holder, in token0 and token1 (V7)
    mapping(address => uint256[2]) internal _principal;

    enum Action {
        Deposit,
        Withdraw,
        Collect,
        Pay
    }

    event Deposited(address indexed who, uint256 liquidity, uint256 amount0, uint256 amount1);
    event Withdrawn(address indexed who, uint256 liquidity, uint256 amount0, uint256 amount1);
    event FeesCollected(uint256 fee0, uint256 fee1);
    event Paid(address indexed who, uint256 indexed token, address to, uint256 principal, uint256 earned);
    event IncentivePaid(address indexed from, uint256 amount);

    error InvalidConfig();
    error NotPoolManager();
    error ZeroLiquidity();
    error PriceOutsideVaultRange(uint160 sqrtPriceX96);
    error PriceOutsideDepositorBounds(uint160 sqrtPriceX96);
    error AmountAboveMaximum(uint256 amount0, uint256 amount1);
    error AmountBelowMinimum(uint256 amount0, uint256 amount1);
    error NothingToCollect();
    error NoSuchToken(uint256 token);
    error ZeroRecipient();

    /// @param stable_ USDarli, at its predicted address
    /// @param halfWidthTicks the range: this many ticks either side of par, widened to the tick spacing (100 ticks is
    ///        about 1 %)
    constructor(
        IPoolManager poolManager_,
        address stable_,
        address quote_,
        uint8 quoteDecimals_,
        uint24 fee_,
        int24 tickSpacing_,
        int24 halfWidthTicks,
        IERC20 rewardToken_
    ) {
        if (
            address(poolManager_) == address(0) || stable_ == address(0) || quote_ == address(0) || stable_ == quote_
                || tickSpacing_ <= 0 || halfWidthTicks <= 0 || address(rewardToken_) == address(0)
                || (quoteDecimals_ != 6 && quoteDecimals_ != 18)
        ) {
            revert InvalidConfig();
        }
        poolManager = poolManager_;
        bool stableIs0 = stable_ < quote_;
        (currency0, currency1) = stableIs0
            ? (Currency.wrap(stable_), Currency.wrap(quote_))
            : (Currency.wrap(quote_), Currency.wrap(stable_));
        fee = fee_;
        tickSpacing = tickSpacing_;
        rewardToken = rewardToken_;
        // par: one USDarli (1e18 raw) for one quote unit (10^d raw), exactly as DarliDeployer initialises the pool
        uint160 par = quoteDecimals_ == 18 ? Q96 : (stableIs0 ? Q96 / 1e6 : Q96 * 1e6);
        int24 center = TickMath.getTickAtSqrtPrice(par);
        int24 lo = _floor(center - halfWidthTicks, tickSpacing_);
        int24 hi = -_floor(-(center + halfWidthTicks), tickSpacing_); // ceiling
        (tickLower, tickUpper) = (lo, hi);
        sqrtPriceLower = TickMath.getSqrtPriceAtTick(lo);
        sqrtPriceUpper = TickMath.getSqrtPriceAtTick(hi);
    }

    function _floor(int24 t, int24 spacing) private pure returns (int24) {
        int24 q = t / spacing;
        if (t < 0 && t % spacing != 0) q--;
        return q * spacing;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(0)));
    }

    function poolSqrtPrice() public view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolKey().toId());
    }

    // --- holders ------------------------------------------------------------------------------------------------------

    /// @notice Adds `liquidity` to the vault's position. The caller states the prices it accepts and the most it pays of
    ///         each token; the fees the position has earned so far go to the holders before this deposit.
    function deposit(
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        uint160 minSqrtPriceX96,
        uint160 maxSqrtPriceX96
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (liquidity == 0) revert ZeroLiquidity();
        uint160 p = poolSqrtPrice();
        if (p < sqrtPriceLower || p > sqrtPriceUpper) revert PriceOutsideVaultRange(p);
        if (p < minSqrtPriceX96 || p > maxSqrtPriceX96) revert PriceOutsideDepositorBounds(p);
        (amount0, amount1) = abi.decode(
            poolManager.unlock(abi.encode(Action.Deposit, msg.sender, liquidity, amount0Max, amount1Max)),
            (uint256, uint256)
        );
        emit Deposited(msg.sender, liquidity, amount0, amount1);
    }

    /// @notice Removes `liquidity`; the principal is credited to the caller (paid by `claim`), the fees go to every
    ///         holder alike. Needs no price and moves no token out of the PoolManager, so no token can refuse it.
    function withdraw(uint128 liquidity, uint256 amount0Min, uint256 amount1Min)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) revert ZeroLiquidity();
        if (shares[msg.sender] < liquidity) revert SharesExceeded();
        (amount0, amount1) = abi.decode(
            poolManager.unlock(abi.encode(Action.Withdraw, msg.sender, liquidity, amount0Min, amount1Min)),
            (uint256, uint256)
        );
        emit Withdrawn(msg.sender, liquidity, amount0, amount1);
    }

    /// @notice Anyone: collects the position's fees into the vault, to be shared per share.
    function collectFees() external nonReentrant {
        if (totalShares == 0) revert NothingToCollect();
        poolManager.unlock(abi.encode(Action.Collect, address(0), uint128(0), uint256(0), uint256(0)));
    }

    /// @notice Pays the caller's principal and earnings in one token -- 0 and 1 the pool's tokens, 2 the reward token --
    ///         to `to`. The other tokens stay owed (V7).
    function claim(uint256 token, address to) external nonReentrant returns (uint256 principal, uint256 earned) {
        return _pay(token, to);
    }

    /// @notice All three tokens to `to` in one call. If one of them refuses the transfer, the call reverts and the
    ///         per-token `claim` pays the others.
    function claimAll(address to)
        external
        nonReentrant
        returns (uint256[3] memory principal, uint256[3] memory earned)
    {
        for (uint256 k = 0; k < 3; k++) {
            (principal[k], earned[k]) = _pay(k, to);
        }
    }

    function principalOf(address who) external view returns (uint256[2] memory) {
        return _principal[who];
    }

    function _pay(uint256 k, address to) internal returns (uint256 principal, uint256 earned) {
        if (k > 2) revert NoSuchToken(k);
        if (to == address(0)) revert ZeroRecipient();
        earned = _claimOwed(msg.sender, k);
        if (k == 2) {
            if (earned > 0) rewardToken.safeTransfer(to, earned);
        } else {
            principal = _principal[msg.sender][k];
            _principal[msg.sender][k] = 0;
            if (principal + earned > 0) {
                poolManager.unlock(abi.encode(Action.Pay, to, k, principal + earned, uint256(0)));
            }
        }
        emit Paid(msg.sender, k, to, principal, earned);
    }

    /// @notice Anyone may pay reward tokens in: streamed to the holders over the next epoch.
    function notifyIncentive(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroLiquidity();
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        _notifyIncentive(amount);
        emit IncentivePaid(msg.sender, amount);
    }

    // --- the PoolManager ----------------------------------------------------------------------------------------------

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, address who, uint256 x, uint256 bound0, uint256 bound1) =
            abi.decode(data, (Action, address, uint256, uint256, uint256));
        if (action == Action.Pay) {
            // x is the token, bound0 the amount: the vault's claim is burnt and the token goes from the PoolManager
            // straight to the recipient; the vault's own address never touches the token
            Currency c = x == 0 ? currency0 : currency1;
            poolManager.burn(address(this), c.toId(), bound0);
            poolManager.take(c, who, bound0);
            return "";
        }
        uint128 liquidity = SafeCast.toUint128(x);
        int256 delta = action == Action.Deposit
            ? SafeCast.toInt256(uint256(liquidity))
            : (action == Action.Withdraw ? -SafeCast.toInt256(uint256(liquidity)) : int256(0));
        (BalanceDelta callerDelta, BalanceDelta fees) = poolManager.modifyLiquidity(
            poolKey(), IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, delta, bytes32(0)), ""
        );
        uint256 f0 = uint256(int256(fees.amount0()));
        uint256 f1 = uint256(int256(fees.amount1()));
        // the fees earned so far belong to the holders of before this change
        _collectFees(f0, f1);
        emit FeesCollected(f0, f1);
        if (action == Action.Deposit) {
            return _onDeposit(who, liquidity, bound0, bound1, callerDelta, f0, f1);
        }
        if (action == Action.Withdraw) {
            return _onWithdraw(who, liquidity, bound0, bound1, callerDelta, f0, f1);
        }
        _keep(currency0, f0);
        _keep(currency1, f1);
        return abi.encode(uint256(0), uint256(0));
    }

    /// The principal is everything the call moved less the fees. The depositor pays it to the PoolManager directly; what
    /// is left to the vault is the fees, kept there as its claims.
    function _onDeposit(
        address who,
        uint128 liquidity,
        uint256 max0,
        uint256 max1,
        BalanceDelta callerDelta,
        uint256 f0,
        uint256 f1
    ) internal returns (bytes memory) {
        uint256 a0 = uint256(int256(f0) - int256(callerDelta.amount0()));
        uint256 a1 = uint256(int256(f1) - int256(callerDelta.amount1()));
        if (a0 > max0 || a1 > max1) revert AmountAboveMaximum(a0, a1);
        _addShares(who, liquidity);
        _payIn(currency0, who, a0);
        _payIn(currency1, who, a1);
        _keep(currency0, f0);
        _keep(currency1, f1);
        return abi.encode(a0, a1);
    }

    /// Principal and fees both stay in the PoolManager as the vault's claims; the principal is credited to the leaver.
    function _onWithdraw(
        address who,
        uint128 liquidity,
        uint256 min0,
        uint256 min1,
        BalanceDelta callerDelta,
        uint256 f0,
        uint256 f1
    ) internal returns (bytes memory) {
        uint256 a0 = uint256(int256(callerDelta.amount0()) - int256(f0));
        uint256 a1 = uint256(int256(callerDelta.amount1()) - int256(f1));
        if (a0 < min0 || a1 < min1) revert AmountBelowMinimum(a0, a1);
        _removeShares(who, liquidity);
        _principal[who][0] += a0;
        _principal[who][1] += a1;
        _keep(currency0, a0 + f0);
        _keep(currency1, a1 + f1);
        return abi.encode(a0, a1);
    }

    /// The depositor's payment of one token, from its account to the PoolManager.
    function _payIn(Currency c, address from, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(c);
        IERC20(Currency.unwrap(c)).safeTransferFrom(from, address(poolManager), amount);
        poolManager.settle();
    }

    /// What the PoolManager owes the vault in one token, kept there as the vault's ERC-6909 claim.
    function _keep(Currency c, uint256 amount) internal {
        if (amount > 0) poolManager.mint(address(this), c.toId(), amount);
    }
}
