// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DarliDeployer, PoolKey, IPoolManagerInit} from "../src/deploy/DarliDeployer.sol";
import {StableToken} from "../src/core/StableToken.sol";
import {NotAuthorized} from "../src/Types.sol";

contract MockPoolManager is IPoolManagerInit {
    mapping(bytes32 => uint160) public priceOf;

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24) {
        bytes32 id = keccak256(abi.encode(key));
        require(priceOf[id] == 0, "PoolAlreadyInitialized");
        priceOf[id] = sqrtPriceX96;
        slotPrice[keccak256(abi.encode(id, bytes32(uint256(6))))] = sqrtPriceX96; // the layout the deployer reads
        return 0;
    }

    mapping(bytes32 => uint160) public slotPrice;

    function extsload(bytes32 slot) external view returns (bytes32) {
        return bytes32(uint256(slotPrice[slot]));
    }
}

/// A PoolManager whose initialise always fails for an unrelated reason and that holds no pool at all.
contract BrokenPoolManager is IPoolManagerInit {
    function initialize(PoolKey memory, uint160) external pure returns (int24) {
        revert("TickSpacingTooLarge");
    }

    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract DarliDeployerTest is Test {
    MockPoolManager pm;
    DarliDeployer d;
    address branch = address(0xB1);
    address[] minters;

    function setUp() public {
        pm = new MockPoolManager();
        d = new DarliDeployer();
        minters.push(branch);
    }

    function _price(uint160 sqrtP, bool stableIs0, uint8 dec) internal pure returns (uint256 quotePerStableWad) {
        // (sqrtP / 2^96)^2 = raw currency1 per raw currency0
        uint256 raw = (uint256(sqrtP) * uint256(sqrtP) * 1e18) >> 192; // WAD-scaled raw price (only valid when it fits)
        if (dec == 18) return raw;
        return stableIs0 ? raw * 1e12 : 0; // the other ordering overflows this helper; checked separately below
    }

    function test_deployCreatesTokenSealsMintersAndInitialisesPoolAtPar() public {
        address usdc = address(uint160(type(uint160).max)); // guarantees token < quote -> stable is currency0
        (StableToken token, uint160 sqrtP) = d.deploy("USDarli", "USDarli", minters, pm, usdc, 6, 100, 1);
        assertTrue(token.mintersSealed());
        assertTrue(token.isMinter(branch));
        (address c0, address c1, uint24 fee, int24 spacing, address hooks) = d.canonicalPool();
        assertEq(c0, address(token));
        assertEq(c1, usdc);
        assertEq(fee, 100);
        assertEq(spacing, 1);
        assertEq(hooks, address(0), "version 1 deploys no hook");
        assertEq(sqrtP, uint160(2 ** 96) / 1e6);
        assertApproxEqRel(_price(sqrtP, true, 6), 1e18, 1e13, "one USDarli must equal one quote unit"); // within 0.001%
        bytes32 id = keccak256(abi.encode(PoolKey(c0, c1, fee, spacing, hooks)));
        assertEq(pm.priceOf(id), sqrtP);
    }

    function test_otherTokenOrderingAndEighteenDecimals() public {
        address lowQuote = address(1); // quote < token -> stable is currency1
        (, uint160 sqrtP) = d.deploy("USDarli", "USDarli", minters, pm, lowQuote, 6, 100, 1);
        assertEq(sqrtP, uint160(2 ** 96) * 1e6);
        DarliDeployer d2 = new DarliDeployer();
        (, uint160 sqrtP18) = d2.deploy("USDarli", "USDarli", minters, pm, lowQuote, 18, 100, 1);
        assertEq(sqrtP18, uint160(2 ** 96));
    }

    function test_deploymentIsOneShotAndLeavesNoPowers() public {
        d.deploy("USDarli", "USDarli", minters, pm, address(1), 6, 100, 1);
        vm.expectRevert(DarliDeployer.AlreadyDeployed.selector);
        d.deploy("USDarli", "USDarli", minters, pm, address(1), 6, 100, 1);
        StableToken token = d.stable();
        address[] memory more = new address[](1);
        more[0] = address(this);
        vm.prank(address(d)); // even the deployer contract itself cannot widen the minter set
        vm.expectRevert(StableToken.AlreadySealed.selector);
        token.sealMinters(more);
        vm.expectRevert(NotAuthorized.selector);
        token.mint(address(this), 1);
    }

    function test_onlyTheDeployerAccount() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(DarliDeployer.NotDeployer.selector);
        d.deploy("USDarli", "USDarli", minters, pm, address(1), 6, 100, 1);
    }

    /// The pool race (SPEC D2): the attacker computes the token's REAL future address and initialises the REAL key first,
    /// at a wrong price. Deployment must still succeed, must say so, and must end with the same sealed token.
    function test_poolRace_realPredictedAddress() public {
        address quote = address(1);
        address predicted = vm.computeCreateAddress(address(d), vm.getNonce(address(d)));
        (address c0, address c1) = predicted < quote ? (predicted, quote) : (quote, predicted);
        PoolKey memory real = PoolKey(c0, c1, 100, 1, address(0));
        vm.prank(address(0xA77AC));
        pm.initialize(real, 12345); // wrong price, right key: `initialize` does not care that the token has no code yet
        (StableToken token,) = d.deploy("USDarli", "USDarli", minters, pm, quote, 6, 100, 1);
        assertEq(address(token), predicted, "the address really was predictable");
        assertTrue(d.poolPreInitialised(), "deployment must record that it lost the race");
        assertEq(d.observedSqrtPriceX96(), 12345, "the record must show the price the pool REALLY has");
        assertEq(d.targetSqrtPriceX96(), uint160(2 ** 96) * 1e6, "and, separately, the price that was asked for");
        assertEq(pm.priceOf(keccak256(abi.encode(real))), 12345, "the attacker's price stands until somebody moves it");
        assertTrue(token.mintersSealed());
        (address k0, address k1,,,) = d.canonicalPool();
        assertTrue(k0 == c0 && k1 == c1, "the canonical key is unchanged");
    }

    /// SPEC D2: a failed initialise is NOT proof that the pool exists. With a PoolManager that fails for an
    /// unrelated reason and holds no pool, the deployment must revert instead of reporting success.
    function test_unrelatedInitialiseFailure_revertsInsteadOfFalseSuccess() public {
        BrokenPoolManager broken = new BrokenPoolManager();
        vm.expectRevert(DarliDeployer.PoolAbsentAfterInitialise.selector);
        d.deploy("USDarli", "USDarli", minters, broken, address(1), 6, 100, 1);
        assertFalse(d.deployed(), "a reverted deployment leaves nothing behind and can be retried");
    }

    function test_noRace_flagStaysFalse() public {
        d.deploy("USDarli", "USDarli", minters, pm, address(1), 6, 100, 1);
        assertFalse(d.poolPreInitialised());
        assertEq(d.observedSqrtPriceX96(), d.targetSqrtPriceX96());
    }

    function test_unsupportedQuoteDecimalsRevert() public {
        vm.expectRevert(DarliDeployer.QuoteDecimalsUnsupported.selector);
        d.deploy("USDarli", "USDarli", minters, pm, address(1), 8, 100, 1);
    }
}
