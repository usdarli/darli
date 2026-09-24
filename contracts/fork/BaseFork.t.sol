// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {DarliSystemBuild, SystemParams, BranchParams, SystemAddrs} from "../script/DarliSystem.s.sol";
import {DarliLiquidityVault} from "../src/liquidity/DarliLiquidityVault.sol";
import {IPoolManagerInit} from "../src/deploy/DarliDeployer.sol";
import {SingleSourcePriceFeed} from "../src/oracle/SingleSourcePriceFeed.sol";
import {ChainlinkSource, ChainlinkSequencerGuard, IAggregatorV3} from "../src/oracle/ChainlinkAdapters.sol";
import {IPriceFeed, IFeedSource, ISequencerGuard} from "../src/interfaces/IPriceFeed.sol";
import {PriceStatus} from "../src/Types.sol";

/// Base's USDC (FiatToken): the blacklist its blacklister can set on any address.
interface IFiatToken {
    function blacklister() external view returns (address);
    function blacklist(address who) external;
    function unBlacklist(address who) external;
}

/// Swaps on the real PoolManager: exact input, up to a price limit; pays and takes its own tokens.
contract Swapper is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit) external {
        pm.unlock(abi.encode(key, zeroForOne, amountIn, limit));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit) =
            abi.decode(data, (PoolKey, bool, uint256, uint160));
        BalanceDelta d = pm.swap(key, IPoolManager.SwapParams(zeroForOne, -int256(amountIn), limit), "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 net) internal {
        if (net < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(pm), uint256(int256(-net)));
            pm.settle();
        } else if (net > 0) {
            pm.take(c, address(this), uint256(int256(net)));
        }
    }
}

/// SPEC D2, D4, V6, V7 and O5 on Base itself, at a pinned block: the real Uniswap v4 PoolManager, USDC, WETH, the Chainlink
/// ETH/USD feed and the sequencer uptime feed. What the offline tests can only assume -- the PoolManager's storage layout,
/// that an empty pool's price can be moved for free, that the vault's position maths are v4's, the feed's gas -- is
/// checked here. Run with `make fork` (BASE_RPC_URL overrides the endpoint).
contract BaseForkTest is Test, DarliSystemBuild {
    uint256 constant BLOCK = 51_380_224;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant SEQUENCER = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    uint256 constant E = 1e18;
    uint256 constant PCT = 1e16;
    uint256 constant FEED_GAS = 100_000; // a placeholder stipend: open in SPEC 13
    uint160 constant Q96 = 2 ** 96;

    IPoolManager pm = IPoolManager(POOL_MANAGER);
    SingleSourcePriceFeed feed;
    SystemParams p;
    address alice = address(0x5000);
    address bob = address(0x5001);
    address carol = address(0x5002);

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base.gateway.tenderly.co")), BLOCK);
        feed = new SingleSourcePriceFeed(
            IFeedSource(address(new ChainlinkSource(IAggregatorV3(ETH_USD)))),
            ISequencerGuard(address(new ChainlinkSequencerGuard(IAggregatorV3(SEQUENCER)))),
            1 hours, // three heartbeats of the feed (20 minutes); the thresholds are open in SPEC 13
            24 hours,
            1 hours,
            FEED_GAS,
            FEED_GAS
        );
        p.name = "USDarli";
        p.symbol = "USDarli";
        p.frontendShare = 3 * PCT;
        p.betaWad = E; // SPEC 2: β = 1; what follows are placeholders for what SPEC 13 leaves open
        p.initialBaseRate = 10 * PCT;
        p.darliRecipient = address(this);
        p.darliSupply = 1_000_000 * E;
        p.poolManager = IPoolManagerInit(POOL_MANAGER);
        p.quote = USDC;
        p.quoteDecimals = 6;
        p.poolFee = 100; // 0.01 %
        p.tickSpacing = 1;
        p.vaultHalfWidthTicks = 100; // about 1 % either side of par
        p.branches
            .push(
                BranchParams({
                    collToken: IERC20(WETH),
                    feed: IPriceFeed(address(feed)),
                    mcr: 110 * PCT,
                    ccr: 150 * PCT,
                    scr: 110 * PCT,
                    minDebt: 500 * E,
                    minRate: PCT / 2,
                    maxRate: 250 * PCT,
                    cap0: 125_000 * E,
                    capCeiling: 250_000 * E,
                    gasDeposit: E / 1000,
                    spShare: 72 * PCT,
                    penSp: 5 * PCT,
                    penRedist: 10 * PCT,
                    liqBonus: PCT / 2,
                    liqBonusCap: 2 * E,
                    nftName: "Darli Trove (WETH)",
                    nftSymbol: "DTROVE-WETH"
                })
            );
    }

    // --- O5: the live feed ---------------------------------------------------------------------------------------------

    function test_fork_theLiveFeedIsValidAndOneReadFitsTheStipend() public {
        (uint256 price, PriceStatus status) = feed.fetchPrice();
        assertEq(uint8(status), uint8(PriceStatus.Valid), "O2: the live feed reads Valid at the pinned block");
        assertGt(price, 1000 * E, "a price in WAD, scaled from the feed's 8 decimals");
        assertLt(price, 10_000 * E);
        // measure each read as the first touch in a transaction: the proxy, the aggregator behind it and our adapter
        ChainlinkSource src = new ChainlinkSource(IAggregatorV3(ETH_USD));
        ChainlinkSequencerGuard seq = new ChainlinkSequencerGuard(IAggregatorV3(SEQUENCER));
        (bool ok, bytes memory ret) = ETH_USD.staticcall(abi.encodeWithSignature("aggregator()"));
        assertTrue(ok);
        address agg = abi.decode(ret, (address));
        (ok, ret) = SEQUENCER.staticcall(abi.encodeWithSignature("aggregator()"));
        address seqAgg = ok ? abi.decode(ret, (address)) : address(0);
        vm.cool(ETH_USD);
        vm.cool(agg);
        vm.cool(address(src));
        uint256 g = gasleft();
        src.read();
        uint256 used = g - gasleft();
        vm.cool(SEQUENCER);
        if (seqAgg != address(0)) vm.cool(seqAgg);
        vm.cool(address(seq));
        g = gasleft();
        seq.status();
        uint256 usedSeq = g - gasleft();
        console2.log("gas of one cold read of the ETH/USD source:", used);
        console2.log("gas of one cold read of the sequencer guard:", usedSeq);
        assertLt(used, FEED_GAS, "O5: an honest read must fit the stipend");
        assertLt(usedSeq, FEED_GAS, "O5: an honest read must fit the stipend");
    }

    // --- D2 on the real PoolManager --------------------------------------------------------------------------------------

    function test_fork_anUncontestedDeploymentReadsBackItsOwnPrice() public {
        SystemAddrs memory s = _deploy(p, address(this));
        assertFalse(s.deployer.poolPreInitialised());
        // the deployer compared the price at its assumed slot with the price it asked for, and would have reverted
        // (PoolStateLayoutMismatch) had the deployed PoolManager kept it elsewhere: the layout is confirmed
        assertEq(s.deployer.observedSqrtPriceX96(), s.deployer.targetSqrtPriceX96(), "D2: the layout of the real PM");
        assertEq(s.vault.poolSqrtPrice(), s.deployer.targetSqrtPriceX96(), "D4: the vault reads the same pool");
    }

    function test_fork_aRacedPoolIsToleratedItsPriceCorrectedForFreeAndTheVaultGuardHolds() public {
        uint256 n = vm.getNonce(address(this));
        address token = vm.computeCreateAddress(vm.computeCreateAddress(address(this), n), 1);
        (address c0, address c1) = token < USDC ? (token, USDC) : (USDC, token);
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 100, 1, IHooks(address(0)));
        uint160 par = token < USDC ? Q96 / 1e6 : Q96 * 1e6;
        uint160 attacker = par * 2; // four times par: far outside the vault's range
        vm.prank(address(0xBAD));
        pm.initialize(key, attacker);
        SystemAddrs memory s = _deploy(p, address(this)); // must not depend on winning the race
        assertTrue(s.deployer.poolPreInitialised(), "D2: the raced pool is tolerated");
        assertEq(s.deployer.observedSqrtPriceX96(), attacker, "D2: and its real price is recorded");
        address holder = _fundHolder(s, alice, 20_000e6);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(DarliLiquidityVault.PriceOutsideVaultRange.selector, attacker));
        s.vault.deposit(1e12, type(uint256).max, type(uint256).max, 0, type(uint160).max);
        // an empty pool's price is moved back to par by anyone, for nothing
        Swapper sw = new Swapper(pm);
        deal(USDC, address(sw), 1);
        deal(address(s.token), address(sw), 0);
        bool zeroForOne = attacker > par; // price falls when token0 is sold
        uint256 before0 = IERC20(c0).balanceOf(address(sw));
        uint256 before1 = IERC20(c1).balanceOf(address(sw));
        sw.swap(key, zeroForOne, 1, par);
        assertEq(s.vault.poolSqrtPrice(), par, "the empty pool is back at par");
        assertEq(IERC20(c0).balanceOf(address(sw)) + IERC20(c1).balanceOf(address(sw)), before0 + before1, "for free");
        vm.prank(holder);
        s.vault.deposit(1e12, type(uint256).max, type(uint256).max, 0, type(uint160).max);
    }

    // --- D4, V6: the vault on a real pool ---------------------------------------------------------------------------------

    /// Alice borrows USDarli against WETH on the fork and holds USDC; she approves the vault.
    function _fundHolder(SystemAddrs memory s, address who, uint256 usdc) internal returns (address) {
        deal(WETH, who, 100 * E);
        deal(USDC, who, usdc);
        vm.startPrank(who);
        IERC20(WETH).approve(address(s.branches[0].manager), type(uint256).max);
        s.branches[0].manager.openTrove(who, 20 * E, 20_000 * E, 5 * PCT, 0, type(uint256).max, 0, 0);
        s.token.approve(address(s.vault), type(uint256).max);
        IERC20(USDC).approve(address(s.vault), type(uint256).max);
        vm.stopPrank();
        return who;
    }

    function _liquidityForUsdc(DarliLiquidityVault v, uint256 usdc) internal view returns (uint128) {
        uint160 sp = v.poolSqrtPrice();
        if (Currency.unwrap(v.currency1()) == USDC) {
            return uint128(FullMath.mulDiv(usdc, Q96, sp - v.sqrtPriceLower()));
        }
        uint256 x = FullMath.mulDiv(usdc, sp, Q96);
        return uint128(FullMath.mulDiv(x, v.sqrtPriceUpper(), v.sqrtPriceUpper() - sp));
    }

    /// Swaps back and forth through the vault's range: fees in both tokens.
    function _churn(Swapper sw, PoolKey memory key, uint256 rounds, bool bothWays) internal {
        bool usdcIs0 = Currency.unwrap(key.currency0) == USDC;
        for (uint256 i = 0; i < rounds; i++) {
            sw.swap(key, usdcIs0, 1_000e6, usdcIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
            if (bothWays) {
                sw.swap(key, !usdcIs0, 1_000 * E, !usdcIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
            }
        }
    }

    function test_fork_theVaultEarnsSwapFeesAndANewcomerGetsNoneOfTheOld() public {
        SystemAddrs memory s = _deploy(p, address(this));
        DarliLiquidityVault v = s.vault;
        PoolKey memory key = v.poolKey();
        _fundHolder(s, alice, 20_000e6);
        _fundHolder(s, carol, 20_000e6);
        uint128 la = _liquidityForUsdc(v, 5_000e6);
        {
            vm.prank(alice);
            (uint256 a0, uint256 a1) = v.deposit(la, type(uint256).max, type(uint256).max, 0, type(uint160).max);
            assertGt(a0, 0);
            assertGt(a1, 0, "D4: at par the position holds both tokens");
        }
        // swaps both ways: fees in both tokens
        Swapper sw = new Swapper(pm);
        deal(USDC, address(sw), 50_000e6);
        vm.prank(alice);
        s.token.transfer(address(sw), 5_000 * E);
        _churn(sw, key, 6, true);
        v.collectFees();
        uint256[3] memory before = v.pending(alice);
        assertGt(before[0], 0, "V6: fees in token0");
        assertGt(before[1], 0, "V6: fees in token1");
        // carol joins after those fees: she gets none of them
        uint128 lc = _liquidityForUsdc(v, 5_000e6);
        vm.prank(carol);
        v.deposit(lc, type(uint256).max, type(uint256).max, 0, type(uint160).max);
        uint256[3] memory c = v.pending(carol);
        assertEq(c[0] + c[1], 0, "V6: a newcomer gets no part of earlier fees");
        _churn(sw, key, 1, false);
        v.collectFees();
        c = v.pending(carol);
        assertGt(c[0] + c[1], 0, "V6: later fees are shared with her");
        // alice leaves: principal back, fees claimable
        uint256[3] memory owedAlice = v.pending(alice);
        {
            vm.prank(alice);
            (uint256 w0, uint256 w1) = v.withdraw(la, 0, 0);
            assertGt(w0 + w1, 0, "the principal comes back");
        }
        uint256 held0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(alice);
        vm.prank(alice);
        (uint256[3] memory principal, uint256[3] memory got) = v.claimAll(alice);
        assertEq(got[0], owedAlice[0], "V6: what she earned stays hers after leaving");
        assertEq(got[1], owedAlice[1]);
        assertEq(
            IERC20(Currency.unwrap(key.currency0)).balanceOf(alice) - held0,
            principal[0] + got[0],
            "V7: principal and earnings in one transfer per token"
        );
        // the vault holds what it owes, as claims inside the PoolManager, and none of the pool's tokens itself
        uint256[3] memory rest = v.pending(carol);
        assertGe(pm.balanceOf(address(v), key.currency0.toId()), rest[0], "V6: the vault covers token0");
        assertGe(pm.balanceOf(address(v), key.currency1.toId()), rest[1], "V6: the vault covers token1");
        assertEq(IERC20(Currency.unwrap(key.currency0)).balanceOf(address(v)), 0, "V7: no token balance in the vault");
        assertEq(IERC20(Currency.unwrap(key.currency1)).balanceOf(address(v)), 0, "V7: no token balance in the vault");
    }

    /// V7 with Base's real USDC blacklist. Alice's address is frozen: she still withdraws, her USDarli and DARLI are
    /// paid, and her USDC waits for a recipient she names. Then the vault's own address is frozen, and carol is still
    /// paid in full. Then the PoolManager's: only USDC stops, and resumes when it is lifted.
    function test_fork_aFrozenAddressBlocksOnlyItsOwnPayoutOfThatToken() public {
        SystemAddrs memory s = _deploy(p, address(this));
        DarliLiquidityVault v = s.vault;
        uint256 u = Currency.unwrap(v.currency0()) == USDC ? 0 : 1; // USDC's index; USDarli is 1 - u
        _fundHolder(s, alice, 20_000e6);
        _fundHolder(s, carol, 20_000e6);
        uint128 la = _liquidityForUsdc(v, 5_000e6);
        vm.prank(alice);
        v.deposit(la, type(uint256).max, type(uint256).max, 0, type(uint160).max);
        // fees in both tokens -- some collected by carol's deposit, some by alice's withdrawal, some by anyone -- and a
        // DARLI reward streamed over the next epoch
        Swapper sw = new Swapper(pm);
        deal(USDC, address(sw), 50_000e6);
        vm.prank(alice);
        s.token.transfer(address(sw), 5_000 * E);
        _churn(sw, v.poolKey(), 2, true);
        uint128 lc = _liquidityForUsdc(v, 5_000e6);
        vm.prank(carol);
        v.deposit(lc, type(uint256).max, type(uint256).max, 0, type(uint160).max);
        _churn(sw, v.poolKey(), 4, true);
        v.collectFees();
        s.darli.approve(address(v), type(uint256).max);
        v.notifyIncentive(7_000 * E);
        vm.warp(block.timestamp + 15 days);
        _churn(sw, v.poolKey(), 1, true);

        IFiatToken usdc = IFiatToken(USDC);
        address blacklister = usdc.blacklister();
        vm.prank(blacklister);
        usdc.blacklist(alice);
        _frozenHolderIsPaidEverythingButUsdcToHerself(s, v, u, la);

        vm.prank(blacklister);
        usdc.blacklist(address(v));
        vm.prank(carol);
        v.withdraw(lc, 0, 0);
        vm.prank(blacklister);
        usdc.blacklist(POOL_MANAGER);
        _refusedByTheBlacklist(carol, address(v), abi.encodeCall(v.claim, (u, carol))); // the PoolManager cannot move it
        uint256 d0 = s.token.balanceOf(carol);
        vm.prank(carol);
        (uint256 prin, uint256 earned) = v.claim(1 - u, carol);
        assertGt(prin, 0);
        assertEq(s.token.balanceOf(carol) - d0, prin + earned, "V7: a frozen PoolManager stops USDC alone");
        vm.prank(blacklister);
        usdc.unBlacklist(POOL_MANAGER);
        uint256 c0 = IERC20(USDC).balanceOf(carol);
        vm.prank(carol);
        (prin, earned) = v.claim(u, carol);
        assertGt(prin, 0);
        assertEq(IERC20(USDC).balanceOf(carol) - c0, prin + earned, "V7: a frozen vault address blocks nobody's USDC");
        assertEq(IERC20(USDC).balanceOf(address(v)), 0, "V7: the vault never held USDC");
    }

    /// The call reverts, and for USDC's own reason (the PoolManager wraps it; the text survives inside).
    function _refusedByTheBlacklist(address from, address target, bytes memory data) internal {
        vm.prank(from);
        (bool ok, bytes memory ret) = target.call(data);
        assertFalse(ok, "V7: the frozen payout is refused");
        bytes memory why = bytes("Blacklistable: account is blacklisted");
        bool found;
        for (uint256 i = 0; i + why.length <= ret.length && !found; i++) {
            found = keccak256(_slice(ret, i, why.length)) == keccak256(why);
        }
        assertTrue(found, "V7: refused by USDC's blacklist, not by anything else");
    }

    function _slice(bytes memory b, uint256 from, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = b[from + i];
        }
    }

    function _frozenHolderIsPaidEverythingButUsdcToHerself(
        SystemAddrs memory s,
        DarliLiquidityVault v,
        uint256 u,
        uint128 la
    ) internal {
        vm.prank(alice);
        (uint256 w0, uint256 w1) = v.withdraw(la, 0, 0);
        uint256[2] memory credited = v.principalOf(alice);
        assertEq(credited[0], w0, "V7: a withdrawal credits the principal and pays nothing");
        assertEq(credited[1], w1);
        _refusedByTheBlacklist(alice, address(v), abi.encodeCall(v.claim, (u, alice)));
        _refusedByTheBlacklist(alice, address(v), abi.encodeCall(v.claimAll, (alice))); // all at once is refused ...
        uint256 d0 = s.token.balanceOf(alice);
        vm.prank(alice);
        (uint256 prin, uint256 earned) = v.claim(1 - u, alice); // ... one token at a time is not
        assertGt(prin, 0);
        assertGt(earned, 0);
        assertEq(s.token.balanceOf(alice) - d0, prin + earned, "V7: her USDarli is paid while her address is frozen");
        vm.prank(alice);
        (, earned) = v.claim(2, alice);
        assertGt(earned, 0);
        assertEq(s.darli.balanceOf(alice), earned, "V7: so are her DARLI rewards");
        vm.prank(alice);
        (prin, earned) = v.claim(u, bob);
        assertGt(prin, 0);
        assertEq(IERC20(USDC).balanceOf(bob), prin + earned, "V7: her USDC goes to a recipient she names");
    }

    function test_fork_depositsAreRefusedOutsideTheRangeAndOutsideTheDepositorsBounds() public {
        SystemAddrs memory s = _deploy(p, address(this));
        DarliLiquidityVault v = s.vault;
        PoolKey memory key = v.poolKey();
        _fundHolder(s, alice, 20_000e6);
        uint160 par = v.poolSqrtPrice();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DarliLiquidityVault.PriceOutsideDepositorBounds.selector, par));
        v.deposit(1e12, type(uint256).max, type(uint256).max, par + 1, type(uint160).max);
        // push the empty pool beyond the range's upper edge
        Swapper sw = new Swapper(pm);
        deal(USDC, address(sw), 1);
        uint160 beyond = v.sqrtPriceUpper() + 1_000;
        sw.swap(key, false, 1, beyond);
        assertEq(v.poolSqrtPrice(), beyond);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DarliLiquidityVault.PriceOutsideVaultRange.selector, beyond));
        v.deposit(1e12, type(uint256).max, type(uint256).max, 0, type(uint160).max);
    }
}
