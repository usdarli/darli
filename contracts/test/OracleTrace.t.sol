// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DualSourcePriceFeed} from "../src/oracle/DualSourcePriceFeed.sol";
import {PoolTwapMath} from "../src/oracle/PoolTwapMath.sol";
import {PriceStatus} from "../src/Types.sol";
import {MockSource, MockSequencer, MockPoolSource} from "./mocks/OracleMocks.sol";

/// The pool source's arithmetic behind an external call, so that an overflow is observed as a revert.
contract PoolTwapMathHarness {
    function quote(int256 tickDelta, uint256 splDelta, uint32 window, bool wethIs0, uint8 decimals)
        external
        pure
        returns (bool, uint256, uint256)
    {
        return PoolTwapMath.quote(tickDelta, splDelta, window, wethIs0, decimals);
    }

    function combine(uint256[4] memory prices, uint256[4] memory weights, uint256 n, uint256 minDepth)
        external
        pure
        returns (uint256)
    {
        return PoolTwapMath.combine(prices, weights, n, minDepth);
    }
}

/// SPEC O2, O3, O7, O8 against the reference model. `contracts/script/oracle_trace.py` drives the model's two-source
/// feed through source answers, pool answers, sequencer outages and time; every step is replayed on
/// DualSourcePriceFeed with mock sources, and the status and price of every read, lastGoodPrice, lastValidAt and the
/// three markers must match. The pool arithmetic is checked on its own vectors, wei for wei.
contract OracleTraceTest is Test {
    string constant TRACE = "test/vectors/oracle_trace.json";
    string constant TWAP = "test/vectors/pool_twap.json";

    MockSource src;
    MockPoolSource pool;
    MockSequencer seq;
    DualSourcePriceFeed feed;

    function setUp() public {
        string memory json = vm.readFile(TRACE);
        vm.warp(vm.parseJsonUint(json, ".config.seqSince"));
        seq = new MockSequencer();
        vm.warp(vm.parseJsonUint(json, ".config.start"));
        src = new MockSource(int256(vm.parseJsonUint(json, ".config.price0")), 0);
        pool = new MockPoolSource(vm.parseJsonUint(json, ".config.pool0"));
        feed = new DualSourcePriceFeed(
            src,
            pool,
            seq,
            vm.parseJsonUint(json, ".config.stale"),
            vm.parseJsonUint(json, ".config.timeout"),
            vm.parseJsonUint(json, ".config.grace"),
            200_000,
            50_000,
            400_000,
            vm.parseJsonUint(json, ".config.maxDeviation")
        );
    }

    /// @return status 9 when the step is not a read
    function _do(uint256 k, uint256 a, uint256 b) internal returns (uint256 status, uint256 price) {
        status = 9;
        if (k == 0) {
            vm.warp(block.timestamp + a);
        } else if (k == 1) {
            src.set(int256(a), b);
        } else if (k == 2) {
            src.setMode(MockSource.Mode(a));
        } else if (k == 3) {
            pool.setValue(a);
        } else if (k == 4) {
            pool.setAvailable(a == 1);
        } else if (k == 5) {
            pool.setMode(a);
        } else if (k == 6) {
            seq.set(a == 1);
        } else {
            PriceStatus s;
            (price, s) = feed.fetchPrice();
            status = uint256(s);
        }
    }

    function test_diff_oracleMatchesModel() public {
        string memory json = vm.readFile(TRACE);
        uint256[] memory kind = vm.parseJsonUintArray(json, ".ops.kind");
        uint256[] memory a = vm.parseJsonUintArray(json, ".ops.a");
        uint256[] memory b = vm.parseJsonUintArray(json, ".ops.b");
        uint256[] memory ledger = vm.parseJsonUintArray(json, ".ledger");
        uint256 len = vm.parseJsonUint(json, ".ledgerLen");
        assertGt(kind.length, 300, "too short to be a differential test");
        for (uint256 i = 0; i < kind.length; i++) {
            (uint256 status, uint256 price) = _do(kind[i], a[i], b[i]);
            uint256[7] memory v = [
                feed.lastGoodPrice(),
                feed.lastValidAt(),
                feed.invalidSince(),
                feed.poolInvalidSince(),
                feed.disagreeSince(),
                status,
                price
            ];
            for (uint256 j = 0; j < len; j++) {
                if (v[j] != ledger[i * len + j]) {
                    emit log_named_uint("step", i);
                    emit log_named_uint("field", j);
                    assertEq(v[j], ledger[i * len + j], "O8: the feed differs from the model");
                }
            }
        }
    }

    function test_diff_poolTwapMathMatchesModel() public {
        PoolTwapMathHarness h = new PoolTwapMathHarness();
        string memory json = vm.readFile(TWAP);
        int256[] memory tickDelta = vm.parseJsonIntArray(json, ".quotes.tickDelta");
        uint256[] memory spl = vm.parseJsonUintArray(json, ".quotes.splDelta");
        uint256[] memory window = vm.parseJsonUintArray(json, ".quotes.window");
        uint256[] memory wethIs0 = vm.parseJsonUintArray(json, ".quotes.wethIs0");
        uint256[] memory dec = vm.parseJsonUintArray(json, ".quotes.decimals");
        uint256[] memory ok = vm.parseJsonUintArray(json, ".quotes.ok");
        uint256[] memory price = vm.parseJsonUintArray(json, ".quotes.price");
        uint256[] memory weight = vm.parseJsonUintArray(json, ".quotes.weight");
        uint256 n = tickDelta.length;
        assertGt(n, 300);
        uint256[] memory qp = new uint256[](n);
        uint256[] memory qw = new uint256[](n);
        bool[] memory qok = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            (qok[i], qp[i], qw[i]) = h.quote(tickDelta[i], spl[i], uint32(window[i]), wethIs0[i] == 1, uint8(dec[i]));
            assertEq(qok[i], ok[i] == 1, "O7: which pools are left out");
            assertEq(qp[i], price[i], "O7: a pool's price");
            assertEq(qw[i], weight[i], "O7: a pool's weight");
        }
        _combos(h, json, qp, qw, qok);
        _medians(h, json);
    }

    /// Crafted: equal weights in shuffled order and exact half splits, where the order and the tie rule decide.
    function _medians(PoolTwapMathHarness h, string memory json) internal view {
        uint256[] memory prices = vm.parseJsonUintArray(json, ".medians.prices");
        uint256[] memory weights = vm.parseJsonUintArray(json, ".medians.weights");
        uint256[] memory count = vm.parseJsonUintArray(json, ".medians.count");
        uint256[] memory minDepth = vm.parseJsonUintArray(json, ".medians.minDepth");
        uint256[] memory want = vm.parseJsonUintArray(json, ".medians.price");
        for (uint256 c = 0; c < count.length; c++) {
            uint256[4] memory p;
            uint256[4] memory w;
            for (uint256 j = 0; j < 4; j++) {
                (p[j], w[j]) = (prices[4 * c + j], weights[4 * c + j]);
            }
            assertEq(h.combine(p, w, count[c], minDepth[c]), want[c], "O7: the weighted median, sorted, lower half");
        }
    }

    function _combos(
        PoolTwapMathHarness h,
        string memory json,
        uint256[] memory qp,
        uint256[] memory qw,
        bool[] memory qok
    ) internal view {
        uint256[] memory idx = vm.parseJsonUintArray(json, ".combos.idx");
        uint256[] memory count = vm.parseJsonUintArray(json, ".combos.count");
        uint256[] memory minDepth = vm.parseJsonUintArray(json, ".combos.minDepth");
        uint256[] memory want = vm.parseJsonUintArray(json, ".combos.price");
        for (uint256 c = 0; c < count.length; c++) {
            uint256[4] memory p;
            uint256[4] memory w;
            uint256 k;
            for (uint256 j = 0; j < count[c]; j++) {
                uint256 q = idx[4 * c + j];
                if (qok[q]) {
                    (p[k], w[k]) = (qp[q], qw[q]);
                    k++;
                }
            }
            uint256 got;
            got = h.combine(p, w, k, minDepth[c]);
            assertEq(got, want[c], "O7: the liquidity-weighted median");
        }
    }
}
