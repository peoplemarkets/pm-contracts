// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {FundingEngine} from "../src/core/FundingEngine.sol";
import {IFundingEngine} from "../src/core/IFundingEngine.sol";
import {ILPVault} from "../src/core/ILPVault.sol";
import {IMarginEngine} from "../src/core/IMarginEngine.sol";
import {IPerpEngine} from "../src/core/IPerpEngine.sol";
import {LPVault} from "../src/core/LPVault.sol";
import {MarginEngine} from "../src/core/MarginEngine.sol";
import {PerpEngine} from "../src/core/PerpEngine.sol";
import {IOracleRouter} from "../src/oracle/IOracleRouter.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {SignedFeedAdapter} from "../src/oracle/SignedFeedAdapter.sol";
import {ISubjectRegistry} from "../src/registry/ISubjectRegistry.sol";
import {SubjectRegistry} from "../src/registry/SubjectRegistry.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev FundingEngine end-to-end test suite. Wires the full Tier-1 stack (USDC + SubjectRegistry +
///      LPVault + PerpEngine + OracleRouter + SignedFeedAdapter + FundingEngine) and exercises:
///        - initialize: parameters, zero-address gates, timelock bounds, defaults
///        - registerSubject / deregisterSubject: happy + error paths
///        - setSentimentScore: bounds, only-writer, subject-not-registered
///        - Sentiment-writer rotation: timelocked add (propose/activate/cancel), immediate remove
///        - setFundingCoefficients: midpoint happy + per-field band errors
///        - pokeFunding:
///            * first poke on a fresh subject (lastFundingAt == 0) seeds clock with rate=0
///            * second poke after elapsed time advances the cumulative index
///            * subject not registered ⇒ reverts
///            * same-block double poke ⇒ elapsed=0 no-op
///            * subject paused ⇒ pushFundingIndex reverts via requireTradeable
///            * negative funding (short-heavy + mark < index) ⇒ index goes down
///            * clamping: extreme premium hits ±F_max
///        - Governance transfer timelocked
///        - Pass-through views
contract FundingEngineTest is Test {
    // ------------------------------------------------------------------------------------------
    // System under test + dependencies
    // ------------------------------------------------------------------------------------------

    FundingEngine internal funding;
    PerpEngine internal engine;
    MarginEngine internal marginEngine;
    LPVault internal vault;
    SubjectRegistry internal registry;
    OracleRouter internal router;
    SignedFeedAdapter internal adapter;
    MockUSDC internal usdc;

    // ------------------------------------------------------------------------------------------
    // Actors
    // ------------------------------------------------------------------------------------------

    address internal governance = makeAddr("governance");
    address internal vaultOperator = makeAddr("vaultOperator");
    address internal routerOperator = makeAddr("routerOperator");
    address internal regAdmin = makeAddr("regAdmin");
    address internal regGuardian = makeAddr("regGuardian");
    address internal kycWriter = makeAddr("kycWriter");
    address internal markWriter = makeAddr("markWriter");
    address internal sentimentWriter = makeAddr("sentimentWriter");
    address internal newSentimentWriter = makeAddr("newSentimentWriter");
    address internal stranger = makeAddr("stranger");
    address internal newGovernance = makeAddr("newGovernance");

    address internal alice = makeAddr("alice"); // LP
    address internal traderLong = makeAddr("traderLong");
    address internal traderShort = makeAddr("traderShort");

    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    bytes32 internal constant SUBJECT_ID = keccak256("drake");
    bytes32 internal constant SUBJECT_ID_UNREGISTERED = keccak256("not-registered");
    bytes32 internal constant CATEGORY_ID = keccak256("musician");
    bytes32 internal constant METRIC_ID = keccak256("metric.spotify.monthlies.drake");
    bytes32 internal constant INDEX_METRIC_ID = keccak256("metric.index.drake");

    uint32 internal constant TIMELOCK_DELAY = 2 days;
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant USDC_1M = 1_000_000 * ONE_USDC;
    uint256 internal constant USDC_10M = 10 * USDC_1M;
    uint256 internal constant ONE_18 = 1e18;
    uint256 internal constant INITIAL_MARK = 100 * ONE_18; // $100 / Drake
    uint256 internal constant INDEX_VALUE = 100 * ONE_18; // reference index

    // Spec midpoints (mechanismdesign.md §2 lines 70-77)
    int256 internal constant DEFAULT_K_PREMIUM = 1.25e16;
    int256 internal constant DEFAULT_K_SENTIMENT = 4e15;
    int256 internal constant DEFAULT_K_SKEW = 3e15;
    int256 internal constant DEFAULT_F_MAX = 7.5e14;

    // Coefficient bounds (spec §2 ranges)
    int256 internal constant MIN_K_PREMIUM = 5e15;
    int256 internal constant MAX_K_PREMIUM = 2.5e16;
    int256 internal constant MIN_K_SENTIMENT = 1e15;
    int256 internal constant MAX_K_SENTIMENT = 1e16;
    int256 internal constant MIN_K_SKEW = 1e15;
    int256 internal constant MAX_K_SKEW = 8e15;
    int256 internal constant MIN_F_MAX = 5e14;
    int256 internal constant MAX_F_MAX = 1.5e15;

    // 3-of-5 signer keys for the SignedFeedAdapter
    uint256[5] internal signerKeys = [uint256(0xA1), 0xA2, 0xA3, 0xA4, 0xA5];
    address[5] internal signerAddrs;
    uint64 internal pushNonce;

    // ------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------

    function setUp() public {
        vm.warp(2_000_000_000);

        usdc = new MockUSDC();

        // 1. SubjectRegistry behind UUPS.
        {
            SubjectRegistry impl = new SubjectRegistry();
            address[] memory admins = new address[](1);
            admins[0] = regAdmin;
            address[] memory guardians = new address[](1);
            guardians[0] = regGuardian;
            address[] memory writers = new address[](1);
            writers[0] = kycWriter;
            bytes memory initData =
                abi.encodeCall(SubjectRegistry.initialize, (governance, TIMELOCK_DELAY, admins, guardians, writers));
            registry = SubjectRegistry(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 2. LPVault behind UUPS.
        {
            LPVault impl = new LPVault();
            bytes memory initData = abi.encodeCall(
                LPVault.initialize,
                (IERC20(address(usdc)), governance, vaultOperator, TIMELOCK_DELAY, "People Markets LP USDC", "pmUSDC")
            );
            vault = LPVault(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 3. PerpEngine behind UUPS.
        {
            PerpEngine impl = new PerpEngine();
            bytes memory initData =
                abi.encodeCall(PerpEngine.initialize, (governance, TIMELOCK_DELAY, address(registry), address(vault)));
            engine = PerpEngine(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 3b. MarginEngine behind UUPS — Wave 4 extraction.
        {
            MarginEngine impl = new MarginEngine();
            bytes memory initData =
                abi.encodeCall(MarginEngine.initialize, (governance, address(engine), TIMELOCK_DELAY));
            marginEngine = MarginEngine(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 4. OracleRouter behind UUPS.
        {
            OracleRouter impl = new OracleRouter();
            bytes memory initData =
                abi.encodeCall(OracleRouter.initialize, (governance, routerOperator, TIMELOCK_DELAY));
            router = OracleRouter(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 5. SignedFeedAdapter (the index source).
        for (uint256 i = 0; i < 5; ++i) {
            signerAddrs[i] = vm.addr(signerKeys[i]);
        }
        adapter = new SignedFeedAdapter(
            IOracleRouter(address(router)), governance, routerOperator, TIMELOCK_DELAY, signerAddrs
        );

        // 6. Register the index metric in the router.
        IOracleRouter.MetricConfig memory cfg = IOracleRouter.MetricConfig({
            sourceType: IOracleRouter.SourceType.SIGNED,
            adapter: address(adapter),
            fallbackAdapter: address(0),
            staleAfter: 1 hours,
            maxDeltaBps: 5_000, // 50% — large headroom for index moves in tests
            degraded: false,
            expectedCadenceSeconds: 300
        });
        vm.prank(governance);
        router.proposeRegister(INDEX_METRIC_ID, cfg);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        router.activateRegister(INDEX_METRIC_ID);

        // 7. Wire LPVault.perpEngine to the engine address (timelocked).
        vm.prank(governance);
        vault.proposeSetPerpEngine(address(engine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateSetPerpEngine();

        // 7b. Wire PerpEngine.marginEngine (timelocked).
        vm.prank(governance);
        engine.proposeSetMarginEngine(address(marginEngine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetMarginEngine();

        // 8. Configure SubjectRegistry: list subjects + KYC tiers.
        vm.startPrank(regAdmin);
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);
        vm.stopPrank();
        vm.startPrank(kycWriter);
        registry.setKycTier(traderLong, 3);
        registry.setKycTier(traderShort, 3);
        vm.stopPrank();

        // 9. KYC caps live on MarginEngine; mark writer + delta cap stay on PerpEngine.
        vm.prank(governance);
        marginEngine.setKycCaps(3, 1_000_000 * ONE_USDC, 4_000_000 * ONE_USDC);
        vm.startPrank(governance);
        engine.setMarkMaxDeltaBps(5_000);
        engine.proposeAddMarkWriter(markWriter);
        vm.stopPrank();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateAddMarkWriter(markWriter);

        // 10. Push initial mark.
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, INITIAL_MARK);

        // 11. Fund actors + seed the vault so OI caps are meaningful.
        usdc.mint(alice, USDC_10M);
        usdc.mint(traderLong, USDC_1M);
        usdc.mint(traderShort, USDC_1M);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(traderLong);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(traderShort);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);
        engine.pokeCappedTvl();

        // 12. Deploy FundingEngine behind UUPS.
        {
            FundingEngine impl = new FundingEngine();
            bytes memory initData =
                abi.encodeCall(FundingEngine.initialize, (governance, address(engine), address(router), TIMELOCK_DELAY));
            funding = FundingEngine(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 13. Wire PerpEngine.fundingEngine = funding (timelocked).
        vm.prank(governance);
        engine.proposeSetFundingEngine(address(funding));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetFundingEngine();

        // 14. Register the subject + add the sentiment writer in the FundingEngine.
        vm.prank(governance);
        funding.registerSubject(SUBJECT_ID, INDEX_METRIC_ID);
        vm.prank(governance);
        funding.proposeAddSentimentWriter(sentimentWriter);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        funding.activateAddSentimentWriter(sentimentWriter);

        // 15. Push an initial value via the SignedFeed for the index metric.
        _pushIndex(INDEX_VALUE, uint64(block.timestamp));
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _digest(uint256 value, uint64 valueTimestamp, uint64 nonce) internal view returns (bytes32) {
        return adapter.hashTypedData(INDEX_METRIC_ID, value, valueTimestamp, nonce);
    }

    function _sign(uint256 privKey, bytes32 d) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, d);
        return abi.encodePacked(r, s, v);
    }

    function _pushIndex(uint256 value, uint64 valueTimestamp) internal {
        unchecked {
            pushNonce += 1;
        }
        bytes32 d = _digest(value, valueTimestamp, pushNonce);
        SignedFeedAdapter.SignerSig[] memory sigs = new SignedFeedAdapter.SignerSig[](3);
        sigs[0] = SignedFeedAdapter.SignerSig({signerIndex: 0, signature: _sign(signerKeys[0], d)});
        sigs[1] = SignedFeedAdapter.SignerSig({signerIndex: 1, signature: _sign(signerKeys[1], d)});
        sigs[2] = SignedFeedAdapter.SignerSig({signerIndex: 2, signature: _sign(signerKeys[2], d)});
        adapter.pushUpdate(INDEX_METRIC_ID, value, valueTimestamp, pushNonce, sigs);
    }

    function _baseOpenParams(
        bytes32 subject,
        IPerpEngine.Side side,
        uint256 size
    )
        internal
        view
        returns (IPerpEngine.OpenParams memory p)
    {
        p = IPerpEngine.OpenParams({
            subjectId: subject,
            side: side,
            collateralAmount: size / 5, // 5× leverage
            sizeNotional: size,
            expectedMark: INITIAL_MARK,
            maxSlippageBps: 10_000,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
    }

    function _refreshMark(uint256 newMark) internal {
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, newMark);
    }

    function _openLong(uint256 size) internal returns (bytes32) {
        // Re-stamp mark right before opening so the 30s staleness window doesn't bite after
        // setUp's multi-warp timelock dance.
        _refreshMark(INITIAL_MARK);
        vm.prank(traderLong);
        return engine.openPosition(_baseOpenParams(SUBJECT_ID, IPerpEngine.Side.LONG, size));
    }

    function _openShort(uint256 size) internal returns (bytes32) {
        _refreshMark(INITIAL_MARK);
        vm.prank(traderShort);
        return engine.openPosition(_baseOpenParams(SUBJECT_ID, IPerpEngine.Side.SHORT, size));
    }

    // ------------------------------------------------------------------------------------------
    // initialize
    // ------------------------------------------------------------------------------------------

    function test_Initialize_StoresParams() public view {
        assertEq(funding.governance(), governance);
        assertEq(funding.perpEngine(), address(engine));
        assertEq(funding.oracleRouter(), address(router));
        assertEq(funding.timelockDelay(), TIMELOCK_DELAY);
        assertEq(funding.kPremium_e18(), DEFAULT_K_PREMIUM);
        assertEq(funding.kSentiment_e18(), DEFAULT_K_SENTIMENT);
        assertEq(funding.kSkew_e18(), DEFAULT_K_SKEW);
        assertEq(funding.fMaxPerHour_e18(), DEFAULT_F_MAX);
    }

    function test_Initialize_RevertOnZeroGovernance() public {
        FundingEngine impl = new FundingEngine();
        bytes memory initData =
            abi.encodeCall(FundingEngine.initialize, (address(0), address(engine), address(router), TIMELOCK_DELAY));
        vm.expectRevert(IFundingEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroPerpEngine() public {
        FundingEngine impl = new FundingEngine();
        bytes memory initData =
            abi.encodeCall(FundingEngine.initialize, (governance, address(0), address(router), TIMELOCK_DELAY));
        vm.expectRevert(IFundingEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroOracleRouter() public {
        FundingEngine impl = new FundingEngine();
        bytes memory initData =
            abi.encodeCall(FundingEngine.initialize, (governance, address(engine), address(0), TIMELOCK_DELAY));
        vm.expectRevert(IFundingEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooShort() public {
        FundingEngine impl = new FundingEngine();
        bytes memory initData =
            abi.encodeCall(FundingEngine.initialize, (governance, address(engine), address(router), uint32(1 minutes)));
        vm.expectRevert(IFundingEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooLong() public {
        FundingEngine impl = new FundingEngine();
        bytes memory initData =
            abi.encodeCall(FundingEngine.initialize, (governance, address(engine), address(router), uint32(60 days)));
        vm.expectRevert(IFundingEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_DoubleInitReverts() public {
        vm.expectRevert();
        funding.initialize(governance, address(engine), address(router), TIMELOCK_DELAY);
    }

    // ------------------------------------------------------------------------------------------
    // registerSubject / deregisterSubject
    // ------------------------------------------------------------------------------------------

    function test_RegisterSubject_HappyPath() public {
        bytes32 newSubject = keccak256("taylor");
        bytes32 newMetric = keccak256("metric.index.taylor");
        vm.expectEmit(true, true, false, false, address(funding));
        emit IFundingEngine.SubjectRegistered(newSubject, newMetric);
        vm.prank(governance);
        funding.registerSubject(newSubject, newMetric);
        assertEq(funding.metricForSubject(newSubject), newMetric);
        assertEq(funding.subjectForMetric(newMetric), newSubject);
    }

    function test_RegisterSubject_RevertOnZeroSubject() public {
        vm.prank(governance);
        vm.expectRevert(IFundingEngine.InvalidConfig.selector);
        funding.registerSubject(bytes32(0), keccak256("foo"));
    }

    function test_RegisterSubject_RevertOnZeroMetric() public {
        vm.prank(governance);
        vm.expectRevert(IFundingEngine.InvalidConfig.selector);
        funding.registerSubject(keccak256("foo"), bytes32(0));
    }

    function test_RegisterSubject_RevertOnReRegister() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.SubjectAlreadyRegistered.selector, SUBJECT_ID));
        funding.registerSubject(SUBJECT_ID, INDEX_METRIC_ID);
    }

    function test_RegisterSubject_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.Unauthorized.selector, stranger));
        funding.registerSubject(keccak256("a"), keccak256("b"));
    }

    /// @dev Wave 7 audit Fix #2: a second register of an already-bound metric MUST revert
    ///      `MetricAlreadyBound`. Pre-fix the reverse-lookup write would silently overwrite
    ///      `metricToSubject[metric]` from subjectA → subjectB while leaving
    ///      `subjectIndexMetric[subjectA]` intact.
    function test_Wave7Fix2_RegisterSubject_RevertOnMetricAlreadyBound() public {
        bytes32 subjectB = keccak256("subject-b");
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.MetricAlreadyBound.selector, INDEX_METRIC_ID));
        funding.registerSubject(subjectB, INDEX_METRIC_ID);

        // Sanity: the reverse-lookup invariant is preserved.
        assertEq(funding.subjectForMetric(INDEX_METRIC_ID), SUBJECT_ID);
        assertEq(funding.metricForSubject(subjectB), bytes32(0));
    }

    function test_DeregisterSubject_HappyPath() public {
        vm.expectEmit(true, true, false, false, address(funding));
        emit IFundingEngine.SubjectDeregistered(SUBJECT_ID, INDEX_METRIC_ID);
        vm.prank(governance);
        funding.deregisterSubject(SUBJECT_ID);
        assertEq(funding.metricForSubject(SUBJECT_ID), bytes32(0));
        assertEq(funding.subjectForMetric(INDEX_METRIC_ID), bytes32(0));
    }

    function test_DeregisterSubject_ClearsSentimentScore() public {
        vm.prank(sentimentWriter);
        funding.setSentimentScore(SUBJECT_ID, 0.5e18);
        assertEq(funding.sentimentScoreOf(SUBJECT_ID), 0.5e18);
        vm.prank(governance);
        funding.deregisterSubject(SUBJECT_ID);
        assertEq(funding.sentimentScoreOf(SUBJECT_ID), 0);
    }

    function test_DeregisterSubject_RevertOnUnregistered() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.SubjectNotRegistered.selector, SUBJECT_ID_UNREGISTERED));
        funding.deregisterSubject(SUBJECT_ID_UNREGISTERED);
    }

    function test_DeregisterSubject_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.Unauthorized.selector, stranger));
        funding.deregisterSubject(SUBJECT_ID);
    }

    // ------------------------------------------------------------------------------------------
    // setSentimentScore
    // ------------------------------------------------------------------------------------------

    function test_SetSentimentScore_Zero() public {
        vm.prank(sentimentWriter);
        funding.setSentimentScore(SUBJECT_ID, 0);
        assertEq(funding.sentimentScoreOf(SUBJECT_ID), 0);
    }

    function test_SetSentimentScore_PositiveMax() public {
        vm.expectEmit(true, false, false, true, address(funding));
        emit IFundingEngine.SentimentScoreSet(SUBJECT_ID, 0, int256(ONE_18), sentimentWriter);
        vm.prank(sentimentWriter);
        funding.setSentimentScore(SUBJECT_ID, int256(ONE_18));
        assertEq(funding.sentimentScoreOf(SUBJECT_ID), int256(ONE_18));
    }

    function test_SetSentimentScore_NegativeMax() public {
        vm.prank(sentimentWriter);
        funding.setSentimentScore(SUBJECT_ID, -int256(ONE_18));
        assertEq(funding.sentimentScoreOf(SUBJECT_ID), -int256(ONE_18));
    }

    function test_SetSentimentScore_RevertOnAboveMax() public {
        int256 score = int256(ONE_18) + 1;
        vm.prank(sentimentWriter);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.SentimentOutOfRange.selector, score));
        funding.setSentimentScore(SUBJECT_ID, score);
    }

    function test_SetSentimentScore_RevertOnBelowMin() public {
        int256 score = -int256(ONE_18) - 1;
        vm.prank(sentimentWriter);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.SentimentOutOfRange.selector, score));
        funding.setSentimentScore(SUBJECT_ID, score);
    }

    function test_SetSentimentScore_RevertOnNonWriter() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.OnlySentimentWriter.selector, stranger));
        funding.setSentimentScore(SUBJECT_ID, 0);
    }

    function test_SetSentimentScore_RevertOnUnregisteredSubject() public {
        vm.prank(sentimentWriter);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.SubjectNotRegistered.selector, SUBJECT_ID_UNREGISTERED));
        funding.setSentimentScore(SUBJECT_ID_UNREGISTERED, 0);
    }

    // ------------------------------------------------------------------------------------------
    // Sentiment-writer rotation
    // ------------------------------------------------------------------------------------------

    function test_ProposeAddSentimentWriter_HappyPath() public {
        uint64 expectedActivateAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, false, false, true, address(funding));
        emit IFundingEngine.SentimentWriterProposed(newSentimentWriter, expectedActivateAt);
        vm.prank(governance);
        funding.proposeAddSentimentWriter(newSentimentWriter);
        assertEq(funding.pendingSentimentWriterActivatesAt(newSentimentWriter), expectedActivateAt);
    }

    function test_ProposeAddSentimentWriter_RevertOnZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(IFundingEngine.InvalidConfig.selector);
        funding.proposeAddSentimentWriter(address(0));
    }

    function test_ProposeAddSentimentWriter_RevertOnAlreadyWriter() public {
        vm.prank(governance);
        vm.expectRevert(IFundingEngine.InvalidConfig.selector);
        funding.proposeAddSentimentWriter(sentimentWriter);
    }

    function test_ProposeAddSentimentWriter_RevertOnPendingExists() public {
        vm.prank(governance);
        funding.proposeAddSentimentWriter(newSentimentWriter);
        vm.prank(governance);
        vm.expectRevert(IFundingEngine.PendingSentimentWriterExists.selector);
        funding.proposeAddSentimentWriter(newSentimentWriter);
    }

    function test_ProposeAddSentimentWriter_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.Unauthorized.selector, stranger));
        funding.proposeAddSentimentWriter(newSentimentWriter);
    }

    function test_ActivateAddSentimentWriter_HappyPath() public {
        vm.prank(governance);
        funding.proposeAddSentimentWriter(newSentimentWriter);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, false, false, false, address(funding));
        emit IFundingEngine.SentimentWriterActivated(newSentimentWriter);
        funding.activateAddSentimentWriter(newSentimentWriter);
        assertTrue(funding.isSentimentWriter(newSentimentWriter));
        assertEq(funding.pendingSentimentWriterActivatesAt(newSentimentWriter), 0);
    }

    function test_ActivateAddSentimentWriter_RevertNoPending() public {
        vm.expectRevert(IFundingEngine.NoPendingSentimentWriter.selector);
        funding.activateAddSentimentWriter(newSentimentWriter);
    }

    function test_ActivateAddSentimentWriter_RevertBeforeTimelock() public {
        vm.prank(governance);
        funding.proposeAddSentimentWriter(newSentimentWriter);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.TimelockNotElapsed.selector, readyAt));
        funding.activateAddSentimentWriter(newSentimentWriter);
    }

    function test_CancelAddSentimentWriter_HappyPath() public {
        vm.prank(governance);
        funding.proposeAddSentimentWriter(newSentimentWriter);
        vm.expectEmit(true, false, false, false, address(funding));
        emit IFundingEngine.SentimentWriterCancelled(newSentimentWriter);
        vm.prank(governance);
        funding.cancelAddSentimentWriter(newSentimentWriter);
        assertEq(funding.pendingSentimentWriterActivatesAt(newSentimentWriter), 0);
    }

    function test_CancelAddSentimentWriter_RevertNoPending() public {
        vm.prank(governance);
        vm.expectRevert(IFundingEngine.NoPendingSentimentWriter.selector);
        funding.cancelAddSentimentWriter(newSentimentWriter);
    }

    function test_CancelAddSentimentWriter_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.Unauthorized.selector, stranger));
        funding.cancelAddSentimentWriter(newSentimentWriter);
    }

    function test_RemoveSentimentWriter_HappyPath() public {
        vm.expectEmit(true, false, false, false, address(funding));
        emit IFundingEngine.SentimentWriterRemoved(sentimentWriter);
        vm.prank(governance);
        funding.removeSentimentWriter(sentimentWriter);
        assertFalse(funding.isSentimentWriter(sentimentWriter));
    }

    function test_RemoveSentimentWriter_RevertOnUnsetWriter() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.SentimentWriterNotSet.selector, stranger));
        funding.removeSentimentWriter(stranger);
    }

    function test_RemoveSentimentWriter_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.Unauthorized.selector, stranger));
        funding.removeSentimentWriter(sentimentWriter);
    }

    // ------------------------------------------------------------------------------------------
    // setFundingCoefficients
    // ------------------------------------------------------------------------------------------

    function test_SetFundingCoefficients_HappyPathAtMidpoints() public {
        int256 newKPremium = 1.5e16;
        int256 newKSentiment = 5e15;
        int256 newKSkew = 4e15;
        int256 newFMax = 1e15;
        vm.expectEmit(false, false, false, true, address(funding));
        emit IFundingEngine.FundingCoefficientsSet(newKPremium, newKSentiment, newKSkew, newFMax);
        vm.prank(governance);
        funding.setFundingCoefficients(newKPremium, newKSentiment, newKSkew, newFMax);
        assertEq(funding.kPremium_e18(), newKPremium);
        assertEq(funding.kSentiment_e18(), newKSentiment);
        assertEq(funding.kSkew_e18(), newKSkew);
        assertEq(funding.fMaxPerHour_e18(), newFMax);
    }

    function test_SetFundingCoefficients_HappyAtBandLow() public {
        vm.prank(governance);
        funding.setFundingCoefficients(MIN_K_PREMIUM, MIN_K_SENTIMENT, MIN_K_SKEW, MIN_F_MAX);
    }

    function test_SetFundingCoefficients_HappyAtBandHigh() public {
        vm.prank(governance);
        funding.setFundingCoefficients(MAX_K_PREMIUM, MAX_K_SENTIMENT, MAX_K_SKEW, MAX_F_MAX);
    }

    function test_SetFundingCoefficients_RevertOnKPremiumBelowMin() public {
        int256 bad = MIN_K_PREMIUM - 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.KPremiumOutOfRange.selector, bad));
        funding.setFundingCoefficients(bad, DEFAULT_K_SENTIMENT, DEFAULT_K_SKEW, DEFAULT_F_MAX);
    }

    function test_SetFundingCoefficients_RevertOnKPremiumAboveMax() public {
        int256 bad = MAX_K_PREMIUM + 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.KPremiumOutOfRange.selector, bad));
        funding.setFundingCoefficients(bad, DEFAULT_K_SENTIMENT, DEFAULT_K_SKEW, DEFAULT_F_MAX);
    }

    function test_SetFundingCoefficients_RevertOnKSentimentBelowMin() public {
        int256 bad = MIN_K_SENTIMENT - 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.KSentimentOutOfRange.selector, bad));
        funding.setFundingCoefficients(DEFAULT_K_PREMIUM, bad, DEFAULT_K_SKEW, DEFAULT_F_MAX);
    }

    function test_SetFundingCoefficients_RevertOnKSentimentAboveMax() public {
        int256 bad = MAX_K_SENTIMENT + 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.KSentimentOutOfRange.selector, bad));
        funding.setFundingCoefficients(DEFAULT_K_PREMIUM, bad, DEFAULT_K_SKEW, DEFAULT_F_MAX);
    }

    function test_SetFundingCoefficients_RevertOnKSkewBelowMin() public {
        int256 bad = MIN_K_SKEW - 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.KSkewOutOfRange.selector, bad));
        funding.setFundingCoefficients(DEFAULT_K_PREMIUM, DEFAULT_K_SENTIMENT, bad, DEFAULT_F_MAX);
    }

    function test_SetFundingCoefficients_RevertOnKSkewAboveMax() public {
        int256 bad = MAX_K_SKEW + 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.KSkewOutOfRange.selector, bad));
        funding.setFundingCoefficients(DEFAULT_K_PREMIUM, DEFAULT_K_SENTIMENT, bad, DEFAULT_F_MAX);
    }

    function test_SetFundingCoefficients_RevertOnFMaxBelowMin() public {
        int256 bad = MIN_F_MAX - 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.FMaxOutOfRange.selector, bad));
        funding.setFundingCoefficients(DEFAULT_K_PREMIUM, DEFAULT_K_SENTIMENT, DEFAULT_K_SKEW, bad);
    }

    function test_SetFundingCoefficients_RevertOnFMaxAboveMax() public {
        int256 bad = MAX_F_MAX + 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.FMaxOutOfRange.selector, bad));
        funding.setFundingCoefficients(DEFAULT_K_PREMIUM, DEFAULT_K_SENTIMENT, DEFAULT_K_SKEW, bad);
    }

    function test_SetFundingCoefficients_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.Unauthorized.selector, stranger));
        funding.setFundingCoefficients(DEFAULT_K_PREMIUM, DEFAULT_K_SENTIMENT, DEFAULT_K_SKEW, DEFAULT_F_MAX);
    }

    // ------------------------------------------------------------------------------------------
    // pokeFunding
    // ------------------------------------------------------------------------------------------

    /// @dev First poke on a fresh subject seeds the clock with rate=0 and `newIndex == oldIndex`.
    function test_PokeFunding_FirstPokeSeedsClock() public {
        assertEq(engine.lastFundingAt(SUBJECT_ID), 0);
        vm.expectEmit(true, false, false, true, address(funding));
        emit IFundingEngine.FundingPoked(SUBJECT_ID, 0, 0, 0, 0);
        funding.pokeFunding(SUBJECT_ID);
        assertEq(engine.lastFundingAt(SUBJECT_ID), uint64(block.timestamp));
        // No index change on the seeding push.
        assertEq(engine.cumulativeFundingIndex(SUBJECT_ID), 0);
    }

    /// @dev Subject not registered ⇒ reverts before reading anything else.
    function test_PokeFunding_RevertOnUnregisteredSubject() public {
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.SubjectNotRegistered.selector, SUBJECT_ID_UNREGISTERED));
        funding.pokeFunding(SUBJECT_ID_UNREGISTERED);
    }

    /// @dev Same-block re-poke is a no-op return. `lastFundingAt` does not change; no event emitted.
    function test_PokeFunding_SameBlockNoOp() public {
        funding.pokeFunding(SUBJECT_ID); // seed
        uint64 lastAt = engine.lastFundingAt(SUBJECT_ID);
        int256 idx = engine.cumulativeFundingIndex(SUBJECT_ID);
        // Second poke in the same block: no state change.
        funding.pokeFunding(SUBJECT_ID);
        assertEq(engine.lastFundingAt(SUBJECT_ID), lastAt);
        assertEq(engine.cumulativeFundingIndex(SUBJECT_ID), idx);
    }

    /// @dev After elapsed time the cumulative index moves. Long-heavy book + mark above index ⇒
    ///      positive rate ⇒ positive delta ⇒ index grows.
    function test_PokeFunding_LongHeavyAboveIndexGrowsCumulative() public {
        funding.pokeFunding(SUBJECT_ID); // seed at t0

        // Open a long-heavy book: $50K long, $30K short.
        _openLong(50_000 * ONE_USDC);
        _openShort(30_000 * ONE_USDC);

        // Mark above index. Push a higher mark (current = INITIAL_MARK = $100; new = $105).
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, 105 * ONE_18);

        // Advance one hour and poke. The mark-staleness window is 30s by default, so refresh first.
        vm.warp(block.timestamp + 1 hours);
        // Refresh the SignedFeed index value (1 hour staleAfter on the metric — push fresh).
        _pushIndex(INDEX_VALUE, uint64(block.timestamp));
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, 105 * ONE_18); // re-stamp mark to defeat staleness

        funding.pokeFunding(SUBJECT_ID);
        int256 idx = engine.cumulativeFundingIndex(SUBJECT_ID);
        assertGt(idx, 0, "index should grow when long-heavy + mark above index");
    }

    /// @dev Short-heavy book + mark below index ⇒ negative rate ⇒ index shrinks.
    function test_PokeFunding_ShortHeavyBelowIndexShrinksCumulative() public {
        funding.pokeFunding(SUBJECT_ID); // seed at t0

        // Open a short-heavy book: $30K long, $50K short.
        _openLong(30_000 * ONE_USDC);
        _openShort(50_000 * ONE_USDC);

        // Mark below index (current $100; new $95).
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, 95 * ONE_18);

        vm.warp(block.timestamp + 1 hours);
        _pushIndex(INDEX_VALUE, uint64(block.timestamp));
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, 95 * ONE_18);

        funding.pokeFunding(SUBJECT_ID);
        int256 idx = engine.cumulativeFundingIndex(SUBJECT_ID);
        assertLt(idx, 0, "index should shrink when short-heavy + mark below index");
    }

    /// @dev Paused subject ⇒ pushFundingIndex reverts via requireTradeable. The exact revert
    ///      surface comes from the registry's `requireTradeable`.
    function test_PokeFunding_RevertOnPausedSubject() public {
        funding.pokeFunding(SUBJECT_ID); // seed
        vm.warp(block.timestamp + 60);

        // Pause the subject via the pause guardian. AUTO_PAUSED.
        vm.prank(regGuardian);
        registry.setAutoPaused(SUBJECT_ID, 1);

        // The next push call inside pokeFunding will hit requireTradeable and revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.AUTO_PAUSED,
                ISubjectRegistry.SubjectStatus.ACTIVE
            )
        );
        funding.pokeFunding(SUBJECT_ID);
    }

    /// @dev Extreme premium hits the F_max clamp. Push a mark wildly above the index — the
    ///      unclamped rate would exceed +F_max so the contract clamps to F_max.
    function test_PokeFunding_ClampsAtFMaxOnExtremePremium() public {
        funding.pokeFunding(SUBJECT_ID); // seed at t0

        // Open balanced OI so the rate only depends on premium (and zero sentiment).
        _openLong(40_000 * ONE_USDC);
        _openShort(40_000 * ONE_USDC);

        // Push a mark 50% above the index — premium = 0.5e18. The premium component alone is
        // kPremium * premium / 1e18 = 1.25e16 * 0.5 = 6.25e15 ≫ F_max (7.5e14). ⇒ clamp at +F_max.
        // INITIAL_MARK is $100; new mark $150 = 50% jump.
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, 150 * ONE_18);

        // Advance exactly one hour so the delta equals the rate verbatim.
        vm.warp(block.timestamp + 1 hours);
        _pushIndex(INDEX_VALUE, uint64(block.timestamp));
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, 150 * ONE_18);

        funding.pokeFunding(SUBJECT_ID);
        int256 idx = engine.cumulativeFundingIndex(SUBJECT_ID);
        // After exactly 1 hour, the cumulative-index delta equals the (clamped) rate. Assert the
        // ceiling: index ≤ DEFAULT_F_MAX (with a small tolerance for the second-level rounding
        // produced by the slight elapsed > 3600 from intermediate operations).
        assertGt(idx, 0);
        // Cap is 7.5e14 over exactly 1 hour. Allow up to 1% overshoot for any second-rounding
        // (delta computes elapsed/3600 via integer division). In practice elapsed == 3600 here.
        assertLe(idx, (DEFAULT_F_MAX * 101) / 100);
    }

    /// @dev Sentiment-only path. Balanced book + mark == index ⇒ only sentiment drives the rate.
    function test_PokeFunding_SentimentDrivenWhenBalanced() public {
        funding.pokeFunding(SUBJECT_ID); // seed

        // Balanced OI so skew is zero; mark already == INITIAL_MARK == INDEX_VALUE so premium = 0.
        _openLong(40_000 * ONE_USDC);
        _openShort(40_000 * ONE_USDC);

        // Set a small positive sentiment of +0.1e18 so the contribution stays under F_max.
        // Expected: kSentiment * 0.1 = 4e15 * 0.1e18 / 1e18 = 4e14, well under F_MAX (7.5e14).
        vm.prank(sentimentWriter);
        funding.setSentimentScore(SUBJECT_ID, 0.1e18);

        vm.warp(block.timestamp + 1 hours);
        _pushIndex(INDEX_VALUE, uint64(block.timestamp));
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, INITIAL_MARK); // restamp mark
        funding.pokeFunding(SUBJECT_ID);

        // Expected delta over 1h = kSentiment * sentiment / 1e18 = 4e15 * 0.1e18 / 1e18 = 4e14.
        // Within F_max so no clamping.
        assertEq(engine.cumulativeFundingIndex(SUBJECT_ID), 4e14);
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer
    // ------------------------------------------------------------------------------------------

    function test_GovernanceTransfer_HappyPath() public {
        uint64 expectedActivateAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, false, false, true, address(funding));
        emit IFundingEngine.GovernanceTransferProposed(newGovernance, expectedActivateAt);
        vm.prank(governance);
        funding.proposeGovernanceTransfer(newGovernance);
        (address pending, uint64 activatesAt) = funding.pendingGovernance();
        assertEq(pending, newGovernance);
        assertEq(activatesAt, expectedActivateAt);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, true, false, false, address(funding));
        emit IFundingEngine.GovernanceTransferActivated(governance, newGovernance);
        funding.activateGovernanceTransfer();
        assertEq(funding.governance(), newGovernance);
    }

    function test_GovernanceTransfer_Cancel() public {
        vm.prank(governance);
        funding.proposeGovernanceTransfer(newGovernance);
        vm.expectEmit(true, false, false, false, address(funding));
        emit IFundingEngine.GovernanceTransferCancelled(newGovernance);
        vm.prank(governance);
        funding.cancelGovernanceTransfer();
        (address pending, uint64 activatesAt) = funding.pendingGovernance();
        assertEq(pending, address(0));
        assertEq(activatesAt, 0);
    }

    function test_GovernanceTransfer_RevertOnZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(IFundingEngine.InvalidConfig.selector);
        funding.proposeGovernanceTransfer(address(0));
    }

    function test_GovernanceTransfer_RevertOnDoubleProposal() public {
        vm.prank(governance);
        funding.proposeGovernanceTransfer(newGovernance);
        vm.prank(governance);
        vm.expectRevert(IFundingEngine.PendingGovernanceTransferExists.selector);
        funding.proposeGovernanceTransfer(newGovernance);
    }

    function test_GovernanceTransfer_ActivateRevertNoPending() public {
        vm.expectRevert(IFundingEngine.NoPendingGovernanceTransfer.selector);
        funding.activateGovernanceTransfer();
    }

    function test_GovernanceTransfer_ActivateRevertBeforeTimelock() public {
        vm.prank(governance);
        funding.proposeGovernanceTransfer(newGovernance);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.TimelockNotElapsed.selector, readyAt));
        funding.activateGovernanceTransfer();
    }

    function test_GovernanceTransfer_CancelRevertNoPending() public {
        vm.prank(governance);
        vm.expectRevert(IFundingEngine.NoPendingGovernanceTransfer.selector);
        funding.cancelGovernanceTransfer();
    }

    function test_GovernanceTransfer_NonGovernancePropose() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.Unauthorized.selector, stranger));
        funding.proposeGovernanceTransfer(newGovernance);
    }

    function test_GovernanceTransfer_NonGovernanceCancel() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.Unauthorized.selector, stranger));
        funding.cancelGovernanceTransfer();
    }

    // ------------------------------------------------------------------------------------------
    // Pass-through views
    // ------------------------------------------------------------------------------------------

    function test_View_CumulativeFundingIndexAndLastFundingAt() public {
        // Before any poke both are zero.
        assertEq(funding.cumulativeFundingIndex(SUBJECT_ID), 0);
        assertEq(funding.lastFundingAt(SUBJECT_ID), 0);
        funding.pokeFunding(SUBJECT_ID); // seed
        assertEq(funding.lastFundingAt(SUBJECT_ID), uint64(block.timestamp));
    }

    function test_View_IsSentimentWriter() public view {
        assertTrue(funding.isSentimentWriter(sentimentWriter));
        assertFalse(funding.isSentimentWriter(stranger));
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    /// @dev `_authorizeUpgrade` is governance-only. Confirms a non-governance caller is rejected
    ///      before any storage layout change can land.
    function test_Upgrade_RevertOnNonGovernance() public {
        FundingEngine newImpl = new FundingEngine();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFundingEngine.Unauthorized.selector, stranger));
        funding.upgradeToAndCall(address(newImpl), "");
    }

    /// @dev Governance can complete an upgrade — exercises `_authorizeUpgrade`'s happy path.
    function test_Upgrade_GovernanceHappyPath() public {
        FundingEngine newImpl = new FundingEngine();
        vm.prank(governance);
        funding.upgradeToAndCall(address(newImpl), "");
        // Post-upgrade: storage preserved.
        assertEq(funding.governance(), governance);
        assertEq(funding.kPremium_e18(), DEFAULT_K_PREMIUM);
    }
}
