// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DarliDeployer, IPoolManagerInit} from "../src/deploy/DarliDeployer.sol";
import {StableToken} from "../src/core/StableToken.sol";
import {FrontendRegistry} from "../src/core/FrontendRegistry.sol";
import {CollateralRegistry} from "../src/core/CollateralRegistry.sol";
import {CollateralVault} from "../src/core/CollateralVault.sol";
import {TroveNFT} from "../src/core/TroveNFT.sol";
import {RateSortedList} from "../src/core/RateSortedList.sol";
import {StabilityPool} from "../src/core/StabilityPool.sol";
import {BranchSettlement} from "../src/core/BranchSettlement.sol";
import {BranchManager, BranchConfig} from "../src/core/BranchManager.sol";
import {InterestEscrow} from "../src/core/InterestEscrow.sol";
import {DarliToken} from "../src/revenue/DarliToken.sol";
import {DarliStaking} from "../src/revenue/DarliStaking.sol";
import {RevenueRouter} from "../src/revenue/RevenueRouter.sol";
import {DarliLiquidityVault} from "../src/liquidity/DarliLiquidityVault.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStableToken} from "../src/interfaces/IStableToken.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {IStabilityPool} from "../src/interfaces/IStabilityPool.sol";
import {IBranchManager, IBranchRedemption, ISettlementHooks} from "../src/interfaces/IBranchManager.sol";
import {
    ICollateralVault,
    IFrontendRegistry,
    ITroveNFT,
    IRateSortedList,
    IInterestEscrow,
    IDarliStaking
} from "../src/interfaces/ICore.sol";

/// One branch: its collateral, its feed and its parameters (`docs/SPEC.md` §2). The collateral and the feed exist before
/// the deployment; everything else of the branch is built by it.
struct BranchParams {
    IERC20 collToken;
    IPriceFeed feed;
    uint256 mcr;
    uint256 ccr;
    uint256 scr;
    uint256 minDebt;
    uint256 minRate;
    uint256 maxRate;
    uint256 cap0;
    uint256 capCeiling;
    uint256 gasDeposit;
    uint256 spShare;
    uint256 penSp;
    uint256 penRedist;
    uint256 liqBonus;
    uint256 liqBonusCap;
    string nftName;
    string nftSymbol;
}

struct SystemParams {
    string name;
    string symbol;
    uint256 frontendShare;
    uint256 betaWad; // SPEC 2: 1 for the pilot
    uint256 initialBaseRate;
    address darliRecipient; // SPEC 13: DARLI supply and distribution, open
    uint256 darliSupply; // SPEC 13: DARLI supply and distribution, open
    IPoolManagerInit poolManager;
    address quote; // SPEC 2: USDC
    uint8 quoteDecimals;
    uint24 poolFee;
    int24 tickSpacing;
    int24 vaultHalfWidthTicks; // the liquidity vault's fixed range, either side of par
    BranchParams[] branches;
}

struct BranchAddrs {
    BranchManager manager;
    CollateralVault vault;
    TroveNFT nft;
    RateSortedList list;
    StabilityPool sp;
    BranchSettlement settlement;
}

struct SystemAddrs {
    DarliDeployer deployer;
    StableToken token;
    FrontendRegistry frontends;
    DarliToken darli;
    InterestEscrow escrow;
    DarliStaking staking;
    RevenueRouter router;
    CollateralRegistry registry;
    DarliLiquidityVault vault;
    BranchAddrs[] branches;
}

/// @title DarliSystemBuild
/// @notice Builds a whole system (`docs/SPEC.md` §10) from one address. Every component is created at the address its
///         creator's nonce predicts, so each can hold its neighbours as immutables before they exist; nothing is wired
///         afterwards, because nothing can be. The order, from the creator's current nonce n:
///           n       DarliDeployer (it creates the stablecoin, its first contract, in the deployment transaction)
///           n+1..6  FrontendRegistry, DarliToken, InterestEscrow, DarliStaking, RevenueRouter, CollateralRegistry
///           then per branch: CollateralVault, TroveNFT, RateSortedList, StabilityPool, BranchSettlement, BranchManager;
///           last, the liquidity vault, bound to the canonical pool's key (D1, D4).
///         Then every immutable link is checked (`checkWiring`), and only then does `DarliDeployer.deploy` create the
///         token, check that every branch names it and seal the minter set for ever (D1). A contract cannot create the
///         whole system in one transaction: the branch alone is near the 24 KB code limit and initcode is capped at twice
///         that. What is sealed in one transaction is what matters: the token, its minters and the pool.
abstract contract DarliSystemBuild is CommonBase {
    error WiringMismatch(string link, uint256 branch);

    function _build(SystemParams memory p, address creator) internal returns (SystemAddrs memory s) {
        uint256 n = vm.getNonce(creator);
        uint256 nb = p.branches.length;
        s.branches = new BranchAddrs[](nb);
        address deployerAt = vm.computeCreateAddress(creator, n);
        IStableToken token = IStableToken(vm.computeCreateAddress(deployerAt, 1)); // the deployer's first creation
        address router = vm.computeCreateAddress(creator, n + 5);
        IBranchRedemption[] memory managers = new IBranchRedemption[](nb);
        for (uint256 i = 0; i < nb; i++) {
            managers[i] = IBranchRedemption(vm.computeCreateAddress(creator, n + 7 + 6 * i + 5));
        }
        s.deployer = new DarliDeployer();
        s.token = StableToken(address(token));
        s.frontends = new FrontendRegistry(token, p.frontendShare);
        s.darli = new DarliToken(p.darliRecipient, p.darliSupply);
        s.escrow = new InterestEscrow(IERC20(address(token)), router);
        s.staking = new DarliStaking(s.darli, IERC20(address(token)), router);
        s.router = new RevenueRouter(
            IERC20(address(token)), IInterestEscrow(address(s.escrow)), IDarliStaking(address(s.staking))
        );
        s.registry = new CollateralRegistry(token, managers, p.betaWad, p.initialBaseRate);
        for (uint256 i = 0; i < nb; i++) {
            s.branches[i] = _buildBranch(p, s, i, address(managers[i]));
        }
        s.vault = new DarliLiquidityVault(
            IPoolManager(address(p.poolManager)),
            address(token),
            p.quote,
            p.quoteDecimals,
            p.poolFee,
            p.tickSpacing,
            p.vaultHalfWidthTicks,
            s.darli
        );
    }

    function _buildBranch(SystemParams memory p, SystemAddrs memory s, uint256 i, address manager)
        internal
        returns (BranchAddrs memory b)
    {
        BranchParams memory q = p.branches[i];
        b.vault = new CollateralVault(q.collToken, manager);
        b.nft = new TroveNFT(manager, q.nftName, q.nftSymbol);
        b.list = new RateSortedList(manager);
        b.sp = new StabilityPool(IERC20(address(s.token)), q.collToken, IBranchManager(manager));
        b.settlement = new BranchSettlement(ISettlementHooks(manager));
        b.manager = new BranchManager(
            BranchConfig({
                stable: IStableToken(address(s.token)),
                collToken: q.collToken,
                feed: q.feed,
                vault: ICollateralVault(address(b.vault)),
                nft: ITroveNFT(address(b.nft)),
                list: IRateSortedList(address(b.list)),
                stabilityPool: IStabilityPool(address(b.sp)),
                frontends: IFrontendRegistry(address(s.frontends)),
                escrow: address(s.escrow),
                collateralRegistry: address(s.registry),
                settlement: address(b.settlement),
                mcr: q.mcr,
                ccr: q.ccr,
                scr: q.scr,
                minDebt: q.minDebt,
                minRate: q.minRate,
                maxRate: q.maxRate,
                cap0: q.cap0,
                capCeiling: q.capCeiling,
                gasDeposit: q.gasDeposit,
                spShare: q.spShare,
                penSp: q.penSp,
                penRedist: q.penRedist,
                liqBonus: q.liqBonus,
                liqBonusCap: q.liqBonusCap
            })
        );
    }

    /// Every immutable link of the system, both ways where a link has two ends. A mismatch means a component was built
    /// for another address than the one it sits at, and would stay so for ever: the deployment must not be sealed.
    function checkWiring(SystemAddrs memory s, SystemParams memory p) public view {
        address t = address(s.token);
        _link(address(s.frontends.stableToken()) == t && s.frontends.share() == p.frontendShare, "frontends", 0);
        _link(address(s.escrow.stable()) == t && s.escrow.router() == address(s.router), "escrow", 0);
        _link(
            address(s.staking.darli()) == address(s.darli) && address(s.staking.reward()) == t
                && s.staking.router() == address(s.router),
            "staking",
            0
        );
        _link(
            address(s.router.stable()) == t && address(s.router.escrow()) == address(s.escrow)
                && address(s.router.staking()) == address(s.staking),
            "router",
            0
        );
        _link(
            address(s.registry.stable()) == t && s.registry.branchCount() == s.branches.length
                && s.registry.betaWad() == p.betaWad,
            "registry",
            0
        );
        for (uint256 i = 0; i < s.branches.length; i++) {
            _checkBranch(s, p.branches[i], i);
        }
        _checkVault(s, p);
    }

    function _checkVault(SystemAddrs memory s, SystemParams memory p) internal view {
        DarliLiquidityVault v = s.vault;
        (address c0, address c1) =
            address(s.token) < p.quote ? (address(s.token), p.quote) : (p.quote, address(s.token));
        _link(
            address(v.poolManager()) == address(p.poolManager) && Currency.unwrap(v.currency0()) == c0
                && Currency.unwrap(v.currency1()) == c1 && v.fee() == p.poolFee && v.tickSpacing() == p.tickSpacing
                && address(v.rewardToken()) == address(s.darli),
            "liquidity vault",
            0
        );
    }

    function _checkBranch(SystemAddrs memory s, BranchParams memory q, uint256 i) internal view {
        BranchAddrs memory b = s.branches[i];
        BranchManager m = b.manager;
        address ma = address(m);
        _link(address(m).code.length > 0, "branch not at its predicted address", i);
        _link(address(s.registry.branches(i)) == ma, "registry lists another branch", i);
        _link(
            address(m.stable()) == address(s.token) && address(m.collToken()) == address(q.collToken)
                && address(m.feed()) == address(q.feed),
            "branch token, collateral or feed",
            i
        );
        _link(
            address(m.vault()) == address(b.vault) && address(m.nft()) == address(b.nft)
                && address(m.list()) == address(b.list) && address(m.stabilityPool()) == address(b.sp)
                && m.settlement() == address(b.settlement),
            "branch parts",
            i
        );
        _link(
            address(m.frontends()) == address(s.frontends) && m.escrow() == address(s.escrow)
                && m.collateralRegistry() == address(s.registry),
            "branch system links",
            i
        );
        _link(
            b.vault.manager() == ma && address(b.vault.collToken()) == address(q.collToken) && b.nft.manager() == ma
                && b.list.branch() == ma && address(b.settlement.branch()) == ma,
            "parts name their branch",
            i
        );
        _link(
            address(b.sp.manager()) == ma && address(b.sp.stable()) == address(s.token)
                && address(b.sp.collToken()) == address(q.collToken),
            "stability pool",
            i
        );
    }

    function _link(bool ok, string memory what, uint256 i) internal pure {
        if (!ok) revert WiringMismatch(what, i);
    }

    /// Builds, checks, and deploys: the token, the sealed minter set and the pool (D1-D2).
    function _deploy(SystemParams memory p, address creator) internal returns (SystemAddrs memory s) {
        s = _build(p, creator);
        checkWiring(s, p);
        address[] memory minters = new address[](s.branches.length);
        for (uint256 i = 0; i < minters.length; i++) {
            minters[i] = address(s.branches[i].manager);
        }
        (StableToken token,) = s.deployer
            .deploy(p.name, p.symbol, minters, p.poolManager, p.quote, p.quoteDecimals, p.poolFee, p.tickSpacing);
        if (address(token) != address(s.token)) revert WiringMismatch("token not at its predicted address", 0);
        // the vault is bound to exactly the pool the deployment initialised (D1)
        (address c0, address c1, uint24 f, int24 ts, address hooks) = s.deployer.canonicalPool();
        _link(
            Currency.unwrap(s.vault.currency0()) == c0 && Currency.unwrap(s.vault.currency1()) == c1
                && s.vault.fee() == f && s.vault.tickSpacing() == ts && hooks == address(0),
            "liquidity vault not bound to the canonical pool",
            0
        );
    }
}

/// @notice `forge script script/DarliSystem.s.sol --rpc-url ... --broadcast`. The decided constants of SPEC §2 are written
///         here; every value SPEC §13 leaves open must be given explicitly (environment), and nothing defaults for it.
contract DeployDarli is Script, DarliSystemBuild {
    uint256 constant PCT = 1e16;

    function run() external returns (SystemAddrs memory s) {
        SystemParams memory p;
        p.name = "USDarli";
        p.symbol = "USDarli";
        p.frontendShare = 3 * PCT; // SPEC 2
        p.betaWad = 1e18; // SPEC 2: β = 1 for the pilot
        p.initialBaseRate = vm.envUint("DARLI_INITIAL_BASE_RATE"); // R6: 10 % for the pilot, 100 % uncapped
        p.darliRecipient = vm.envAddress("DARLI_RECIPIENT"); // open: SPEC 13, DARLI distribution
        p.darliSupply = vm.envUint("DARLI_SUPPLY"); // open: SPEC 13, DARLI supply
        // SPEC 2: the canonical pool and the vault, on Base (addresses checked on a fork: contracts/fork)
        p.poolManager = IPoolManagerInit(0x498581fF718922c3f8e6A244956aF099B2652b2b); // Uniswap v4 PoolManager
        p.quote = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC, native
        p.quoteDecimals = 6;
        p.poolFee = 100; // 0.01 %
        p.tickSpacing = 1;
        p.vaultHalfWidthTicks = 100; // about 1 % either side of par
        p.branches = new BranchParams[](1);
        p.branches[0] = BranchParams({
            collToken: IERC20(0x4200000000000000000000000000000000000006), // WETH on Base
            feed: IPriceFeed(vm.envAddress("WETH_FEED")), // the DualSourcePriceFeed of script/DeployFeed.s.sol
            mcr: 110 * PCT,
            ccr: 150 * PCT,
            scr: 110 * PCT,
            minDebt: vm.envUint("MIN_DEBT"), // SPEC 2: 500, proposed
            minRate: PCT / 2,
            maxRate: 250 * PCT,
            cap0: vm.envUint("DEBT_CAP0"), // SPEC 2: 125,000 for the pilot
            capCeiling: vm.envUint("DEBT_CAP_CEILING"), // SPEC 2: 250,000 for the pilot
            gasDeposit: 1e15, // SPEC 2: 0.001 ETH
            spShare: 72 * PCT,
            penSp: 5 * PCT,
            penRedist: 10 * PCT,
            liqBonus: PCT / 2,
            liqBonusCap: 2e18,
            nftName: "Darli Trove (WETH)",
            nftSymbol: "DTROVE-WETH"
        });
        vm.startBroadcast();
        s = _deploy(p, msg.sender);
        vm.stopBroadcast();
    }
}
