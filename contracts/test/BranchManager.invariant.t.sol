// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {BranchFixture} from "./BranchFixture.sol";
import {BranchManager} from "../src/core/BranchManager.sol";
import {StableToken} from "../src/core/StableToken.sol";
import {MockPriceFeed, MockStabilityPool} from "./mocks/BranchMocks.sol";
import {TroveNFT} from "../src/core/TroveNFT.sol";
import {Trove, TroveStatus, PriceStatus} from "../src/Types.sol";

/// Random borrower operations by four users, with time and price moving. Every call is wrapped, so a refusal is an
/// outcome, not a failure; what is checked is the state the branch is left in.
contract BranchHandler is Test {
    BranchManager public immutable manager;
    StableToken public immutable stable;
    MockPriceFeed public immutable feed;
    MockStabilityPool public immutable sp;
    TroveNFT public immutable nft;
    uint256 constant E = 1e18;
    uint256 constant MAX = type(uint256).max;
    uint256 public accepted;

    constructor(BranchManager m, StableToken s, MockPriceFeed f, MockStabilityPool p, TroveNFT n) {
        manager = m;
        stable = s;
        feed = f;
        sp = p;
        nft = n;
    }

    function _user(uint256 seed) internal pure returns (address) {
        return address(uint160(0x1000 + seed % 4));
    }

    function _trove(uint256 seed) internal view returns (uint256) {
        uint256 n = manager.nextTroveId() - 1;
        return n == 0 ? 1 : 1 + seed % n;
    }

    function _owner(uint256 id) internal view returns (address) {
        try nft.ownerOf(id) returns (address o) {
            return o;
        } catch {
            return _user(id);
        }
    }

    function _count(bool ok) internal {
        if (ok) accepted++;
    }

    function open(uint256 who, uint256 debt, uint256 cr, uint256 rate, uint256 fid) external {
        address u = _user(who);
        debt = bound(debt, 1_000 * E, 50_000 * E);
        uint256 coll = debt * bound(cr, 105, 400) / 100 * E / feed.price();
        vm.prank(u);
        try manager.openTrove(u, coll, debt, bound(rate, 4e15, 3e17), uint32(fid % 3), MAX, 0, 0) {
            _count(true);
        } catch {}
    }

    function borrow(uint256 t, uint256 amount) external {
        uint256 id = _trove(t);
        vm.prank(_owner(id));
        try manager.borrow(id, bound(amount, 1, 8_000 * E), MAX) {
            _count(true);
        } catch {}
    }

    function repay(uint256 t, uint256 amount, uint256 who) external {
        uint256 id = _trove(t);
        vm.prank(who % 3 == 0 ? _user(who) : _owner(id));
        try manager.repay(id, bound(amount, 1, 20_000 * E)) {
            _count(true);
        } catch {}
    }

    function addColl(uint256 t, uint256 amount) external {
        uint256 id = _trove(t);
        vm.prank(_owner(id));
        try manager.addColl(id, bound(amount, 1, 10 * E)) {
            _count(true);
        } catch {}
    }

    function withdrawColl(uint256 t, uint256 amount) external {
        uint256 id = _trove(t);
        vm.prank(_owner(id));
        try manager.withdrawColl(id, bound(amount, 1, 5 * E)) {
            _count(true);
        } catch {}
    }

    function adjust(uint256 t, int256 dc, int256 dd) external {
        uint256 id = _trove(t);
        dc = bound(dc, -5e18, 5e18);
        dd = bound(dd, -10_000e18, 10_000e18);
        vm.prank(_owner(id));
        try manager.adjustTrove(id, dc, dd, MAX) {
            _count(true);
        } catch {}
    }

    function adjustRate(uint256 t, uint256 rate) external {
        uint256 id = _trove(t);
        vm.prank(_owner(id));
        try manager.adjustRate(id, bound(rate, 4e15, 3e17), MAX, 0, 0) {
            _count(true);
        } catch {}
    }

    function close(uint256 t, uint256 donor) external {
        uint256 id = _trove(t);
        address o = _owner(id);
        address d = _user(donor);
        uint256 give = stable.balanceOf(d) / 2;
        if (d != o && give > 0) {
            vm.prank(d);
            stable.transfer(o, give);
        }
        vm.prank(o);
        try manager.closeTrove(id) {
            _count(true);
        } catch {}
    }

    function applyPending(uint256 t) external {
        try manager.applyPendingDebt(_trove(t)) {
            _count(true);
        } catch {}
    }

    function transfer(uint256 t, uint256 to) external {
        uint256 id = _trove(t);
        address o = _owner(id);
        vm.prank(o);
        try nft.transferFrom(o, _user(to), id) {
            _count(true);
        } catch {}
    }

    function spDeposit(uint256 who, uint256 amount) external {
        vm.prank(_user(who));
        try sp.deposit(bound(amount, 1, 30_000 * E)) {
            _count(true);
        } catch {}
    }

    function spWithdraw(uint256 who, uint256 amount) external {
        vm.prank(_user(who));
        try sp.withdraw(bound(amount, 1, 30_000 * E)) {
            _count(true);
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 40 days));
    }

    function setPrice(uint256 p) external {
        feed.set(bound(p, 1_200 * E, 3_000 * E), feed.status());
    }

    function setStatus(uint256 s) external {
        feed.set(feed.price(), s % 5 == 0 ? PriceStatus.PriceInvalid : PriceStatus.Valid);
    }
}

/// SPEC I-1, I-2, I-4, I-17, I-21 and the queue rule R2, after any sequence of borrower operations. The model checks the
/// same identities in `check_invariants`; here they are checked on the contracts.
contract BranchManagerInvariantTest is StdInvariant, BranchFixture {
    BranchHandler handler;

    function setUp() public {
        deployBranch(2000 * E, 5_000_000 * E, 5_000_000 * E, E / 1000);
        handler = new BranchHandler(manager, stable, feed, sp, nft);
        for (uint256 i = 0; i < 4; i++) {
            weth.mint(account(i), 10_000 * E);
        }
        bytes4[] memory s = new bytes4[](16);
        s[0] = BranchHandler.open.selector;
        s[1] = BranchHandler.open.selector;
        s[2] = BranchHandler.borrow.selector;
        s[3] = BranchHandler.repay.selector;
        s[4] = BranchHandler.addColl.selector;
        s[5] = BranchHandler.withdrawColl.selector;
        s[6] = BranchHandler.adjust.selector;
        s[7] = BranchHandler.adjustRate.selector;
        s[8] = BranchHandler.close.selector;
        s[9] = BranchHandler.applyPending.selector;
        s[10] = BranchHandler.transfer.selector;
        s[11] = BranchHandler.spDeposit.selector;
        s[12] = BranchHandler.spWithdraw.selector;
        s[13] = BranchHandler.warp.selector;
        s[14] = BranchHandler.setPrice.selector;
        s[15] = BranchHandler.setStatus.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: s}));
        targetContract(address(handler));
    }

    function invariant_ledgersAgree() public view {
        uint256 n = manager.nextTroveId();
        uint256 sumDebt;
        uint256 sumWeight;
        uint256 sumColl;
        uint256 sumStake;
        uint256 sumGas;
        uint256 open;
        uint256 active;
        for (uint256 id = 1; id < n; id++) {
            Trove memory t = manager.getTrove(id);
            sumGas += manager.gasLeft(id);
            if (t.status != TroveStatus.Active && t.status != TroveStatus.Zombie) {
                assertEq(t.coll + t.recordedDebt + t.stake, 0, "a closed Trove kept a balance");
                assertFalse(list.contains(id), "R2: a closed Trove is still queued");
                continue;
            }
            open++;
            if (t.status == TroveStatus.Active) active++;
            assertEq(list.contains(id), t.status == TroveStatus.Active, "R2: the queue holds exactly the Active Troves");
            sumDebt += manager.troveDebt(id);
            sumWeight += t.recordedDebt * t.annualRate;
            sumColl += t.coll;
            sumStake += t.stake;
        }
        uint256 aggDebt = manager.ledger().aggDebt;
        uint256 badDebt = manager.ledger().badDebt;
        assertEq(stable.totalSupply(), aggDebt, "I-1 / T3: supply == aggregate debt");
        // I-2: aggregate (rounded up) never below the sum of Troves (rounded down) plus bad debt; epsilon >= 0
        assertGe(aggDebt + manager.pendingAggInterest(), sumDebt + badDebt, "I-2: epsilon went negative");
        assertEq(manager.ledger().aggWeightedDebtSum, sumWeight, "B1: aggW is not the sum of recorded debt x rate");
        assertEq(manager.activeColl(), sumColl, "B12: active collateral is not the sum of the Troves'");
        assertEq(manager.totalStakes(), sumStake, "total stakes is not the sum of the Troves'");
        assertEq(manager.gasPool(), sumGas, "I-21: gas pool is not the sum of the per-Trove deposits");
        assertEq(manager.nOpen(), open, "the open-Trove counter drifted");
        assertEq(list.size(), active, "R2: queue size");
        // I-4 / B12: every named account is in the vault, and nothing unnamed is in the ledger
        assertEq(vault.accountedColl(), manager.activeColl() + manager.defaultColl() + manager.gasPool(), "I-4");
        assertGe(weth.balanceOf(address(vault)), vault.accountedColl(), "I-4: vault holds less than it accounts");
        // I-17: the registry can pay every claim, and never credited more than was deposited
        uint256 claims;
        for (uint256 i = 0; i < N_ACCOUNTS; i++) {
            claims += registry.claimable(account(i));
        }
        assertGe(stable.balanceOf(address(registry)), claims, "I-17: registry cannot pay its claims");
        assertGe(registry.totalDeposited(), registry.totalCredited(), "I-17: credited more than deposited");
    }
}
