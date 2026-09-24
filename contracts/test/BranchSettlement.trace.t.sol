// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BranchFixture} from "./BranchFixture.sol";
import {Trove, BranchLedger, PriceStatus} from "../src/Types.sol";

/// SPEC §9 against the reference model: four model-driven traces (`contracts/script/settle_trace.py`) take a branch
/// through a live life, a shutdown and its whole settlement -- an oracle failure with write-offs, an undone write-off
/// and late settlements; under-water Troves absorbed by the owners' surplus; a haircut for the holders; an empty pot
/// whose claim units are paid only by late settlements. Every acceptance, every refusal and every recorded number of
/// the branch, the settlement accounts and every account must match the model's.
contract BranchSettlementTraceTest is BranchFixture {
    struct Ops {
        uint256[] kind;
        uint256[] caller;
        uint256[] tid;
        uint256[] a;
        uint256[] b;
        uint256[] c;
        uint256[] d;
        uint256[] ok;
        uint256[] batch;
        uint256[] batchLen;
    }

    struct Expected {
        uint256[] ledger;
        uint256 ledgerLen;
        uint256[] troves;
        uint256[] trovesLen;
    }

    uint256 constant TROVE_LEN = 8;
    uint256 troveCursor;
    uint256 batchCursor;

    function setUp() public {
        deployBranch(2000 * E, 400_000 * E, 1_600_000 * E, E / 1000);
    }

    function _fund(string memory json) internal {
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
        o.batch = vm.parseJsonUintArray(json, ".batch");
        o.batchLen = vm.parseJsonUintArray(json, ".batchLen");
    }

    function _expected(string memory json) internal pure returns (Expected memory x) {
        x.ledger = vm.parseJsonUintArray(json, ".ledger");
        x.ledgerLen = vm.parseJsonUint(json, ".ledgerLen");
        x.troves = vm.parseJsonUintArray(json, ".troves");
        x.trovesLen = vm.parseJsonUintArray(json, ".trovesLen");
    }

    /// One step; kinds follow OPS in settle_trace.py. Returns whether the contracts accepted it.
    function _do(Ops memory o, uint256 i) internal returns (bool ok) {
        uint256 k = o.kind[i];
        address who = account(o.caller[i]);
        uint256 tid = o.tid[i];
        if (k == 5) {
            feed.set(o.a[i], feed.status());
            return true;
        }
        if (k == 6) {
            feed.set(feed.price(), PriceStatus(o.a[i]));
            return true;
        }
        if (k == 9) {
            vm.warp(block.timestamp + o.a[i]);
            return true;
        }
        address target;
        bytes memory data;
        if (k == 0) {
            target = address(manager);
            data = abi.encodeCall(
                manager.openTrove, (who, o.a[i], o.b[i], o.c[i], uint32(o.d[i]), type(uint256).max, 0, 0)
            );
        } else if (k == 1) {
            (target, data) = (address(sp), abi.encodeCall(sp.deposit, (o.a[i])));
        } else if (k == 2) {
            (target, data) = (address(sp), abi.encodeCall(sp.withdraw, (o.a[i])));
        } else if (k == 3) {
            (target, data) = (address(sp), abi.encodeCall(sp.claim, ()));
        } else if (k == 4) {
            (target, data) = (address(manager), abi.encodeCall(manager.liquidate, (tid)));
        } else if (k == 7) {
            (target, data) = (address(manager), abi.encodeCall(manager.pokeOracle, ()));
        } else if (k == 8) {
            (target, data) = (address(manager), abi.encodeCall(manager.triggerShutdown, ()));
        } else if (k == 10) {
            (target, data) = (address(stable), abi.encodeCall(stable.transfer, (account(o.a[i]), o.b[i])));
        } else if (k == 18) {
            (target, data) = (address(manager), abi.encodeCall(manager.claimSurplus, ()));
        } else {
            (target, data) = (address(settlement), _settlementCall(o, i));
        }
        vm.prank(who);
        (ok,) = target.call(data);
    }

    function _settlementCall(Ops memory o, uint256 i) internal returns (bytes memory) {
        uint256 k = o.kind[i];
        if (k == 11) return abi.encodeCall(settlement.settleTrove, (o.tid[i]));
        if (k == 12) {
            uint256[] memory ids = new uint256[](o.batchLen[i]);
            for (uint256 j = 0; j < ids.length; j++) {
                ids[j] = o.batch[batchCursor + j];
            }
            batchCursor += ids.length;
            return abi.encodeCall(settlement.settleTroves, (ids));
        }
        if (k == 13) return abi.encodeCall(settlement.writeOff, (o.tid[i]));
        if (k == 14) return abi.encodeCall(settlement.redeemBadDebtColl, (o.a[i], o.b[i]));
        if (k == 15) return abi.encodeCall(settlement.repayBadDebt, (o.a[i]));
        if (k == 16) return abi.encodeCall(settlement.claimLate, ());
        if (k == 17) return abi.encodeCall(settlement.claimSurplus, ());
        revert("unknown operation kind");
    }

    function _ledgerNow(uint256 len) internal view returns (uint256[] memory v) {
        v = new uint256[](len);
        BranchLedger memory l = manager.ledger();
        v[0] = l.aggDebt;
        v[1] = l.aggWeightedDebtSum;
        v[2] = l.badDebt;
        v[3] = l.badDebtColl;
        v[4] = l.shutdownAt;
        v[5] = l.oracleFailed ? 1 : 0;
        v[6] = manager.activeColl();
        v[7] = manager.defaultColl();
        v[8] = manager.gasPool();
        v[9] = manager.nOpen();
        v[10] = manager.unsettled();
        v[11] = manager.settlePrice();
        v[12] = manager.totalStakes();
        v[13] = stable.totalSupply();
        v[14] = weth.balanceOf(address(vault));
        v[15] = vault.accountedColl();
        v[16] = sp.totalDeposits();
        v[17] = manager.lastZombieTroveId();
        _settlementNow(v);
        for (uint256 j = 0; j < N_ACCOUNTS; j++) {
            _accountNow(v, j);
        }
    }

    function _settlementNow(uint256[] memory v) internal view {
        v[18] = settlement.claimUnits();
        v[19] = settlement.take();
        v[20] = settlement.latePerUnit();
        v[21] = settlement.latePool();
        v[22] = settlement.parTotal();
        v[23] = settlement.contribTotal();
        v[24] = settlement.settleSurplusPool();
        v[25] = settlement.settleSurplusGross();
        v[26] = settlement.settleShortTotal();
        v[27] = settlement.surplusKeep();
        v[28] = settlement.keepFixed() ? 1 : 0;
    }

    function _accountNow(uint256[] memory v, uint256 j) internal view {
        address a = account(j);
        uint256 o = 29 + 8 * j;
        v[o] = stable.balanceOf(a);
        v[o + 1] = weth.balanceOf(a);
        v[o + 2] = manager.surplus(a);
        v[o + 3] = settlement.grossOf(a);
        v[o + 4] = settlement.surplusPaid(a);
        v[o + 5] = settlement.unitsOf(a);
        v[o + 6] = settlement.latePaid(a);
        v[o + 7] = registry.claimable(a);
    }

    function _troveNow(uint256 tid) internal view returns (uint256[TROVE_LEN] memory v) {
        Trove memory t = manager.getTrove(tid);
        (uint256 debt, uint256 need, bool set) = settlement.writtenOff(tid);
        v = [tid, t.coll, t.recordedDebt, uint256(uint8(t.status)), manager.gasLeft(tid), set ? 1 : 0, debt, need];
    }

    function _compare(Expected memory x, uint256 step) internal {
        uint256[] memory v = _ledgerNow(x.ledgerLen);
        for (uint256 j = 0; j < x.ledgerLen; j++) {
            if (v[j] != x.ledger[step * x.ledgerLen + j]) {
                emit log_named_uint("step", step);
                emit log_named_uint("ledger field", j);
                assertEq(v[j], x.ledger[step * x.ledgerLen + j], "settlement state differs from the model");
            }
        }
        for (uint256 n = 0; n < x.trovesLen[step]; n++) {
            uint256[TROVE_LEN] memory t = _troveNow(x.troves[troveCursor]);
            for (uint256 f = 0; f < TROVE_LEN; f++) {
                if (t[f] != x.troves[troveCursor + f]) {
                    emit log_named_uint("step", step);
                    emit log_named_uint("trove", t[0]);
                    emit log_named_uint("trove field", f);
                    assertEq(t[f], x.troves[troveCursor + f], "Trove differs from the model");
                }
            }
            troveCursor += TROVE_LEN;
        }
    }

    function _replay(string memory path) internal {
        string memory json = vm.readFile(path);
        _fund(json);
        Ops memory o = _ops(json);
        Expected memory x = _expected(json);
        assertGt(o.kind.length, 100, "too short to be a differential test");
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
        assertEq(batchCursor, o.batch.length, "not every batch was replayed");
        assertTrue(settlement.phaseOneComplete(), "every trace ends with phase 1 complete");
    }

    function test_diff_settlementMatchesModel_oracleFailure() public {
        _replay("test/vectors/settle_trace_failure.json");
    }

    function test_diff_settlementMatchesModel_surplusAbsorbs() public {
        _replay("test/vectors/settle_trace_absorb.json");
    }

    function test_diff_settlementMatchesModel_holdersHaircut() public {
        _replay("test/vectors/settle_trace_haircut.json");
    }

    function test_diff_settlementMatchesModel_emptyPot() public {
        _replay("test/vectors/settle_trace_empty.json");
    }
}
