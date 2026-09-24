// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LPFeeAccounting} from "../src/liquidity/LPFeeAccounting.sol";

/// The vault's books alone, driven directly: the pool is not involved, so any fee amount can be fed in.
contract LPFeeAccountingHarness is LPFeeAccounting {
    mapping(address => uint256[3]) internal _claimed;

    function deposit(address who, uint256 liquidity) external {
        require(liquidity > 0, "zero");
        _addShares(who, liquidity);
    }

    function withdraw(address who, uint256 liquidity) external {
        require(liquidity > 0, "zero");
        _removeShares(who, liquidity);
    }

    function fees(uint256 f0, uint256 f1) external {
        _collectFees(f0, f1);
    }

    function incentive(uint256 amount) external {
        require(amount > 0, "zero");
        _notifyIncentive(amount);
    }

    function claim(address who) external {
        uint256[3] memory out = _claimOwed(who);
        for (uint256 k = 0; k < 3; k++) {
            _claimed[who][k] += out[k];
        }
    }

    function claimedOf(address who) external view returns (uint256[3] memory) {
        return _claimed[who];
    }
}

/// SPEC V6 against the reference model: every operation of a model-driven trace (`contracts/script/lp_trace.py`) --
/// deposits, withdrawals, fees in both tokens, reward tokens streamed over fixed epochs, claims, time -- is replayed on
/// the vault's accounting, and every acceptance, refusal and recorded number must match the model's.
contract LPFeeAccountingTraceTest is Test {
    string constant TRACE = "test/vectors/lp_trace.json";
    uint256 constant N = 4;
    LPFeeAccountingHarness books;

    function holder(uint256 i) internal pure returns (address) {
        return address(uint160(0x4000 + i));
    }

    function setUp() public {
        vm.warp(vm.parseJsonUint(vm.readFile(TRACE), ".config.start"));
        books = new LPFeeAccountingHarness();
    }

    function _do(uint256 k, address who, uint256 a, uint256 b) internal returns (bool ok) {
        if (k == 5) {
            vm.warp(block.timestamp + a);
            return true;
        }
        bytes memory data;
        if (k == 0) data = abi.encodeCall(books.deposit, (who, a));
        else if (k == 1) data = abi.encodeCall(books.withdraw, (who, a));
        else if (k == 2) data = abi.encodeCall(books.fees, (a, b));
        else if (k == 3) data = abi.encodeCall(books.incentive, (a));
        else data = abi.encodeCall(books.claim, (who));
        (ok,) = address(books).call(data);
    }

    struct Trace {
        uint256[] kind;
        uint256[] who;
        uint256[] a;
        uint256[] b;
        uint256[] ok;
        uint256[] ledger;
        uint256 len;
    }

    function _stateNow(uint256 len) internal view returns (uint256[] memory v) {
        v = new uint256[](len);
        v[0] = books.totalShares();
        for (uint256 k = 0; k < 3; k++) {
            v[1 + k] = books.acc(k);
            v[4 + k] = books.unassigned(k);
        }
        (v[7], v[8], v[9], v[10]) = books.stream();
        for (uint256 i = 0; i < N; i++) {
            _holderNow(v, i);
        }
    }

    function _holderNow(uint256[] memory v, uint256 i) internal view {
        address h = holder(i);
        uint256 o = 11 + 10 * i;
        v[o] = books.shares(h);
        uint256[3] memory snap = books.snapOf(h);
        uint256[3] memory owed = books.owedOf(h);
        uint256[3] memory got = books.claimedOf(h);
        for (uint256 k = 0; k < 3; k++) {
            (v[o + 1 + k], v[o + 4 + k], v[o + 7 + k]) = (snap[k], owed[k], got[k]);
        }
    }

    function _trace() internal view returns (Trace memory t) {
        string memory json = vm.readFile(TRACE);
        t.kind = vm.parseJsonUintArray(json, ".ops.kind");
        t.who = vm.parseJsonUintArray(json, ".ops.who");
        t.a = vm.parseJsonUintArray(json, ".ops.a");
        t.b = vm.parseJsonUintArray(json, ".ops.b");
        t.ok = vm.parseJsonUintArray(json, ".ops.ok");
        t.ledger = vm.parseJsonUintArray(json, ".ledger");
        t.len = vm.parseJsonUint(json, ".ledgerLen");
    }

    function test_diff_lpAccountingMatchesModel() public {
        Trace memory t = _trace();
        assertGt(t.kind.length, 300, "too short to be a differential test");
        for (uint256 i = 0; i < t.kind.length; i++) {
            bool accepted = _do(t.kind[i], holder(t.who[i]), t.a[i], t.b[i]);
            if (accepted != (t.ok[i] == 1)) {
                emit log_named_uint("step", i);
                assertEq(
                    accepted, t.ok[i] == 1, "the vault and the model disagree on whether this operation is allowed"
                );
            }
            uint256[] memory v = _stateNow(t.len);
            for (uint256 j = 0; j < t.len; j++) {
                if (v[j] != t.ledger[i * t.len + j]) {
                    emit log_named_uint("step", i);
                    emit log_named_uint("field", j);
                    assertEq(v[j], t.ledger[i * t.len + j], "vault books differ from the model");
                }
            }
        }
    }
}
