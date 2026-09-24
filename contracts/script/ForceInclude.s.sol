// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

/// Base's OptimismPortal on Ethereum: a deposit made here is included on Base within the sequencing window, whatever
/// the sequencer does.
interface IOptimismPortal {
    function depositTransaction(address to, uint256 value, uint64 gasLimit, bool isCreation, bytes calldata data)
        external
        payable;
}

/// @notice Any Darli call, sent through Ethereum when the Base sequencer will not include it (censorship resistance).
///         Signed by the same key as on Base: a deposit from an Ethereum account arrives on Base from the SAME address,
///         so it acts on that address's own Troves, deposits and claims. Nothing here touches the protocol; it is the
///         rollup's own escape hatch, pointed at Darli.
///
///             L2_TARGET=<the Darli contract on Base> \
///             L2_CALLDATA=$(cast calldata "repay(uint256,uint256)" <troveId> <amount>) \
///             forge script script/ForceInclude.s.sol --rpc-url <an Ethereum endpoint> --broadcast
///
///         L2_GAS_LIMIT (default 1,000,000) is bought on Ethereum; it must cover the call on Base. The deposit takes
///         effect on Base after the rollup derives it, normally within minutes, at most the sequencing window (12 hours).
///         A contract wallet's deposit arrives from an aliased address; use an externally owned account.
contract ForceInclude is Script {
    /// Base's portal on Ethereum mainnet. Its SystemConfig's batch inbox is 0xff...8453 (Base's chain id), checked in
    /// contracts/fork/ForceInclusion.t.sol.
    address public constant BASE_PORTAL = 0x49048044D57e1C92A77f79988d21Fa8fAF74E97e;

    function run() external {
        address target = vm.envAddress("L2_TARGET");
        bytes memory data = vm.envBytes("L2_CALLDATA");
        uint64 gasLimit = uint64(vm.envOr("L2_GAS_LIMIT", uint256(1_000_000)));
        vm.startBroadcast();
        deposit(target, data, gasLimit);
        vm.stopBroadcast();
    }

    function deposit(address target, bytes memory data, uint64 gasLimit) public {
        IOptimismPortal(BASE_PORTAL).depositTransaction(target, 0, gasLimit, false, data);
    }
}
