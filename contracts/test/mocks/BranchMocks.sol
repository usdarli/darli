// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";
import {IStabilityPool} from "../../src/interfaces/IStabilityPool.sol";
import {IBranchManager} from "../../src/interfaces/IBranchManager.sol";
import {PriceStatus, NotAuthorized, ZeroAmount, BranchShutDown} from "../../src/Types.sol";
import {MAX_SP_DEPOSITS} from "../../src/libraries/Constants.sol";

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

    constructor(uint256 price_) {
        price = price_;
        lastGoodPrice = price_;
    }

    function set(uint256 price_, PriceStatus status_) external {
        price = price_;
        status = status_;
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
        return fetchPrice();
    }
}

/// Until the Stability Pool exists (stage 4) the branch needs only what the split of SPEC V1 reads: the total deposited,
/// yield credited to it, and step A before every deposit and withdrawal. Without liquidations a deposit's compounded
/// value is the deposit itself, which is what the model's pool returns too.
contract MockStabilityPool is IStabilityPool {
    IERC20 public immutable stable;
    IBranchManager public immutable manager;
    uint256 public totalDeposits;
    uint256 public yieldCredited;
    mapping(address => uint256) public deposits;

    constructor(IERC20 stable_, IBranchManager manager_) {
        stable = stable_;
        manager = manager_;
    }

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (manager.ledger().shutdownAt != 0) revert BranchShutDown();
        require(totalDeposits + amount <= MAX_SP_DEPOSITS, "SP deposit domain");
        manager.mintAggInterest();
        stable.transferFrom(msg.sender, address(this), amount);
        totalDeposits += amount;
        deposits[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external returns (uint256) {
        manager.mintAggInterest();
        if (amount > deposits[msg.sender]) amount = deposits[msg.sender];
        stable.transfer(msg.sender, amount);
        totalDeposits -= amount;
        deposits[msg.sender] -= amount;
        return amount;
    }

    function creditYield(uint256 amount) external {
        if (msg.sender != address(manager)) revert NotAuthorized();
        yieldCredited += amount;
    }

    function claim() external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function offset(uint256, uint256) external pure {
        revert("stage 4");
    }

    function compoundedDeposit(address depositor) external view returns (uint256) {
        return deposits[depositor];
    }

    function pendingColl(address) external pure returns (uint256) {
        return 0;
    }

    function pendingYield(address) external pure returns (uint256) {
        return 0;
    }
}
