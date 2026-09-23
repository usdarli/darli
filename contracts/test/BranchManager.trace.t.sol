// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BranchFixture} from "./BranchFixture.sol";
import {Trove, BranchLedger, PriceStatus} from "../src/Types.sol";

/// SPEC §4, §5, §6 and §8 against the reference model: every operation of a model-driven trace -- borrowing, redemption,
/// liquidation, redistribution, the Stability Pool, the shutdown triggers -- is replayed, and every acceptance, every refusal and
/// every recorded number must match the model's.
contract BranchManagerTraceTest is BranchFixture {
    struct Ops {
        uint256[] kind;
        uint256[] caller;
        uint256[] tid;
        uint256[] a;
        uint256[] b;
        uint256[] c;
        uint256[] d;
        uint256[] ok;
    }

    struct Expected {
        uint256[] ledger;
        uint256 ledgerLen;
        uint256[] troves;
        uint256[] trovesLen;
        uint256[] queue;
        uint256[] queueLen;
        uint256[] full;
    }

    uint256 troveCursor;
    uint256 queueCursor;

    // the trace is read into memory by the test itself: stored in a state variable, a trace this size would cost more
    // storage writes than the gas limit of setUp allows
    string constant TRACE = "test/vectors/branch_trace.json";

    function setUp() public {
        string memory json = vm.readFile(TRACE);
        deployBranch(2000 * E, 400_000 * E, 1_600_000 * E, E / 1000);
        uint256 funding = vm.parseJsonUint(json, ".config.funding");
        for (uint256 i = 0; i < vm.parseJsonUint(json, ".config.users"); i++) {
            weth.mint(account(i), funding);
        }
    }

    function _ops(string memory json) internal pure returns (Ops memory o) {
        o.kind = vm.parseJsonUintArray(json, ".ops.kind");
        o.caller = vm.parseJsonUintArray(json, ".ops.caller");
        o.tid = vm.parseJsonUintArray(json, ".ops.tid");
        o.a = vm.parseJsonUintArray(json, ".ops.a");
        o.b = vm.parseJsonUintArray(json, ".ops.b");
        o.c = vm.parseJsonUintArray(json, ".ops.c");
        o.d = vm.parseJsonUintArray(json, ".ops.d");
        o.ok = vm.parseJsonUintArray(json, ".ops.ok");
    }

    function _expected(string memory json) internal pure returns (Expected memory x) {
        x.ledger = vm.parseJsonUintArray(json, ".ledger");
        x.ledgerLen = vm.parseJsonUint(json, ".ledgerLen");
        x.troves = vm.parseJsonUintArray(json, ".troves");
        x.trovesLen = vm.parseJsonUintArray(json, ".trovesLen");
        x.queue = vm.parseJsonUintArray(json, ".queue");
        x.queueLen = vm.parseJsonUintArray(json, ".queueLen");
        x.full = vm.parseJsonUintArray(json, ".full");
    }

    /// One step. Returns whether the contracts accepted it. Kinds follow OPS in branch_trace.py.
    function _do(Ops memory o, uint256 i) internal returns (bool) {
        uint256 k = o.kind[i];
        address who = account(o.caller[i]);
        uint256 tid = o.tid[i];
        uint256 max = type(uint256).max;
        if (k == 10) {
            vm.warp(block.timestamp + o.a[i]);
            return true;
        }
        if (k == 11) {
            feed.set(o.a[i], feed.status());
            return true;
        }
        if (k == 12) {
            feed.set(feed.price(), PriceStatus(o.a[i]));
            return true;
        }
        vm.prank(who);
        if (k == 0) {
            try manager.openTrove(who, o.a[i], o.b[i], o.c[i], uint32(o.d[i]), max, 0, 0) returns (uint256 id) {
                assertEq(id, tid, "Trove ids are assigned differently from the model");
                return true;
            } catch {
                return false;
            }
        }
        if (k == 1) return _try(address(manager), abi.encodeCall(manager.borrow, (tid, o.a[i], max)));
        if (k == 2) return _try(address(manager), abi.encodeCall(manager.repay, (tid, o.a[i])));
        if (k == 3) return _try(address(manager), abi.encodeCall(manager.addColl, (tid, o.a[i])));
        if (k == 4) return _try(address(manager), abi.encodeCall(manager.withdrawColl, (tid, o.a[i])));
        if (k == 5) {
            int256 dc = o.c[i] & 1 == 1 ? -int256(o.a[i]) : int256(o.a[i]);
            int256 dd = o.c[i] & 2 == 2 ? -int256(o.b[i]) : int256(o.b[i]);
            return _try(address(manager), abi.encodeCall(manager.adjustTrove, (tid, dc, dd, max)));
        }
        if (k == 6) return _try(address(manager), abi.encodeCall(manager.adjustRate, (tid, o.a[i], max, 0, 0)));
        if (k == 7) return _try(address(manager), abi.encodeCall(manager.closeTrove, (tid)));
        if (k == 8) return _try(address(manager), abi.encodeCall(manager.applyPendingDebt, (tid)));
        if (k == 9) return _try(address(nft), abi.encodeCall(nft.transferFrom, (who, account(o.a[i]), tid)));
        if (k == 13) return _try(address(sp), abi.encodeCall(sp.deposit, (o.a[i])));
        if (k == 14) return _try(address(sp), abi.encodeCall(sp.withdraw, (o.a[i])));
        if (k == 15) return _try(address(stable), abi.encodeCall(stable.transfer, (account(o.a[i]), o.b[i])));
        if (k == 16) return _try(address(registry), abi.encodeCall(registry.claim, ()));
        if (k == 17) return _try(address(manager), abi.encodeCall(manager.triggerShutdown, ()));
        if (k == 18) return _try(address(manager), abi.encodeCall(manager.pokeOracle, ()));
        if (k == 19) return _try(address(manager), abi.encodeCall(manager.liquidate, (tid)));
        if (k == 20) return _try(address(sp), abi.encodeCall(sp.claim, ()));
        if (k == 21) return _try(address(manager), abi.encodeCall(manager.claimSurplus, ()));
        if (k == 22) {
            return _try(address(collRegistry), abi.encodeCall(collRegistry.redeem, (o.a[i], o.b[i], o.c[i])));
        }
        revert("unknown operation kind");
    }

    function _try(address target, bytes memory data) internal returns (bool ok) {
        (ok,) = target.call(data);
    }

    function _ledgerNow() internal view returns (uint256[] memory v) {
        BranchLedger memory l = manager.ledger();
        v = new uint256[](40 + 9 * N_ACCOUNTS);
        v[0] = l.aggDebt;
        v[1] = l.aggWeightedDebtSum;
        v[2] = l.lastAggUpdate;
        v[3] = l.badDebt;
        v[4] = l.shutdownAt;
        v[5] = l.oracleFailed ? 1 : 0;
        v[6] = manager.activeColl();
        v[7] = manager.defaultColl();
        v[8] = manager.gasPool();
        v[9] = manager.nOpen();
        v[10] = manager.totalStakes();
        v[11] = manager.settlePrice();
        v[12] = manager.unsettled();
        v[13] = stable.totalSupply();
        v[14] = stable.balanceOf(escrow);
        v[15] = stable.balanceOf(address(registry));
        v[16] = stable.balanceOf(address(sp));
        v[17] = weth.balanceOf(address(vault));
        v[18] = vault.accountedColl();
        v[19] = registry.totalDeposited();
        v[20] = registry.totalCredited();
        v[21] = sp.totalDeposits();
        v[22] = feed.lastGoodPrice();
        v[23] = manager.lColl();
        v[24] = manager.lDebt();
        v[25] = manager.lCollError();
        v[26] = manager.lDebtError();
        v[27] = manager.totalStakesSnapshot();
        v[28] = manager.totalCollSnapshot();
        v[29] = l.badDebtColl;
        _poolNow(v);
        for (uint256 j = 0; j < N_ACCOUNTS; j++) {
            _accountNow(v, j);
        }
    }

    function _poolNow(uint256[] memory v) internal view {
        uint256 scale = sp.currentScale();
        v[30] = sp.P();
        v[31] = scale;
        v[32] = sp.errColl();
        v[33] = sp.errYield();
        v[34] = sp.scaleToS(scale);
        v[35] = sp.scaleToB(scale);
        v[36] = weth.balanceOf(address(sp));
        v[37] = collRegistry.baseRate();
        v[38] = collRegistry.lastFeeOperationTime();
        v[39] = manager.lastZombieTroveId();
    }

    function _accountNow(uint256[] memory v, uint256 j) internal view {
        address a = account(j);
        uint256 o = 40 + 9 * j;
        v[o] = stable.balanceOf(a);
        v[o + 1] = weth.balanceOf(a);
        v[o + 2] = registry.claimable(a);
        v[o + 3] = manager.surplus(a);
        v[o + 4] = sp.compoundedDeposit(a);
        v[o + 5] = sp.pendingColl(a);
        v[o + 6] = sp.pendingYield(a);
        v[o + 7] = sp.claimableColl(a);
        v[o + 8] = sp.claimableYield(a);
    }

    function _troveNow(uint256 tid) internal view returns (uint256[12] memory v) {
        Trove memory t = manager.getTrove(tid);
        uint256 owner;
        if (uint8(t.status) == 1 || uint8(t.status) == 2) {
            owner = uint160(nft.ownerOf(tid)) - 0x1000 + 1;
        }
        v = [
            tid,
            t.coll,
            t.recordedDebt,
            t.annualRate,
            t.stake,
            uint256(t.lastDebtUpdate),
            uint256(t.lastRateAdjust),
            uint256(uint8(t.status)),
            manager.gasLeft(tid),
            owner,
            t.snapshotLColl,
            t.snapshotLDebt
        ];
    }

    function _compare(Expected memory x, uint256 step) internal {
        uint256[] memory v = _ledgerNow();
        for (uint256 j = 0; j < x.ledgerLen; j++) {
            if (v[j] != x.ledger[step * x.ledgerLen + j]) {
                emit log_named_uint("step", step);
                emit log_named_uint("ledger field", j);
                assertEq(v[j], x.ledger[step * x.ledgerLen + j], "ledger differs from the model");
            }
        }
        for (uint256 n = 0; n < x.trovesLen[step]; n++) {
            uint256 tid = x.troves[troveCursor];
            uint256[12] memory t = _troveNow(tid);
            for (uint256 f = 0; f < 12; f++) {
                if (t[f] != x.troves[troveCursor + f]) {
                    emit log_named_uint("step", step);
                    emit log_named_uint("trove", tid);
                    emit log_named_uint("trove field", f);
                    assertEq(t[f], x.troves[troveCursor + f], "Trove differs from the model");
                }
            }
            troveCursor += 12;
        }
        if (x.full[step] == 1) {
            assertEq(list.size(), x.queueLen[step], "R2: queue length differs from the model");
            uint256 id = list.last();
            for (uint256 q = 0; q < x.queueLen[step]; q++) {
                assertEq(id, x.queue[queueCursor + q], "R2: queue order differs from the model");
                id = list.prev(id);
            }
            queueCursor += x.queueLen[step];
        }
    }

    function test_diff_branchTraceMatchesModel() public {
        string memory json = vm.readFile(TRACE);
        Ops memory o = _ops(json);
        Expected memory x = _expected(json);
        assertGt(o.kind.length, 500, "too short to be a differential test");
        for (uint256 i = 0; i < o.kind.length; i++) {
            bool ok = _do(o, i);
            if (ok != (o.ok[i] == 1)) {
                emit log_named_uint("step", i);
                emit log_named_uint("kind", o.kind[i]);
                assertEq(ok, o.ok[i] == 1, "the contracts and the model disagree on whether this operation is allowed");
            }
            _compare(x, i);
        }
        assertEq(troveCursor, x.troves.length, "not every recorded Trove was compared");
        assertEq(queueCursor, x.queue.length, "not every recorded queue was compared");
        assertTrue(manager.ledger().shutdownAt != 0, "the trace ends with a shut-down branch");
    }
}
