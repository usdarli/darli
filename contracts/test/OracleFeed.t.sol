// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {SingleSourcePriceFeed} from "../src/oracle/SingleSourcePriceFeed.sol";
import {IFeedSource, ISequencerGuard} from "../src/interfaces/IPriceFeed.sol";
import {PriceStatus} from "../src/Types.sol";
import {MockSource, NestedProxySource, MockSequencer, Heuristic64Feed} from "./mocks/OracleMocks.sol";

/// Mirrors `model/test_scenarios.py` scenario_20 (a, b, c, d, h, i) and measures the gas guard (e, e2, f) on a real EVM.
contract OracleFeedTest is Test {
    uint256 constant STALE = 3 hours;
    uint256 constant TIMEOUT = 24 hours;
    uint256 constant GRACE = 1 hours;
    int256 constant PRICE = 2000e18;

    MockSource src;
    MockSequencer seq;
    SingleSourcePriceFeed feed;

    function setUp() public {
        vm.warp(1_700_000_000);
        src = new MockSource(PRICE, 0);
        seq = new MockSequencer();
        vm.warp(block.timestamp + 30 days); // sequencer has been up for a long time
        src.push();
        feed = new SingleSourcePriceFeed(src, seq, STALE, TIMEOUT, GRACE, 200_000, 50_000);
    }

    function _status() internal returns (PriceStatus s) { (, s) = feed.fetchPrice(); }

    // (a) an outage far longer than staleness AND timeout must never end in Failed
    function test_a_sequencerOutageDoesNotFail() public {
        seq.set(false);
        skip(30 hours);
        assertEq(uint8(_status()), uint8(PriceStatus.NetworkUnstable));
        seq.set(true);
        skip(GRACE - 1);
        assertEq(uint8(_status()), uint8(PriceStatus.NetworkUnstable), "grace");
        skip(2);
        assertEq(uint8(_status()), uint8(PriceStatus.PriceInvalid), "31h old answer, network up for 1h only");
        src.push();
        assertEq(uint8(_status()), uint8(PriceStatus.Valid));
    }

    // (b) dead feed, healthy network
    function test_b_deadFeedFailsExactlyAfterTimeout() public {
        skip(STALE + 1);
        assertEq(uint8(_status()), uint8(PriceStatus.PriceInvalid));
        skip(TIMEOUT - STALE - 1);
        assertEq(uint8(_status()), uint8(PriceStatus.PriceInvalid), "exactly TIMEOUT old: not yet");
        skip(1);
        (uint256 p, PriceStatus s) = feed.fetchPrice();
        assertEq(uint8(s), uint8(PriceStatus.Failed));
        assertEq(p, uint256(PRICE), "last good price");
    }

    // (c) malformed answers: two observations TIMEOUT apart, a healthy one in between resets the clock
    function test_c_malformedNeedsTwoObservations() public {
        src.set(0, block.timestamp);
        assertEq(uint8(_status()), uint8(PriceStatus.PriceInvalid));
        assertEq(feed.invalidSince(), block.timestamp);
        skip(TIMEOUT - 1); src.set(0, block.timestamp);
        assertEq(uint8(_status()), uint8(PriceStatus.PriceInvalid));
        src.set(2100e18, block.timestamp);
        assertEq(uint8(_status()), uint8(PriceStatus.Valid));
        assertEq(feed.invalidSince(), 0);
        src.set(-5, block.timestamp);
        assertEq(uint8(_status()), uint8(PriceStatus.PriceInvalid));
        skip(TIMEOUT - 1); src.set(-5, block.timestamp);
        assertEq(uint8(_status()), uint8(PriceStatus.PriceInvalid));
        skip(1); src.set(-5, block.timestamp);
        (uint256 p, PriceStatus s) = feed.fetchPrice();
        assertEq(uint8(s), uint8(PriceStatus.Failed));
        assertEq(p, 2100e18);
    }

    // (d) a marker written inside a reverting transaction does not survive
    function fetchThenRevert() external { feed.fetchPrice(); revert("borrower op refused"); }

    function test_d_markerDoesNotSurviveRevert() public {
        src.setMode(MockSource.Mode.Revert);
        vm.expectRevert();
        this.fetchThenRevert();
        assertEq(feed.invalidSince(), 0);
    }

    // (h) + robustness of the low-level read
    function test_h_futureTimestamp_shortReturn_noCode_areMalformed() public {
        src.set(PRICE, block.timestamp + 600);
        assertEq(uint8(_status()), uint8(PriceStatus.PriceInvalid), "future timestamp");
        src.set(PRICE, block.timestamp);
        assertEq(uint8(_status()), uint8(PriceStatus.Valid));
        src.setMode(MockSource.Mode.ShortReturn);
        assertEq(uint8(_status()), uint8(PriceStatus.PriceInvalid), "32 bytes instead of 64 (try/catch would NOT catch this)");
        src.setMode(MockSource.Mode.Ok);
        vm.etch(address(src), "");
        assertEq(uint8(_status()), uint8(PriceStatus.PriceInvalid), "no code at the source (try/catch would revert)");
    }

    // (i) the real distance between a Valid observation and Failed is TIMEOUT - staleness
    function test_i_minimumDistanceValidToFailed() public {
        skip(STALE);
        assertEq(uint8(_status()), uint8(PriceStatus.Valid));
        uint256 tValid = block.timestamp;
        skip(TIMEOUT - STALE);
        assertEq(uint8(_status()), uint8(PriceStatus.PriceInvalid));
        skip(1);
        assertEq(uint8(_status()), uint8(PriceStatus.Failed));
        assertEq(block.timestamp - tValid, TIMEOUT - STALE + 1);
    }

    function test_constructorRejectsUnhealthyFeedAndBadConfig() public {
        MockSource bad = new MockSource(0, 0);
        vm.expectRevert(SingleSourcePriceFeed.FeedUnhealthyAtCreation.selector);
        new SingleSourcePriceFeed(bad, ISequencerGuard(address(0)), STALE, TIMEOUT, GRACE, 200_000, 50_000);
        vm.expectRevert(SingleSourcePriceFeed.BadConfig.selector);
        new SingleSourcePriceFeed(src, ISequencerGuard(address(0)), TIMEOUT, TIMEOUT, GRACE, 200_000, 50_000);
        // a stipend below the honest cost of the source is caught at birth, not in production
        MockSource hungry = new MockSource(PRICE, 300_000);
        vm.expectRevert(SingleSourcePriceFeed.FeedUnhealthyAtCreation.selector);
        new SingleSourcePriceFeed(hungry, ISequencerGuard(address(0)), STALE, TIMEOUT, GRACE, 200_000, 50_000);
    }

    // ---------------------------------------------------------------- gas guard, measured on the EVM

    /// Sweeps the gas given to fetchPrice. Returns how many calls ended in a NON-Valid observation of a healthy
    /// source (= successful griefing) and how many reverted.
    function _sweep(address target, uint256 from, uint256 to, uint256 step) internal returns (uint256 poisoned, uint256 reverted) {
        for (uint256 g = from; g <= to; g += step) {
            (bool ok, bytes memory ret) = target.call{gas: g}(abi.encodeWithSignature("fetchPrice()"));
            if (!ok) { reverted++; continue; }
            (, PriceStatus s) = abi.decode(ret, (uint256, PriceStatus));
            if (s != PriceStatus.Valid) poisoned++;
        }
    }

    // (e) the specified guard: no gas amount makes a healthy feed look malformed (flat and nested, cheap and hungry)
    function test_e_stipendGuardCannotBeGriefed() public {
        MockSource hungry = new MockSource(PRICE, 1_000_000);
        NestedProxySource proxy = new NestedProxySource(hungry);
        IFeedSource[3] memory sources = [IFeedSource(src), IFeedSource(hungry), IFeedSource(proxy)];
        uint256[3] memory limits = [uint256(200_000), 1_300_000, 1_300_000];
        for (uint256 i = 0; i < 3; i++) {
            SingleSourcePriceFeed f =
                new SingleSourcePriceFeed(sources[i], ISequencerGuard(address(0)), STALE, TIMEOUT, GRACE, limits[i], 50_000);
            (uint256 poisoned, uint256 reverted) = _sweep(address(f), 30_000, 1_800_000, 2_777);
            assertEq(poisoned, 0, "healthy feed observed as malformed");
            assertGt(reverted, 0, "sweep never hit the guard: test is blind");
            assertEq(f.invalidSince(), 0);
        }
    }

    // (e2) model finding: nested + gas-hungry source vs the 1/64 heuristic
    function test_e2_heuristic64_nestedHungrySource() public {
        MockSource hungry = new MockSource(PRICE, 1_000_000);
        NestedProxySource proxy = new NestedProxySource(hungry);
        Heuristic64Feed h = new Heuristic64Feed(proxy);
        (uint256 poisoned, uint256 reverted) = _sweep(address(h), 600_000, 1_200_000, 997);
        console2.log("heuristic64 / nested hungry: poisoned", poisoned, "reverted", reverted);
        // flat (non nested) control
        Heuristic64Feed hFlat = new Heuristic64Feed(hungry);
        (uint256 poisonedFlat,) = _sweep(address(hFlat), 600_000, 1_200_000, 997);
        console2.log("heuristic64 / flat hungry:   poisoned", poisonedFlat);
        // Confirms the reference-model finding on a real EVM: the proxy hands its own 1/64 back, the caller ends up
        // with ~2/64, the heuristic does not fire, and a HEALTHY feed gets a malformed marker.
        assertGt(poisoned, 0, "expected the nested hungry source to defeat the 1/64 heuristic");
        assertEq(poisonedFlat, 0, "flat call: the heuristic holds");
    }

    // (f) a source that burns everything it is given
    function test_f_gasBurningSource() public {
        src.setMode(MockSource.Mode.BurnAllGas);
        // specified guard: observable, reaches Failed
        assertEq(uint8(_status()), uint8(PriceStatus.PriceInvalid));
        skip(TIMEOUT);
        assertEq(uint8(_status()), uint8(PriceStatus.Failed));
        // 1/64 heuristic: every observation reverts, whatever the gas -> never observable
        Heuristic64Feed h = new Heuristic64Feed(src);
        (uint256 poisoned, uint256 reverted) = _sweep(address(h), 100_000, 30_000_000, 1_499_999);
        assertEq(poisoned, 0, "heuristic: the burner can never be observed");
        assertEq(reverted, 20, "heuristic: every observation reverts -> the branch can never reach Failed");
    }
}
