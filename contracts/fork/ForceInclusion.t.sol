// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ForceInclude, IOptimismPortal} from "../script/ForceInclude.s.sol";

interface IPortalConfig {
    function systemConfig() external view returns (address);
}

interface ISystemConfig {
    function batchInbox() external view returns (address);
}

/// Censorship resistance through Ethereum, on an Ethereum fork: the portal ForceInclude uses is Base's, and a Darli
/// call deposited through it by an account is emitted for Base with that account as the sender (no alias) and the call
/// data unchanged -- what the rollup derives and executes on Base whatever the sequencer does.
contract ForceInclusionTest is Test {
    uint256 constant ETH_BLOCK = 26_046_803;

    event TransactionDeposited(address indexed from, address indexed to, uint256 indexed version, bytes opaqueData);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")), ETH_BLOCK);
    }

    function test_fork_aCensoredCallGoesThroughEthereumFromTheSameAddress() public {
        ForceInclude tool = new ForceInclude();
        address portal = tool.BASE_PORTAL();
        address config = IPortalConfig(portal).systemConfig();
        assertEq(
            ISystemConfig(config).batchInbox(),
            0xFf00000000000000000000000000000000008453,
            "the portal is Base's: its batch inbox names chain 8453"
        );
        address user = makeAddr("censored borrower");
        address manager = address(0xDA811); // any Darli contract on Base
        bytes memory call = abi.encodeWithSignature("repay(uint256,uint256)", 7, 1_000e18);
        uint64 gasLimit = 1_000_000;
        vm.expectEmit(true, true, true, true, portal);
        emit TransactionDeposited(user, manager, 0, abi.encodePacked(uint256(0), uint256(0), gasLimit, false, call));
        vm.prank(user, user); // an externally owned account signs the Ethereum transaction itself
        IOptimismPortal(portal).depositTransaction(manager, 0, gasLimit, false, call);
    }
}
