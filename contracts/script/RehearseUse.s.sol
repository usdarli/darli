// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BranchManager} from "../src/core/BranchManager.sol";
import {StabilityPool} from "../src/core/StabilityPool.sol";
import {CollateralRegistry} from "../src/core/CollateralRegistry.sol";
import {PriceStatus} from "../src/Types.sol";

interface IWETH {
    function deposit() external payable;
}

/// @notice The deployment rehearsal's second half (script/rehearse.sh): an ordinary user on the freshly deployed system,
///         in real transactions -- wrap ETH, open a Trove, deposit into the Stability Pool, read the price, redeem
///         through the router -- and the balances and ledger each step leaves. MANAGER, SP and REGISTRY come from the
///         deployment's broadcast record.
contract RehearseUse is Script {
    address constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        BranchManager manager = BranchManager(vm.envAddress("MANAGER"));
        StabilityPool sp = StabilityPool(vm.envAddress("SP"));
        CollateralRegistry registry = CollateralRegistry(vm.envAddress("REGISTRY"));
        IERC20 usd = IERC20(address(manager.stable()));
        vm.startBroadcast();
        address me = msg.sender;
        IWETH(WETH).deposit{value: 30 ether}();
        IERC20(WETH).approve(address(manager), type(uint256).max);
        uint256 id = manager.openTrove(me, 20 ether, 20_000 ether, 5e16, 0, type(uint256).max, 0, 0);
        usd.approve(address(sp), type(uint256).max);
        sp.deposit(5_000 ether);
        PriceStatus status = manager.pokeOracle();
        uint256 wethBefore = IERC20(WETH).balanceOf(me);
        uint256 redeemed = registry.redeem(1_000 ether, 10, 1e18);
        vm.stopBroadcast();
        require(status == PriceStatus.Valid, "the price is not Valid on the rehearsal fork");
        require(redeemed == 1_000 ether && IERC20(WETH).balanceOf(me) > wethBefore, "the redemption paid nothing");
        require(usd.totalSupply() == manager.ledger().aggDebt, "I-1: supply is not the branch's debt");
        console2.log("trove", id);
        console2.log("trove debt", manager.troveDebt(id));
        console2.log("trove coll", manager.troveColl(id));
        console2.log("stability pool", sp.totalDeposits());
        console2.log("ETH received for 1,000 USDarli redeemed", IERC20(WETH).balanceOf(me) - wethBefore);
        console2.log("USDarli supply", usd.totalSupply());
    }
}
