// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableToken} from "../core/StableToken.sol";
import {IBranchManager} from "../interfaces/IBranchManager.sol";

/// @dev Minimal view of the Uniswap v4 PoolManager: only what deployment needs. Darli does not fork or import v4.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IPoolManagerInit {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    /// @dev v4 exposes raw storage reads; pool state lives at keccak256(abi.encode(poolId, POOLS_SLOT)) and the low 160 bits
    ///      of its first word are sqrtPriceX96 (0 = pool does not exist). Matches v4-core SOURCE at commit 46c6834: POOLS_SLOT
    ///      = 6, the state slot is keccak256(abi.encodePacked(poolId, POOLS_SLOT)) -- byte-identical to abi.encode for two
    ///      bytes32, pinned by `test_slotDerivation_encodeEqualsEncodePacked` -- and Slot0 keeps sqrtPriceX96 in bits 0-159.
    ///      TO BE CONFIRMED against the DEPLOYED PoolManager on a fork: source is not bytecode. Until then this contract
    ///      proves the layout itself on every uncontested deployment (see PoolStateLayoutMismatch).
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @title DarliDeployer
/// @notice Everything that happens exactly once. In ONE transaction it creates USDarli, checks that every branch was built
///         for exactly that token, seals its minter set, and initialises
///         the canonical USDarli / quote pool in Uniswap v4 at par, with no hook. After `deploy` this contract can do
///         nothing: it has no other function and the token's deployer rights are spent.
///         "At par" means the representable sqrtPriceX96 at or just below one: exact for an 18-decimal quote and for a
///         6-decimal quote when USDarli is currency1; floor(2^96 / 1e6) when USDarli is currency0, which puts the price
///         2.4e-23 below one -- about 4e18 times smaller than a single tick.
/// @dev    THE POOL RACE. In v4 anyone may initialise any pool key at any price, and `initialize` does not check that the
///         currencies have code. The token's future address is predictable (CREATE: this contract's address and nonce), so an
///         attacker CAN initialise this very key first. Deployment therefore never depends on winning that race: a failed
///         `initialize` is tolerated and recorded in `poolPreInitialised`. The PRICE is enforced where it matters: the
///         liquidity vault must refuse deposits while the pool's price is outside its fixed range, and the price of a pool
///         without liquidity can be moved by anyone at no cost. (To be confirmed against the real PoolManager on a fork.)
///         The core contracts never learn the pool's address; only this public record and the liquidity vault do.
contract DarliDeployer {
    uint160 private constant Q96 = 2 ** 96;
    /// @dev v4-core TickMath (commit 46c6834): `initialize` rejects any price outside [MIN, MAX), so no pool can hold one.
    uint160 private constant MIN_SQRT_PRICE = 4295128739;
    uint160 private constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    address public immutable deployerEOA;
    bool public deployed;
    bool public poolPreInitialised;
    uint160 public targetSqrtPriceX96; // what this deployment asked for
    uint160 public observedSqrtPriceX96; // what the pool really holds when deployment ends (may differ: see THE POOL RACE)
    bytes32 private constant POOLS_SLOT = bytes32(uint256(6));
    StableToken public stable;
    PoolKey public canonicalPool;

    error NotDeployer();
    error AlreadyDeployed();
    error QuoteDecimalsUnsupported();
    error PoolAbsentAfterInitialise();
    error QuoteHasNoCode();
    error PoolStateLayoutMismatch();
    error PoolPriceOutOfRange();
    error MinterNotBuiltForThisToken(address minter);

    event PoolWasPreInitialised();
    event Deployed(
        address indexed stable,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        uint160 targetSqrtPriceX96,
        uint160 observedSqrtPriceX96
    );

    constructor() {
        deployerEOA = msg.sender;
    }

    /// @param minters      the branch contracts of this deployment (the only addresses that will ever mint or burn)
    /// @param quote        the quote asset of the canonical pool (e.g. USDC)
    /// @param quoteDecimals 6 or 18
    function deploy(
        string calldata name,
        string calldata symbol,
        address[] calldata minters,
        IPoolManagerInit poolManager,
        address quote,
        uint8 quoteDecimals,
        uint24 fee,
        int24 tickSpacing
    ) external returns (StableToken token, uint160 sqrtPriceX96) {
        if (msg.sender != deployerEOA) revert NotDeployer();
        if (deployed) revert AlreadyDeployed();
        // v4 `initialize` does not check that a currency has code, so a mistyped quote would create the one canonical pool,
        // for ever, against something that is not a token. address(0) is native ETH in v4, and "par" against ETH is
        // meaningless, so it is refused by the same check.
        if (quote.code.length == 0) revert QuoteHasNoCode();
        deployed = true;

        token = new StableToken(name, symbol, address(this));
        // Each branch was built before this transaction, with the token's predicted address as an immutable. Nothing
        // else checks that prediction, and sealing a branch built for another address would make it a minter for ever
        // of a token it does not mint. So every minter must name exactly this token before the set is closed; anything
        // else -- no code, no `stable()`, another address -- reverts the whole deployment, which can then be retried.
        // A one-time cost of one staticcall per branch; no operation after deployment reads anything more.
        for (uint256 i = 0; i < minters.length; i++) {
            (bool ok, bytes memory ret) = minters[i].staticcall(abi.encodeCall(IBranchManager.stable, ()));
            if (!ok || ret.length != 32 || abi.decode(ret, (address)) != address(token)) {
                revert MinterNotBuiltForThisToken(minters[i]);
            }
        }
        token.sealMinters(minters); // one shot: the minter set is closed for ever, for this contract too

        (address c0, address c1) = address(token) < quote ? (address(token), quote) : (quote, address(token));
        sqrtPriceX96 = _sqrtPriceAtPar(c0 == address(token), quoteDecimals);
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: address(0)});
        try poolManager.initialize(key, sqrtPriceX96) {}
        catch {
            // A failed initialise means "already initialised" ONLY IF the pool demonstrably exists. Any other failure (wrong
            // PoolManager, invalid fee or tick spacing, anything else) must stop the deployment: no false success.
            poolPreInitialised = true;
        }
        uint160 observed = _poolPrice(poolManager, key);
        if (observed == 0) revert PoolAbsentAfterInitialise();
        // Self-test of the storage-layout assumption. When OUR initialise succeeded the pool holds exactly the price we
        // passed, so reading anything else proves POOLS_SLOT or the Slot0 packing is not what this contract assumes. On
        // this path that can be PROVEN, so the deployment refuses rather than record a number read from the wrong place;
        // it reverts whole and can be retried once the layout is fixed. Every uncontested deployment is thereby a check
        // of the layout on the real PoolManager.
        if (!poolPreInitialised && observed != sqrtPriceX96) revert PoolStateLayoutMismatch();
        // On the raced path the price is the attacker's and cannot be compared with ours. It can at least be required to
        // be a price v4 could hold at all. That is a weak filter -- an unrelated slot can hold such a number -- and the
        // fork test named in SPEC 13 remains the real confirmation for this path.
        if (observed < MIN_SQRT_PRICE || observed >= MAX_SQRT_PRICE) revert PoolPriceOutOfRange();
        targetSqrtPriceX96 = sqrtPriceX96;
        observedSqrtPriceX96 = observed;

        if (poolPreInitialised) emit PoolWasPreInitialised();
        stable = token;
        canonicalPool = key;
        emit Deployed(address(token), c0, c1, fee, tickSpacing, sqrtPriceX96, observed);
    }

    function _poolPrice(IPoolManagerInit pm, PoolKey memory key) private view returns (uint160) {
        bytes32 poolId = keccak256(abi.encode(key));
        bytes32 stateSlot = keccak256(abi.encode(poolId, POOLS_SLOT));
        return uint160(uint256(pm.extsload(stateSlot)));
    }

    /// @dev price = raw amount of currency1 per raw unit of currency0. One USDarli (1e18 raw) == one quote unit (10^d raw).
    function _sqrtPriceAtPar(bool stableIsCurrency0, uint8 quoteDecimals) private pure returns (uint160) {
        if (quoteDecimals == 18) return Q96;
        if (quoteDecimals != 6) revert QuoteDecimalsUnsupported();
        // stable is currency0: price = 1e6 / 1e18 = 1e-12 -> sqrt = 1e-6 ; otherwise price = 1e12 -> sqrt = 1e6
        return stableIsCurrency0 ? Q96 / 1e6 : Q96 * 1e6;
    }
}
