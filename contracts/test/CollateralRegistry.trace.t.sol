// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableToken} from "../src/core/StableToken.sol";
import {FrontendRegistry} from "../src/core/FrontendRegistry.sol";
import {CollateralVault} from "../src/core/CollateralVault.sol";
import {TroveNFT} from "../src/core/TroveNFT.sol";
import {RateSortedList} from "../src/core/RateSortedList.sol";
import {StabilityPool} from "../src/core/StabilityPool.sol";
import {CollateralRegistry} from "../src/core/CollateralRegistry.sol";
import {BranchManager, BranchConfig} from "../src/core/BranchManager.sol";
import {IBranchManager, IBranchRedemption} from "../src/interfaces/IBranchManager.sol";
import {IStabilityPool} from "../src/interfaces/IStabilityPool.sol";
import {IFrontendRegistry, ICollateralVault, ITroveNFT, IRateSortedList} from "../src/interfaces/ICore.sol";
import {IStableToken} from "../src/interfaces/IStableToken.sol";
import {Trove, PriceStatus} from "../src/Types.sol";
import {MockCollateral, MockPriceFeed} from "./mocks/BranchMocks.sol";

/// SPEC R1, R3 and R5 against the reference model, across three branches: every operation of a model-driven trace
/// (`contracts/script/routing_trace.py`) is replayed on one system -- one stablecoin, one frontend registry, one
/// CollateralRegistry, three branches at the addresses the deployment predicts -- and every acceptance, every refusal
/// and every recorded number must match the model's: how a request is split, truncated and charged, and what each
/// branch, pool and account holds afterwards.
contract CollateralRegistryTraceTest is Test {
    uint256 constant E = 1e18;
    uint256 constant PCT = 1e16;
    uint256 constant N = 3;
    uint256 constant BRANCH_LEN = 8;
    string constant TRACE = "test/vectors/routing_trace.json";

    StableToken stable;
    FrontendRegistry frontends;
    CollateralRegistry collRegistry;
    MockCollateral[N] coll;
    MockPriceFeed[N] feed;
    StabilityPool[N] sp;
    RateSortedList[N] list;
    BranchManager[N] manager;
    address escrow = makeAddr("InterestEscrow");
    uint256 users;
    uint256 troveCursor;

    function account(uint256 i) internal pure returns (address) {
        return address(uint160(0x1000 + i));
    }

    function setUp() public {
        string memory json = vm.readFile(TRACE);
        vm.warp(vm.parseJsonUint(json, ".config.start"));
        uint256[] memory prices = vm.parseJsonUintArray(json, ".config.prices");
        stable = new StableToken("USDarli", "USDarli", address(this));
        frontends = new FrontendRegistry(IStableToken(address(stable)), 3 * PCT);
        // the registry first, then per branch: collateral, feed, vault, NFT, queue, pool, manager
        uint256 n = vm.getNonce(address(this));
        IBranchRedemption[] memory predicted = new IBranchRedemption[](N);
        address[] memory minters = new address[](N);
        for (uint256 i = 0; i < N; i++) {
            minters[i] = vm.computeCreateAddress(address(this), n + 1 + 7 * i + 6);
            predicted[i] = IBranchRedemption(minters[i]);
        }
        collRegistry = new CollateralRegistry(IStableToken(address(stable)), predicted, 4 * E, 10 * PCT);
        for (uint256 i = 0; i < N; i++) {
            _deployBranch(i, minters[i], prices[i]);
        }
        stable.sealMinters(minters);
        users = vm.parseJsonUint(json, ".config.users");
        uint256 funding = vm.parseJsonUint(json, ".config.funding");
        for (uint256 u = 0; u < users; u++) {
            vm.startPrank(account(u));
            for (uint256 i = 0; i < N; i++) {
                coll[i].mint(account(u), funding);
                coll[i].approve(address(manager[i]), type(uint256).max);
                stable.approve(address(sp[i]), type(uint256).max);
            }
            vm.stopPrank();
        }
    }

    function _deployBranch(uint256 i, address predicted, uint256 price) internal {
        coll[i] = new MockCollateral();
        feed[i] = new MockPriceFeed(price);
        CollateralVault vault = new CollateralVault(coll[i], predicted);
        TroveNFT nft = new TroveNFT(predicted, "Darli Trove", "DTROVE");
        list[i] = new RateSortedList(predicted);
        sp[i] = new StabilityPool(stable, coll[i], IBranchManager(predicted));
        manager[i] = new BranchManager(
            BranchConfig({
                stable: IStableToken(address(stable)),
                collToken: coll[i],
                feed: feed[i],
                vault: ICollateralVault(address(vault)),
                nft: ITroveNFT(address(nft)),
                list: IRateSortedList(address(list[i])),
                stabilityPool: IStabilityPool(address(sp[i])),
                frontends: IFrontendRegistry(address(frontends)),
                escrow: escrow,
                collateralRegistry: address(collRegistry),
                mcr: 110 * PCT,
                ccr: 150 * PCT,
                scr: 110 * PCT,
                minDebt: 2000 * E,
                minRate: PCT / 2,
                maxRate: 250 * PCT,
                cap0: 10_000_000 * E,
                capCeiling: 10_000_000 * E,
                gasDeposit: E / 1000,
                spShare: 72 * PCT,
                penSp: 5 * PCT,
                penRedist: 10 * PCT,
                liqBonus: PCT / 2,
                liqBonusCap: 2 * E
            })
        );
        assertEq(address(manager[i]), predicted, "the branch is not at the address the registry was built with");
    }

    /// One step; kinds follow OPS in routing_trace.py. Returns whether the contracts accepted it.
    function _do(uint256[8] memory o) internal returns (bool ok) {
        (uint256 k, uint256 br, address who) = (o[0], o[1], account(o[2]));
        if (k == 3) {
            feed[br].set(o[3], feed[br].status());
            return true;
        }
        if (k == 4) {
            feed[br].set(feed[br].price(), PriceStatus(o[3]));
            return true;
        }
        if (k == 5) {
            vm.warp(block.timestamp + o[3]);
            return true;
        }
        bytes memory data;
        address target;
        if (k == 0) {
            target = address(manager[br]);
            data = abi.encodeCall(manager[br].openTrove, (who, o[3], o[4], o[5], 0, type(uint256).max, 0, 0));
        } else if (k == 1) {
            (target, data) = (address(sp[br]), abi.encodeCall(sp[br].deposit, (o[3])));
        } else if (k == 2) {
            (target, data) = (address(sp[br]), abi.encodeCall(sp[br].withdraw, (o[3])));
        } else if (k == 6) {
            (target, data) = (address(collRegistry), abi.encodeCall(collRegistry.redeem, (o[3], o[4], o[5])));
        } else if (k == 7) {
            (target, data) = (address(stable), abi.encodeCall(stable.transfer, (account(o[3]), o[4])));
        } else if (k == 8) {
            (target, data) = (address(manager[br]), abi.encodeCall(manager[br].triggerShutdown, ()));
        } else {
            revert("unknown operation kind");
        }
        vm.prank(who);
        (ok,) = target.call(data);
    }

    function _ledgerNow(uint256 len) internal view returns (uint256[] memory v) {
        v = new uint256[](len);
        v[0] = collRegistry.baseRate();
        v[1] = collRegistry.lastFeeOperationTime();
        v[2] = stable.totalSupply();
        for (uint256 i = 0; i < N; i++) {
            uint256 o = 3 + BRANCH_LEN * i;
            BranchManager m = manager[i];
            v[o] = m.ledger().aggDebt;
            v[o + 1] = m.ledger().aggWeightedDebtSum;
            v[o + 2] = m.activeColl();
            v[o + 3] = sp[i].totalDeposits();
            v[o + 4] = m.lastZombieTroveId();
            v[o + 5] = m.nOpen();
            v[o + 6] = m.ledger().shutdownAt;
            v[o + 7] = list[i].last();
        }
        for (uint256 u = 0; u < users; u++) {
            uint256 o = 3 + BRANCH_LEN * N + (1 + N) * u;
            v[o] = stable.balanceOf(account(u));
            for (uint256 i = 0; i < N; i++) {
                v[o + 1 + i] = coll[i].balanceOf(account(u));
            }
        }
    }

    function _compareTroves(uint256[] memory troves, uint256 count, uint256 step) internal {
        for (uint256 j = 0; j < count; j++) {
            uint256 at = troveCursor + 6 * j;
            Trove memory t = manager[troves[at]].getTrove(troves[at + 1]);
            uint256 status = uint8(t.status) >= 3 ? 3 : uint8(t.status);
            uint256[4] memory got = [t.coll, t.recordedDebt, t.annualRate, status];
            for (uint256 f = 0; f < 4; f++) {
                if (got[f] != troves[at + 2 + f]) {
                    emit log_named_uint("step", step);
                    emit log_named_uint("branch", troves[at]);
                    emit log_named_uint("trove", troves[at + 1]);
                    assertEq(got[f], troves[at + 2 + f], "Trove differs from the model");
                }
            }
        }
        troveCursor += 6 * count;
    }

    function test_diff_routingMatchesModel() public {
        string memory json = vm.readFile(TRACE);
        uint256[][8] memory ops;
        string[8] memory keys =
            [".ops.kind", ".ops.br", ".ops.caller", ".ops.a", ".ops.b", ".ops.c", ".ops.d", ".ops.ok"];
        for (uint256 f = 0; f < 8; f++) {
            ops[f] = vm.parseJsonUintArray(json, keys[f]);
        }
        uint256[] memory ledger = vm.parseJsonUintArray(json, ".ledger");
        uint256 len = vm.parseJsonUint(json, ".ledgerLen");
        uint256[] memory troves = vm.parseJsonUintArray(json, ".troves");
        uint256[] memory trovesLen = vm.parseJsonUintArray(json, ".trovesLen");
        assertEq(len, 3 + BRANCH_LEN * N + (1 + N) * users);
        assertGt(ops[0].length, 300, "too short to be a differential test");
        for (uint256 i = 0; i < ops[0].length; i++) {
            uint256[8] memory o;
            for (uint256 f = 0; f < 8; f++) {
                o[f] = ops[f][i];
            }
            bool ok = _do(o);
            if (ok != (o[7] == 1)) {
                emit log_named_uint("step", i);
                emit log_named_uint("kind", o[0]);
                assertEq(ok, o[7] == 1, "the contracts and the model disagree on whether this operation is allowed");
            }
            uint256[] memory v = _ledgerNow(len);
            for (uint256 j = 0; j < len; j++) {
                if (v[j] != ledger[i * len + j]) {
                    emit log_named_uint("step", i);
                    emit log_named_uint("field", j);
                    assertEq(v[j], ledger[i * len + j], "routing state differs from the model");
                }
            }
            _compareTroves(troves, trovesLen[i], i);
        }
        assertEq(troveCursor, troves.length, "not every recorded Trove was compared");
    }
}
