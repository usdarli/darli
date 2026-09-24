// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DarliToken} from "../src/revenue/DarliToken.sol";
import {DarliStaking} from "../src/revenue/DarliStaking.sol";
import {RevenueRouter} from "../src/revenue/RevenueRouter.sol";
import {InterestEscrow} from "../src/core/InterestEscrow.sol";
import {IInterestEscrow, IDarliStaking} from "../src/interfaces/ICore.sol";
import {MockCollateral} from "./mocks/BranchMocks.sol";

/// SPEC V3-V5 against the reference model: every operation of a model-driven trace (`contracts/script/staking_trace.py`)
/// -- stakes, unstakes, claims, revenue arriving in the escrow and routed to the stakers, time across epoch boundaries and
/// through weeks with nobody staked -- is replayed on the escrow, the router and the staking contract at their predicted
/// addresses, and every acceptance, refusal and recorded number must match the model's. At every step the staking
/// contract must also hold everything it owes (the model's liabilities check).
contract DarliStakingTraceTest is Test {
    string constant TRACE = "test/vectors/staking_trace.json";
    uint256 constant N = 4;

    MockCollateral stable; // any ERC20 stands in for USDarli here: the contracts only transfer it
    DarliToken darli;
    InterestEscrow escrow;
    DarliStaking staking;
    RevenueRouter router;

    function staker(uint256 i) internal pure returns (address) {
        return address(uint160(0x2000 + i));
    }

    function setUp() public {
        string memory json = vm.readFile(TRACE);
        vm.warp(vm.parseJsonUint(json, ".config.start"));
        uint256 each = vm.parseJsonUint(json, ".config.darli");
        stable = new MockCollateral();
        darli = new DarliToken(address(this), each * N);
        uint256 n = vm.getNonce(address(this));
        address predictedRouter = vm.computeCreateAddress(address(this), n + 2);
        escrow = new InterestEscrow(stable, predictedRouter);
        staking = new DarliStaking(darli, stable, predictedRouter);
        router = new RevenueRouter(stable, IInterestEscrow(address(escrow)), IDarliStaking(address(staking)));
        assertEq(address(router), predictedRouter);
        for (uint256 i = 0; i < N; i++) {
            darli.transfer(staker(i), each);
            vm.prank(staker(i));
            darli.approve(address(staking), type(uint256).max);
        }
    }

    function _do(uint256 k, address who, uint256 a) internal returns (bool ok) {
        if (k == 3) {
            stable.mint(address(escrow), a);
            return true;
        }
        if (k == 5) {
            vm.warp(block.timestamp + a);
            return true;
        }
        bytes memory data;
        address target = address(staking);
        if (k == 0) {
            data = abi.encodeCall(staking.stake, (a));
        } else if (k == 1) {
            data = abi.encodeCall(staking.unstake, (a));
        } else if (k == 2) {
            data = abi.encodeCall(staking.claim, ());
        } else {
            (target, data) = (address(router), abi.encodeCall(router.routeRevenue, ()));
        }
        vm.prank(who);
        (ok,) = target.call(data);
    }

    function _stateNow(uint256 len) internal view returns (uint256[] memory v) {
        v = new uint256[](len);
        uint256 t0 = staking.t0();
        uint256 last = staking.last();
        v[0] = t0;
        v[1] = last;
        v[2] = staking.rate();
        v[3] = staking.queued();
        v[4] = staking.idle();
        v[5] = staking.totalStaked();
        v[6] = staking.rewardPerToken();
        v[7] = stable.balanceOf(address(staking));
        v[8] = stable.balanceOf(address(escrow));
        v[9] = stable.totalSupply();
        v[10] = t0 + ((last - t0) / staking.PERIOD() + 1) * staking.PERIOD();
        for (uint256 i = 0; i < N; i++) {
            address s = staker(i);
            uint256 o = 11 + 5 * i;
            v[o] = staking.stakeOf(s);
            v[o + 1] = staking.paid(s);
            v[o + 2] = staking.earned(s);
            v[o + 3] = stable.balanceOf(s);
            v[o + 4] = darli.balanceOf(s);
        }
    }

    /// V4, V5: the balance covers everything earned and everything not yet streamed. The model asserts
    /// `balance + 1 >= liabilities` with liabilities = earned + unstreamed / PREC + 1, its own deliberate round-up: the
    /// same inequality, by a bound of zero wei.
    function _solvent() internal view {
        uint256 owed = staking.unstreamed() / staking.PREC();
        for (uint256 i = 0; i < N; i++) {
            owed += staking.earnedOf(staker(i));
        }
        assertGe(stable.balanceOf(address(staking)), owed, "V4: the staking contract cannot pay what it owes");
    }

    function test_diff_stakingMatchesModel() public {
        string memory json = vm.readFile(TRACE);
        uint256[] memory kind = vm.parseJsonUintArray(json, ".ops.kind");
        uint256[] memory who = vm.parseJsonUintArray(json, ".ops.who");
        uint256[] memory a = vm.parseJsonUintArray(json, ".ops.a");
        uint256[] memory ok = vm.parseJsonUintArray(json, ".ops.ok");
        uint256[] memory ledger = vm.parseJsonUintArray(json, ".ledger");
        uint256 len = vm.parseJsonUint(json, ".ledgerLen");
        assertGt(kind.length, 300, "too short to be a differential test");
        for (uint256 i = 0; i < kind.length; i++) {
            bool accepted = _do(kind[i], staker(who[i]), a[i]);
            if (accepted != (ok[i] == 1)) {
                emit log_named_uint("step", i);
                assertEq(
                    accepted, ok[i] == 1, "the contracts and the model disagree on whether this operation is allowed"
                );
            }
            uint256[] memory v = _stateNow(len);
            for (uint256 j = 0; j < len; j++) {
                if (v[j] != ledger[i * len + j]) {
                    emit log_named_uint("step", i);
                    emit log_named_uint("field", j);
                    assertEq(v[j], ledger[i * len + j], "staking state differs from the model");
                }
            }
            _solvent();
        }
    }
}
