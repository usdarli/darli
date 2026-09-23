// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";
import {PriceStatus} from "../../src/Types.sol";

/// 18-decimal collateral anyone can mint: a stand-in for WETH.
contract MockCollateral is ERC20("Wrapped Ether", "WETH") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// The model's `Feed`: a price and a status injected by the test; the last good price moves only on a Valid read.
contract MockPriceFeed is IPriceFeed {
    uint256 public price;
    PriceStatus public status;
    uint256 public lastGoodPrice;
    bool public broken; // every read reverts: shows which operations never read the price at all
    uint256 public redemptionPrice; // 0: the redemption price is the price (plain collateral)

    constructor(uint256 price_) {
        price = price_;
        lastGoodPrice = price_;
    }

    function set(uint256 price_, PriceStatus status_) external {
        price = price_;
        status = status_;
    }

    /// A conservative redemption price below the market price (SPEC R4); 0 restores plain collateral.
    function setRedemptionPrice(uint256 redemptionPrice_) external {
        redemptionPrice = redemptionPrice_;
    }

    function setBroken(bool broken_) external {
        broken = broken_;
    }

    function fetchPrice() public returns (uint256, PriceStatus) {
        require(!broken, "feed read");
        if (status == PriceStatus.Valid) {
            lastGoodPrice = price;
            return (price, status);
        }
        return (lastGoodPrice, status);
    }

    function fetchRedemptionPrice() external returns (uint256, PriceStatus) {
        (uint256 p, PriceStatus s) = fetchPrice();
        return (redemptionPrice == 0 || s != PriceStatus.Valid ? p : redemptionPrice, s);
    }
}
