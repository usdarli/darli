// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableToken} from "../src/core/StableToken.sol";
import {InterestEscrow} from "../src/core/InterestEscrow.sol";
import {NotAuthorized, InvalidRecipient} from "../src/Types.sol";

contract StableTokenTest is Test {
    StableToken token;
    address factory = address(0xFAC);
    address branch = address(0xB1);
    address alice = address(0xA11CE);

    function setUp() public {
        token = new StableToken("USDarli", "USDarli", factory);
        address[] memory m = new address[](1);
        m[0] = branch;
        vm.prank(factory);
        token.sealMinters(m);
    }

    // Immutability: the minter set is written once and can never change again, not even by the deployer
    function test_minterSetIsSealedForEver() public {
        address[] memory m = new address[](1);
        m[0] = alice;
        vm.expectRevert(NotAuthorized.selector);
        token.sealMinters(m); // a stranger
        vm.prank(branch);
        vm.expectRevert(NotAuthorized.selector);
        token.sealMinters(m); // an existing minter
        vm.prank(factory);
        vm.expectRevert(StableToken.AlreadySealed.selector);
        token.sealMinters(m); // the deployer itself, a second time
        assertTrue(token.mintersSealed());
        assertFalse(token.isMinter(alice));
    }

    function test_cannotSealAnEmptySetOrMintBeforeSealing() public {
        StableToken fresh = new StableToken("x", "x", factory);
        address[] memory none = new address[](0);
        vm.prank(factory);
        vm.expectRevert(StableToken.NoMinters.selector);
        fresh.sealMinters(none);
        vm.prank(branch);
        vm.expectRevert(NotAuthorized.selector);
        fresh.mint(alice, 1);
    }

    function test_onlyMintersMintAndBurn() public {
        vm.expectRevert(NotAuthorized.selector);
        token.mint(alice, 1);
        vm.prank(branch);
        token.mint(alice, 100);
        vm.prank(alice);
        vm.expectRevert(NotAuthorized.selector);
        token.burn(alice, 1);
        vm.prank(branch);
        token.burn(alice, 40); // no allowance needed: the branch burns the redeemer's / SP's tokens
        assertEq(token.balanceOf(alice), 60);
        assertEq(token.totalSupply(), 60);
    }

    function test_transferToTokenItselfOrZeroIsRejected() public {
        vm.prank(branch);
        token.mint(alice, 10);
        vm.startPrank(alice);
        vm.expectRevert(InvalidRecipient.selector);
        token.transfer(address(token), 1);
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.stopPrank();
    }

    function testFuzz_supplyEqualsMintsMinusBurns(uint96 a, uint96 b) public {
        b = uint96(bound(b, 0, a));
        vm.startPrank(branch);
        token.mint(alice, a);
        token.burn(alice, b);
        assertEq(token.totalSupply(), uint256(a) - b);
    }

    function test_escrowOnlyRouterPulls() public {
        address router = address(0x7007);
        InterestEscrow escrow = new InterestEscrow(token, router);
        vm.prank(branch);
        token.mint(address(escrow), 500);
        vm.expectRevert(NotAuthorized.selector);
        escrow.pull(1);
        vm.prank(router);
        escrow.pull(200);
        assertEq(token.balanceOf(router), 200);
    }
}
