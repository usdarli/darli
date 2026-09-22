// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PriceStatus} from "../Types.sol";

/// @notice Whitepaper section 7. `fetch*` never revert because of the feed; they only revert when the
///         caller did not supply enough gas for the guarded source call (InsufficientGasForOracleCall).
interface IPriceFeed {
    /// @return price collateral price in the system's reference currency, WAD per normalised collateral unit.
    ///         When status != Valid this is lastGoodPrice.
    function fetchPrice() external returns (uint256 price, PriceStatus status);
    /// @notice conservative price for redemptions (equal to fetchPrice for plain collateral).
    function fetchRedemptionPrice() external returns (uint256 price, PriceStatus status);
    function lastGoodPrice() external view returns (uint256);
}

/// @notice One external source behind a uniform shape, so any provider can be plugged in.
interface IFeedSource {
    function read() external view returns (int256 value, uint256 updatedAt);
}

/// @notice L2 sequencer uptime. `since` is the time of the last status change.
interface ISequencerGuard {
    function status() external view returns (bool isUp, uint256 since);
}
