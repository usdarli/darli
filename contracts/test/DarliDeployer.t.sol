// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {DarliDeployer, PoolKey, IPoolManagerInit} from "../src/deploy/DarliDeployer.sol";
import {StableToken} from "../src/core/StableToken.sol";
import {BranchManager, BranchConfig} from "../src/core/BranchManager.sol";
import {IStableToken} from "../src/interfaces/IStableToken.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {IStabilityPool} from "../src/interfaces/IStabilityPool.sol";
import {ICollateralVault, IFrontendRegistry, ITroveNFT, IRateSortedList} from "../src/interfaces/ICore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NotAuthorized} from "../src/Types.sol";

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

/// A PoolManager whose layout is NOT the one the deployer assumes: `initialize` succeeds, but the word at the assumed slot
/// is some other field that happens to look like a valid price.
contract ShiftedLayoutPoolManager is IPoolManagerInit {
    function initialize(PoolKey memory, uint160) external pure returns (int24) {
        return 0;
    }

    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(uint256(2 ** 96));
    }
}

/// A raced pool whose word at the assumed slot holds a number no v4 pool can hold as a price.
contract RacedGarbagePoolManager is IPoolManagerInit {
    function initialize(PoolKey memory, uint160) external pure returns (int24) {
        revert("PoolAlreadyInitialized");
    }

    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(uint256(7));
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

/// Answers `stable()` like a branch, with whatever address it was built for.
contract StandInBranch {
    address public stable;

    constructor(address stable_) {
        stable = stable_;
    }
}

contract DarliDeployerTest is Test {
    MockPoolManager pm;
    DarliDeployer d;
    address branch;
    address[] minters;
    // Quote tokens with code at controlled addresses, so the token ordering is chosen by the test. 0x1000 is below any
    // CREATE address (quote is currency0) and clear of every precompile; the maximum address is above any (quote is
    // currency1). The deployer refuses a quote without code.
    address constant LOW_QUOTE = address(0x1000);
    address constant HIGH_QUOTE = address(type(uint160).max);

    function setUp() public {
        pm = new MockPoolManager();
        d = new DarliDeployer();
        branch = address(new StandInBranch(_tokenOf(d)));
        minters.push(branch);
        vm.etch(LOW_QUOTE, hex"00");
        vm.etch(HIGH_QUOTE, hex"00");
    }

    /// The address the deployer's `deploy` will create the token at: its first CREATE.
    function _tokenOf(DarliDeployer dep) internal view returns (address) {
        return vm.computeCreateAddress(address(dep), vm.getNonce(address(dep)));
    }

    function _price(uint160 sqrtP, bool stableIs0, uint8 dec) internal pure returns (uint256 quotePerStableWad) {
        // (sqrtP / 2^96)^2 = raw currency1 per raw currency0
        uint256 raw = (uint256(sqrtP) * uint256(sqrtP) * 1e18) >> 192; // WAD-scaled raw price (only valid when it fits)
        if (dec == 18) return raw;
        return stableIs0 ? raw * 1e12 : 0; // the other ordering overflows this helper; checked separately below
    }

    function test_deployCreatesTokenSealsMintersAndInitialisesPoolAtPar() public {
        address usdc = HIGH_QUOTE; // guarantees token < quote -> stable is currency0
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
        address lowQuote = LOW_QUOTE; // quote < token -> stable is currency1
        (, uint160 sqrtP) = d.deploy("USDarli", "USDarli", minters, pm, lowQuote, 6, 100, 1);
        assertEq(sqrtP, uint160(2 ** 96) * 1e6);
        DarliDeployer d2 = new DarliDeployer();
        address[] memory m2 = new address[](1);
        m2[0] = address(new StandInBranch(_tokenOf(d2)));
        (, uint160 sqrtP18) = d2.deploy("USDarli", "USDarli", m2, pm, lowQuote, 18, 100, 1);
        assertEq(sqrtP18, uint160(2 ** 96));
    }

    function test_deploymentIsOneShotAndLeavesNoPowers() public {
        d.deploy("USDarli", "USDarli", minters, pm, LOW_QUOTE, 6, 100, 1);
        vm.expectRevert(DarliDeployer.AlreadyDeployed.selector);
        d.deploy("USDarli", "USDarli", minters, pm, LOW_QUOTE, 6, 100, 1);
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
        d.deploy("USDarli", "USDarli", minters, pm, LOW_QUOTE, 6, 100, 1);
    }

    /// The pool race (SPEC D2): the attacker computes the token's REAL future address and initialises the REAL key first,
    /// at a wrong price. Deployment must still succeed, must say so, and must end with the same sealed token.
    function test_poolRace_realPredictedAddress() public {
        address quote = LOW_QUOTE;
        address predicted = vm.computeCreateAddress(address(d), vm.getNonce(address(d)));
        (address c0, address c1) = predicted < quote ? (predicted, quote) : (quote, predicted);
        PoolKey memory real = PoolKey(c0, c1, 100, 1, address(0));
        // Wrong price, right key: `initialize` does not care that the token has no code yet. The price is a quarter of par
        // (square root halved). It used to be 12345, which is below v4's MIN_SQRT_PRICE: a real PoolManager would have
        // refused it, so the race it modelled could not happen.
        uint160 attackerPrice = uint160(2 ** 96) * 1e6 / 2;
        vm.prank(address(0xA77AC));
        pm.initialize(real, attackerPrice);
        (StableToken token,) = d.deploy("USDarli", "USDarli", minters, pm, quote, 6, 100, 1);
        assertEq(address(token), predicted, "the address really was predictable");
        assertTrue(d.poolPreInitialised(), "deployment must record that it lost the race");
        assertEq(d.observedSqrtPriceX96(), attackerPrice, "the record must show the price the pool REALLY has");
        assertEq(d.targetSqrtPriceX96(), uint160(2 ** 96) * 1e6, "and, separately, the price that was asked for");
        assertEq(
            pm.priceOf(keccak256(abi.encode(real))),
            attackerPrice,
            "the attacker's price stands until somebody moves it"
        );
        assertTrue(token.mintersSealed());
        (address k0, address k1,,,) = d.canonicalPool();
        assertTrue(k0 == c0 && k1 == c1, "the canonical key is unchanged");
    }

    /// SPEC D2: a failed initialise is NOT proof that the pool exists. With a PoolManager that fails for an
    /// unrelated reason and holds no pool, the deployment must revert instead of reporting success.
    function test_unrelatedInitialiseFailure_revertsInsteadOfFalseSuccess() public {
        BrokenPoolManager broken = new BrokenPoolManager();
        vm.expectRevert(DarliDeployer.PoolAbsentAfterInitialise.selector);
        d.deploy("USDarli", "USDarli", minters, broken, LOW_QUOTE, 6, 100, 1);
        assertFalse(d.deployed(), "a reverted deployment leaves nothing behind and can be retried");
    }

    function test_noRace_flagStaysFalse() public {
        d.deploy("USDarli", "USDarli", minters, pm, LOW_QUOTE, 6, 100, 1);
        assertFalse(d.poolPreInitialised());
        assertEq(d.observedSqrtPriceX96(), d.targetSqrtPriceX96());
    }

    /// v4 does not check that a currency has code, so a mistyped quote would create the canonical pool for ever against
    /// something that is not a token. address(0) is native ETH in v4: "par" against it means nothing.
    function test_quoteWithoutCode_isRefused() public {
        vm.expectRevert(DarliDeployer.QuoteHasNoCode.selector);
        d.deploy("USDarli", "USDarli", minters, pm, address(0xC0FFEE), 6, 100, 1);
        vm.expectRevert(DarliDeployer.QuoteHasNoCode.selector);
        d.deploy("USDarli", "USDarli", minters, pm, address(0), 6, 100, 1);
        assertFalse(d.deployed());
    }

    /// SPEC D2, the layout self-test. When our own initialise succeeds the pool must hold exactly our price; reading
    /// anything else proves the storage layout is not the assumed one, and the deployment must refuse rather than record
    /// a number read from the wrong place.
    function test_uncontestedDeployment_readsBackItsOwnPrice_orRefuses() public {
        ShiftedLayoutPoolManager shifted = new ShiftedLayoutPoolManager();
        vm.expectRevert(DarliDeployer.PoolStateLayoutMismatch.selector);
        d.deploy("USDarli", "USDarli", minters, shifted, LOW_QUOTE, 6, 100, 1);
        assertFalse(d.deployed(), "a refused deployment leaves nothing behind and can be retried");
    }

    /// On the raced path the price cannot be compared with ours, but it must at least be one a v4 pool can hold.
    function test_racedPool_priceNoPoolCanHold_isRefused() public {
        RacedGarbagePoolManager garbage = new RacedGarbagePoolManager();
        vm.expectRevert(DarliDeployer.PoolPriceOutOfRange.selector);
        d.deploy("USDarli", "USDarli", minters, garbage, LOW_QUOTE, 6, 100, 1);
    }

    /// v4 derives the state slot with abi.encodePacked(poolId, POOLS_SLOT); the deployer uses abi.encode. For two bytes32
    /// the two are the same 64 bytes. Argued in a comment until now; pinned here.
    function testFuzz_slotDerivation_encodeEqualsEncodePacked(bytes32 poolId) public pure {
        bytes32 slot = bytes32(uint256(6));
        assertEq(keccak256(abi.encode(poolId, slot)), keccak256(abi.encodePacked(poolId, slot)));
    }

    /// The token's address is the first thing anyone watching the deployment needs; an unindexed address cannot be
    /// filtered on (Slither: unindexed-event-address).
    function test_deployedEvent_indexesTheStablecoin() public {
        vm.recordLogs();
        (StableToken token,) = d.deploy("USDarli", "USDarli", minters, pm, LOW_QUOTE, 6, 100, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Deployed(address,address,address,uint24,int24,uint160,uint160)");
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(d) && logs[i].topics[0] == sig) {
                assertEq(logs[i].topics.length, 2, "exactly the stablecoin is indexed");
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(token));
                seen = true;
            }
        }
        assertTrue(seen, "Deployed was not emitted");
    }

    function test_unsupportedQuoteDecimalsRevert() public {
        vm.expectRevert(DarliDeployer.QuoteDecimalsUnsupported.selector);
        d.deploy("USDarli", "USDarli", minters, pm, LOW_QUOTE, 8, 100, 1);
    }

    // --- SPEC D1: every minter was built for exactly this token --------------------------------------------------------

    function _realBranch(address stableAddress) internal returns (address) {
        address one = address(1); // the parts are not called at construction; the stablecoin is the point here
        return address(
            new BranchManager(
                BranchConfig({
                    stable: IStableToken(stableAddress),
                    collToken: IERC20(one),
                    feed: IPriceFeed(one),
                    vault: ICollateralVault(one),
                    nft: ITroveNFT(one),
                    list: IRateSortedList(one),
                    stabilityPool: IStabilityPool(one),
                    frontends: IFrontendRegistry(one),
                    escrow: one,
                    mcr: 110e16,
                    ccr: 150e16,
                    scr: 110e16,
                    minDebt: 500e18,
                    minRate: 5e15,
                    maxRate: 250e16,
                    cap0: 125_000e18,
                    capCeiling: 250_000e18,
                    gasDeposit: 0,
                    spShare: 72e16,
                    penSp: 5e16,
                    penRedist: 10e16,
                    liqBonus: 5e15,
                    liqBonusCap: 2e18
                })
            )
        );
    }

    /// A real BranchManager, built against the token's real predicted address, is accepted and sealed as a minter.
    function test_branchBuiltForThePredictedToken_isSealed() public {
        address[] memory m = new address[](1);
        m[0] = _realBranch(_tokenOf(d));
        (StableToken token,) = d.deploy("USDarli", "USDarli", m, pm, LOW_QUOTE, 6, 100, 1);
        assertTrue(token.isMinter(m[0]), "D1: the branch built for this token is its minter");
        assertEq(address(BranchManager(m[0]).stable()), address(token));
    }

    /// A branch built for any other address would be a minter for ever of a token it does not mint: refused, and the
    /// deployment leaves nothing behind.
    function test_minterBuiltForAnotherToken_isRefused() public {
        address[] memory m = new address[](2);
        m[0] = _realBranch(_tokenOf(d));
        m[1] = _realBranch(address(0xDEAD)); // off by anything: a wrong nonce, a wrong deployer, a typo
        vm.expectRevert(abi.encodeWithSelector(DarliDeployer.MinterNotBuiltForThisToken.selector, m[1]));
        d.deploy("USDarli", "USDarli", m, pm, LOW_QUOTE, 6, 100, 1);
        assertFalse(d.deployed(), "D1: a refused deployment leaves nothing behind and can be retried");
    }

    /// Something that cannot name its token is not a branch: an address without code, a contract without `stable()`.
    function test_minterThatCannotNameItsToken_isRefused() public {
        address[] memory m = new address[](1);
        m[0] = address(0xB1);
        vm.expectRevert(abi.encodeWithSelector(DarliDeployer.MinterNotBuiltForThisToken.selector, address(0xB1)));
        d.deploy("USDarli", "USDarli", m, pm, LOW_QUOTE, 6, 100, 1);
        m[0] = address(pm);
        vm.expectRevert(abi.encodeWithSelector(DarliDeployer.MinterNotBuiltForThisToken.selector, address(pm)));
        d.deploy("USDarli", "USDarli", m, pm, LOW_QUOTE, 6, 100, 1);
    }
}
