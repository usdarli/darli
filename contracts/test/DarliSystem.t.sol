// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DarliSystemBuild, SystemParams, BranchParams, SystemAddrs, BranchAddrs} from "../script/DarliSystem.s.sol";
import {BranchSettlement} from "../src/core/BranchSettlement.sol";
import {ISettlementHooks} from "../src/interfaces/IBranchManager.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {PriceStatus} from "../src/Types.sol";
import {MockCollateral, MockPriceFeed} from "./mocks/BranchMocks.sol";
import {MockPoolManager} from "./mocks/PoolMocks.sol";

/// SPEC §10 end to end: a whole system -- two branches, the redemption router, revenue to DARLI stakers, the frontend
/// registry -- built by the same code as the deployment script, at the addresses the deployment predicts, checked link by
/// link and sealed. Then one life of it: borrowing on both branches, a Stability Pool, a redemption split across them,
/// interest routed to a staker, a liquidation, and one branch shut down and settled while the other goes on. The
/// system-wide identity (supply == the branches' debt, I-1) is checked at every stage.
contract DarliSystemTest is Test, DarliSystemBuild {
    uint256 constant E = 1e18;
    uint256 constant PCT = 1e16;
    uint256 constant MAX = type(uint256).max;

    MockCollateral weth;
    MockCollateral wbtc; // any second collateral: the branches are independent
    MockPriceFeed feed0;
    MockPriceFeed feed1;
    MockCollateral quote;
    MockPoolManager pm;
    SystemParams p;
    SystemAddrs s;
    address alice = address(0x3000);
    address bob = address(0x3001);
    address carol = address(0x3002);
    address keeper = address(0x3003);

    function _branch(IERC20 coll, IPriceFeed feed, string memory sym) internal pure returns (BranchParams memory) {
        return BranchParams({
            collToken: coll,
            feed: feed,
            mcr: 110 * PCT,
            ccr: 150 * PCT,
            scr: 110 * PCT,
            minDebt: 500 * E, // SPEC 2, proposed
            minRate: PCT / 2,
            maxRate: 250 * PCT,
            cap0: 125_000 * E, // SPEC 2, pilot
            capCeiling: 250_000 * E,
            gasDeposit: E / 1000, // SPEC 13 item 2 is open: a placeholder for the test
            spShare: 72 * PCT,
            penSp: 5 * PCT,
            penRedist: 10 * PCT,
            liqBonus: PCT / 2,
            liqBonusCap: 2 * E,
            nftName: string.concat("Darli Trove (", sym, ")"),
            nftSymbol: string.concat("DTROVE-", sym)
        });
    }

    function setUp() public {
        vm.warp(1_700_000_000);
        weth = new MockCollateral();
        wbtc = new MockCollateral();
        feed0 = new MockPriceFeed(2000 * E);
        feed1 = new MockPriceFeed(3000 * E);
        quote = new MockCollateral();
        pm = new MockPoolManager();
        p.name = "USDarli";
        p.symbol = "USDarli";
        p.frontendShare = 3 * PCT;
        p.betaWad = 4 * E; // SPEC 13 item 1 is open: the pilot simulations' value
        p.initialBaseRate = 10 * PCT;
        p.darliRecipient = address(this); // SPEC 13 item 4 is open: placeholders
        p.darliSupply = 1_000_000 * E;
        p.poolManager = pm;
        p.quote = address(quote);
        p.quoteDecimals = 18;
        p.poolFee = 100;
        p.tickSpacing = 1;
        p.vaultHalfWidthTicks = 100;
        p.branches.push(_branch(weth, feed0, "WETH"));
        p.branches.push(_branch(wbtc, feed1, "C2"));
        _keep(_deploy(p, address(this)));
        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < 3; i++) {
            weth.mint(users[i], 1_000 * E);
            wbtc.mint(users[i], 1_000 * E);
            vm.startPrank(users[i]);
            weth.approve(address(s.branches[0].manager), MAX);
            wbtc.approve(address(s.branches[1].manager), MAX);
            s.token.approve(address(s.branches[0].sp), MAX);
            vm.stopPrank();
        }
    }

    /// Storage cannot take a memory struct holding an array in one assignment.
    function _keep(SystemAddrs memory m) internal {
        (s.deployer, s.token, s.frontends, s.darli) = (m.deployer, m.token, m.frontends, m.darli);
        (s.escrow, s.staking, s.router, s.registry, s.vault) = (m.escrow, m.staking, m.router, m.registry, m.vault);
        for (uint256 i = 0; i < m.branches.length; i++) {
            s.branches.push(m.branches[i]);
        }
    }

    function _supplyIsTheBranchesDebt(string memory when) internal view {
        uint256 debt = s.branches[0].manager.ledger().aggDebt + s.branches[1].manager.ledger().aggDebt;
        assertEq(s.token.totalSupply(), debt, string.concat("I-1: supply == the branches' debt, ", when));
    }

    function _open(uint256 b, address who, uint256 coll, uint256 debt, uint256 rate) internal returns (uint256) {
        vm.prank(who);
        return s.branches[b].manager.openTrove(who, coll, debt, rate, 0, MAX, 0, 0);
    }

    function test_theDeploymentIsSealedAtThePredictedAddresses() public view {
        assertEq(address(s.deployer.stable()), address(s.token), "D1: the token is where every branch expects it");
        assertTrue(s.deployer.deployed());
        for (uint256 i = 0; i < 2; i++) {
            assertTrue(s.token.isMinter(address(s.branches[i].manager)), "D1: every branch is a minter");
        }
        assertFalse(s.token.isMinter(address(s.registry)), "D1: nothing else is");
        assertFalse(s.token.isMinter(address(s.branches[0].settlement)));
        assertEq(s.deployer.observedSqrtPriceX96(), s.deployer.targetSqrtPriceX96(), "D2: the pool at par");
        this.checkWiring(s, p);
    }

    function test_aComponentBuiltForAnotherAddressIsFoundBeforeSealing() public {
        SystemAddrs memory bad = s;
        bad.branches = new BranchAddrs[](2);
        bad.branches[0] = s.branches[0];
        bad.branches[1] = s.branches[1];
        // a settlement built for the wrong branch: the branch still names its own, so the link does not close
        bad.branches[1].settlement = new BranchSettlement(ISettlementHooks(address(s.branches[0].manager)));
        vm.expectRevert(abi.encodeWithSelector(WiringMismatch.selector, "branch parts", 1));
        this.checkWiring(bad, p);
        SystemParams memory other = p;
        other.frontendShare = 4 * PCT;
        vm.expectRevert(abi.encodeWithSelector(WiringMismatch.selector, "frontends", 0));
        this.checkWiring(s, other);
    }

    function test_aDeployedSystemLivesThroughEveryPartOfItsLife() public {
        // borrowing on both branches, and a Stability Pool on the first
        uint256 a0 = _open(0, alice, 40 * E, 20_000 * E, 2 * PCT);
        _open(0, bob, 100 * E, 40_000 * E, 5 * PCT);
        _open(1, alice, 30 * E, 20_000 * E, 1 * PCT);
        uint256 w1 = _open(1, bob, 13 * E, 30_000 * E, 6 * PCT);
        vm.prank(bob);
        s.branches[0].sp.deposit(10_000 * E);
        _supplyIsTheBranchesDebt("after borrowing");

        // a redemption through the router is split across both branches, lowest rate first in each
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        s.token.transfer(carol, 5_000 * E);
        uint256 w = weth.balanceOf(carol);
        uint256 c = wbtc.balanceOf(carol);
        vm.prank(carol);
        uint256 redeemed = s.registry.redeem(5_000 * E, 10, E);
        assertEq(redeemed, 5_000 * E);
        assertGt(weth.balanceOf(carol), w, "R3: the first branch was redeemed from");
        assertGt(wbtc.balanceOf(carol), c, "R3: and so was the second");
        _supplyIsTheBranchesDebt("after a redemption");

        // revenue: the stakers' share of interest reaches a DARLI staker, through the router, over the next epoch
        s.darli.approve(address(s.staking), MAX);
        s.staking.stake(1_000 * E);
        vm.prank(keeper);
        s.branches[1].manager.applyPendingDebt(w1); // step A: interest minted, the escrow's share with it
        uint256 escrowed = s.token.balanceOf(address(s.escrow));
        assertGt(escrowed, 0, "V1: the escrow receives its share of interest");
        vm.prank(keeper);
        assertEq(s.router.routeRevenue(), escrowed, "V3: anyone routes it");
        vm.warp(block.timestamp + 14 days);
        uint256 got = s.staking.claim();
        assertLe(got, escrowed);
        assertGe(got + 1e12, escrowed, "V4, V5: the staker receives it within two epochs, less dust");

        // a liquidation on the second branch
        uint256 atIcr105 = 105 * PCT * s.branches[1].manager.troveDebt(w1) / s.branches[1].manager.troveColl(w1);
        feed1.set(atIcr105, PriceStatus.Valid); // the Trove at 105 %, the branch far above SCR
        vm.prank(keeper);
        s.branches[1].manager.liquidate(w1);
        _supplyIsTheBranchesDebt("after a liquidation");

        // the first branch shuts down and is settled; the second goes on
        feed0.set(1, PriceStatus.Failed);
        s.branches[0].manager.pokeOracle();
        assertTrue(s.branches[0].manager.ledger().shutdownAt != 0);
        assertEq(s.branches[1].manager.ledger().shutdownAt, 0, "one branch's shutdown is its own");
        vm.startPrank(keeper);
        s.branches[0].settlement.settleTrove(a0);
        s.branches[0].settlement.settleTrove(2);
        vm.stopPrank();
        assertTrue(s.branches[0].settlement.phaseOneComplete());
        uint256 claim = 2_000 * E;
        vm.prank(bob);
        s.token.transfer(carol, claim); // any USDarli claims the pot, whichever branch minted it
        uint256 before = weth.balanceOf(carol);
        vm.prank(carol);
        s.branches[0].settlement.redeemBadDebtColl(claim, 0);
        assertGt(weth.balanceOf(carol), before, "X8: a holder claims the settled branch's pot");
        _supplyIsTheBranchesDebt("after a settlement claim");
        // the live branch still borrows and is still redeemed; the shut-down one is left out of redemptions
        _open(1, carol, 30 * E, 10_000 * E, 3 * PCT);
        uint256 s1 = s.branches[1].manager.ledger().aggDebt;
        vm.prank(carol);
        s.registry.redeem(1_000 * E, 10, E);
        assertLt(s.branches[1].manager.ledger().aggDebt, s1, "R1: the live branch alone is redeemed");
        _supplyIsTheBranchesDebt("at the end");
    }
}
