// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableToken} from "../src/core/StableToken.sol";
import {StabilityPool} from "../src/core/StabilityPool.sol";
import {IBranchManager} from "../src/interfaces/IBranchManager.sol";
import {BranchLedger} from "../src/Types.sol";
import {MockCollateral} from "./mocks/BranchMocks.sol";

/// SPEC SP2, SP4 against the reference model. This contract plays the pool's branch: it answers step A and "not shut
/// down", mints the yield, sends the collateral before an offset and burns the absorbed USDarli after it -- exactly
/// what the branch does, and what `contracts/script/sp_trace.py` does to the model's pool.
contract StabilityPoolTest is Test {
    StableToken stable;
    MockCollateral weth;
    StabilityPool sp;
    uint256 users;

    struct Ops {
        uint256[] kind;
        uint256[] who;
        uint256[] a;
        uint256[] b;
        uint256[] ok;
    }

    // --- the branch, as far as the pool can see it ---------------------------------------------------------------------

    function ledger() external pure returns (BranchLedger memory l) {
        return l; // live: shutdownAt == 0
    }

    function mintAggInterest() external pure returns (uint256) {
        return 0; // the yield is credited explicitly by the `credit` operations, as in the model's trace
    }

    function account(uint256 i) internal pure returns (address) {
        return address(uint160(0x2000 + i));
    }

    function setUp() public {
        stable = new StableToken("USDarli", "USDarli", address(this));
        address[] memory m = new address[](1);
        m[0] = address(this);
        stable.sealMinters(m);
        weth = new MockCollateral();
        sp = new StabilityPool(stable, weth, IBranchManager(address(this)));
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(account(i));
            stable.approve(address(sp), type(uint256).max);
        }
    }

    function _load(string memory json) internal pure returns (Ops memory o) {
        o.kind = vm.parseJsonUintArray(json, ".ops.kind");
        o.who = vm.parseJsonUintArray(json, ".ops.who");
        o.a = vm.parseJsonUintArray(json, ".ops.a");
        o.b = vm.parseJsonUintArray(json, ".ops.b");
        o.ok = vm.parseJsonUintArray(json, ".ops.ok");
    }

    function _do(Ops memory o, uint256 i) internal returns (bool ok) {
        uint256 k = o.kind[i];
        address who = account(o.who[i]);
        if (k == 0) {
            stable.mint(who, o.a[i]);
            vm.prank(who);
            (ok,) = address(sp).call(abi.encodeCall(sp.deposit, (o.a[i])));
        } else if (k == 1) {
            vm.prank(who);
            (ok,) = address(sp).call(abi.encodeCall(sp.withdraw, (o.a[i])));
        } else if (k == 2) {
            vm.prank(who);
            (ok,) = address(sp).call(abi.encodeCall(sp.claim, ()));
        } else if (k == 3) {
            weth.mint(address(sp), o.b[i]);
            (ok,) = address(sp).call(abi.encodeCall(sp.offset, (o.a[i], o.b[i])));
            if (ok) stable.burn(address(sp), o.a[i]);
        } else {
            stable.mint(address(sp), o.a[i]);
            (ok,) = address(sp).call(abi.encodeCall(sp.creditYield, (o.a[i])));
        }
    }

    function _state() internal view returns (uint256[] memory v) {
        uint256 scale = sp.currentScale();
        v = new uint256[](9 + 7 * users);
        v[0] = sp.P();
        v[1] = scale;
        v[2] = sp.totalDeposits();
        v[3] = sp.errColl();
        v[4] = sp.errYield();
        v[5] = sp.scaleToS(scale);
        v[6] = sp.scaleToB(scale);
        v[7] = stable.balanceOf(address(sp));
        v[8] = weth.balanceOf(address(sp));
        for (uint256 j = 0; j < users; j++) {
            address u = account(j);
            v[9 + 7 * j] = sp.compoundedDeposit(u);
            v[10 + 7 * j] = sp.pendingColl(u);
            v[11 + 7 * j] = sp.pendingYield(u);
            v[12 + 7 * j] = sp.claimableColl(u);
            v[13 + 7 * j] = sp.claimableYield(u);
            v[14 + 7 * j] = stable.balanceOf(u);
            v[15 + 7 * j] = weth.balanceOf(u);
        }
    }

    function test_diff_stabilityPoolMatchesModel() public {
        string memory json = vm.readFile("test/vectors/stability_pool.json");
        Ops memory o = _load(json);
        uint256[] memory expected = vm.parseJsonUintArray(json, ".state");
        uint256 len = vm.parseJsonUint(json, ".stateLen");
        users = vm.parseJsonUint(json, ".users");
        assertGt(o.kind.length, 300, "too short to be a differential test");
        for (uint256 i = 0; i < o.kind.length; i++) {
            bool ok = _do(o, i);
            assertEq(ok, o.ok[i] == 1, "the pool and the model disagree on whether this operation is allowed");
            uint256[] memory v = _state();
            for (uint256 f = 0; f < len; f++) {
                if (v[f] != expected[i * len + f]) {
                    emit log_named_uint("step", i);
                    emit log_named_uint("field", f);
                    assertEq(v[f], expected[i * len + f], "SP2: the pool differs from the model");
                }
            }
        }
        assertGt(sp.currentScale(), 8, "the trace must rescale past MAX_SCALE_DIFF");
        assertEq(sp.compoundedDeposit(account(0)), 0, "SP4 a: a deposit older than MAX_SCALE_DIFF rescalings is spent");
    }

    // --- rights ---------------------------------------------------------------------------------------------------------

    function test_onlyTheBranchOffsetsAndCredits() public {
        vm.startPrank(account(0));
        vm.expectRevert();
        sp.offset(1, 1);
        vm.expectRevert();
        sp.creditYield(1);
        vm.stopPrank();
    }

    function test_anOffsetAlwaysLeavesTheResidual() public {
        stable.mint(account(0), 10e18);
        vm.prank(account(0));
        sp.deposit(10e18);
        vm.expectRevert(abi.encodeWithSelector(StabilityPool.OffsetOutOfRange.selector, 9e18 + 1, 10e18));
        sp.offset(9e18 + 1, 0); // would leave less than MIN_SP_RESIDUAL
        vm.expectRevert(abi.encodeWithSelector(StabilityPool.OffsetOutOfRange.selector, 0, 10e18));
        sp.offset(0, 0);
        sp.offset(9e18, 0);
        assertEq(sp.totalDeposits(), 1e18);
        assertGt(sp.P(), 0, "SP2: P must never reach zero");
    }
}
