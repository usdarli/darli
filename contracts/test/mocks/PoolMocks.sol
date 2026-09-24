// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey, IPoolManagerInit} from "../../src/deploy/DarliDeployer.sol";

uint160 constant MIN_SQRT_PRICE = 4295128739;
uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

/// Follows v4-core SOURCE (commit 46c6834), not the deployer's own assumption. It used to write the price exactly where
/// the deployer reads it, which made every test here check that assumption against itself. Now: the state slot is derived
/// with abi.encodePacked as StateLibrary does, Slot0 carries a tick and an lpFee above the price as the real packing does
/// (tick -1 sets all 24 tick bits, so an unmasked read of the word cannot pass for a price), and `initialize` rejects any
/// price v4 would reject.
contract MockPoolManager is IPoolManagerInit {
    mapping(bytes32 => uint160) public priceOf;
    mapping(bytes32 => bytes32) internal slots;

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24) {
        require(sqrtPriceX96 >= MIN_SQRT_PRICE && sqrtPriceX96 < MAX_SQRT_PRICE, "InvalidSqrtPrice");
        bytes32 id = keccak256(abi.encode(key));
        require(priceOf[id] == 0, "PoolAlreadyInitialized");
        priceOf[id] = sqrtPriceX96;
        int24 tick = -1;
        slots[keccak256(abi.encodePacked(id, bytes32(uint256(6))))] =
            bytes32(uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160) | (uint256(key.fee) << 208));
        return tick;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }
}

