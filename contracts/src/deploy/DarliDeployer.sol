// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableToken} from "../core/StableToken.sol";

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
    ///      of its first word are sqrtPriceX96 (0 = pool does not exist). TO BE CONFIRMED against the deployed PoolManager.
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @title DarliDeployer
/// @notice Everything that happens exactly once. In ONE transaction it creates USDarli, seals its minter set, and initialises
///         the canonical USDarli / quote pool in Uniswap v4 at a price of exactly 1, with no hook. After `deploy` this contract
///         can do nothing: it has no other function and the token's deployer rights are spent.
/// @dev    THE POOL RACE. In v4 anyone may initialise any pool key at any price, and `initialize` does not check that the
///         currencies have code. The token's future address is predictable (CREATE: this contract's address and nonce), so an
///         attacker CAN initialise this very key first. Deployment therefore never depends on winning that race: a failed
///         `initialize` is tolerated and recorded in `poolPreInitialised`. The PRICE is enforced where it matters: the
///         liquidity vault must refuse deposits while the pool's price is outside its fixed range, and the price of a pool
///         without liquidity can be moved by anyone at no cost. (To be confirmed against the real PoolManager on a fork.)
///         The core contracts never learn the pool's address; only this public record and the liquidity vault do.
contract DarliDeployer {
    uint160 private constant Q96 = 2 ** 96;

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

    event PoolWasPreInitialised();
    event Deployed(address stable, address currency0, address currency1, uint24 fee, int24 tickSpacing, uint160 targetSqrtPriceX96, uint160 observedSqrtPriceX96);

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
        deployed = true;

        token = new StableToken(name, symbol, address(this));
        token.sealMinters(minters); // one shot: the minter set is closed for ever, for this contract too

        (address c0, address c1) = address(token) < quote ? (address(token), quote) : (quote, address(token));
        sqrtPriceX96 = _sqrtPriceAtPar(c0 == address(token), quoteDecimals);
        PoolKey memory key = PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: address(0)});
        try poolManager.initialize(key, sqrtPriceX96) {}
        catch {
            // A failed initialise means "already initialised" ONLY IF the pool demonstrably exists. Any other failure (wrong
            // PoolManager, invalid fee or tick spacing, anything else) must stop the deployment: no false success.
            poolPreInitialised = true;
        }
        uint160 observed = _poolPrice(poolManager, key);
        if (observed == 0) revert PoolAbsentAfterInitialise();
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
