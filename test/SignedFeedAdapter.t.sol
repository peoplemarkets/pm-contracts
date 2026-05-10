// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test} from "forge-std/Test.sol";

import {IOracleRouter} from "../src/oracle/IOracleRouter.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {SignedFeedAdapter} from "../src/oracle/SignedFeedAdapter.sol";

contract SignedFeedAdapterTest is Test {
    OracleRouter internal router;
    SignedFeedAdapter internal adapter;

    address internal governance = makeAddr("governance");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");
    uint32 internal constant TIMELOCK_DELAY = 2 days;

    // Five signers, accessible by privkey for vm.sign
    uint256[5] internal signerKeys = [uint256(0xA1), 0xA2, 0xA3, 0xA4, 0xA5];
    address[5] internal signerAddrs;

    bytes32 internal constant METRIC_ID = keccak256("metric.spotify.monthlies.drake");
    uint32 internal constant MAX_DELTA_BPS = 300; // 3%

    // ------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------

    function setUp() public {
        // 1. router behind UUPS proxy
        OracleRouter impl = new OracleRouter();
        bytes memory initData = abi.encodeCall(OracleRouter.initialize, (governance, operator, TIMELOCK_DELAY));
        router = OracleRouter(address(new ERC1967Proxy(address(impl), initData)));

        // 2. derive signer addresses
        for (uint256 i = 0; i < 5; ++i) {
            signerAddrs[i] = vm.addr(signerKeys[i]);
        }

        // 3. deploy adapter pointing at router
        adapter =
            new SignedFeedAdapter(IOracleRouter(address(router)), governance, operator, TIMELOCK_DELAY, signerAddrs);

        // 4. register the metric in the router so pushes are accepted
        IOracleRouter.MetricConfig memory cfg = IOracleRouter.MetricConfig({
            sourceType: IOracleRouter.SourceType.SIGNED,
            adapter: address(adapter),
            fallbackAdapter: address(0),
            staleAfter: 1 hours,
            maxDeltaBps: MAX_DELTA_BPS,
            degraded: false
        });
        vm.prank(governance);
        router.proposeRegister(METRIC_ID, cfg);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        router.activateRegister(METRIC_ID);

        // ensure block.timestamp is meaningful for valueTimestamp checks
        vm.warp(2_000_000_000);
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _digest(
        bytes32 metricId,
        uint256 value,
        uint64 valueTimestamp,
        uint64 nonce
    )
        internal
        view
        returns (bytes32)
    {
        return adapter.hashTypedData(metricId, value, valueTimestamp, nonce);
    }

    function _sign(uint256 privKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _threeSigs(
        uint256 value,
        uint64 valueTimestamp,
        uint64 nonce,
        uint8[3] memory indices
    )
        internal
        view
        returns (SignedFeedAdapter.SignerSig[] memory sigs)
    {
        bytes32 d = _digest(METRIC_ID, value, valueTimestamp, nonce);
        sigs = new SignedFeedAdapter.SignerSig[](3);
        for (uint256 i = 0; i < 3; ++i) {
            sigs[i] =
                SignedFeedAdapter.SignerSig({signerIndex: indices[i], signature: _sign(signerKeys[indices[i]], d)});
        }
    }

    function _push(uint256 value, uint64 valueTimestamp, uint64 nonce) internal {
        SignedFeedAdapter.SignerSig[] memory sigs = _threeSigs(value, valueTimestamp, nonce, [uint8(0), 1, 2]);
        adapter.pushUpdate(METRIC_ID, value, valueTimestamp, nonce, sigs);
    }

    // ------------------------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------------------------

    function test_Constructor_StoresParams() public view {
        assertEq(address(adapter.router()), address(router));
        assertEq(adapter.governance(), governance);
        assertEq(adapter.operator(), operator);
        assertEq(adapter.timelockDelay(), TIMELOCK_DELAY);
        address[5] memory s = adapter.getSigners();
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(s[i], signerAddrs[i]);
        }
    }

    function test_Constructor_RevertOnZeroRouter() public {
        vm.expectRevert(SignedFeedAdapter.InvalidConfig.selector);
        new SignedFeedAdapter(IOracleRouter(address(0)), governance, operator, TIMELOCK_DELAY, signerAddrs);
    }

    function test_Constructor_RevertOnZeroGovernance() public {
        vm.expectRevert(SignedFeedAdapter.InvalidConfig.selector);
        new SignedFeedAdapter(IOracleRouter(address(router)), address(0), operator, TIMELOCK_DELAY, signerAddrs);
    }

    function test_Constructor_RevertOnZeroOperator() public {
        vm.expectRevert(SignedFeedAdapter.InvalidConfig.selector);
        new SignedFeedAdapter(IOracleRouter(address(router)), governance, address(0), TIMELOCK_DELAY, signerAddrs);
    }

    function test_Constructor_RevertOnTimelockTooShort() public {
        vm.expectRevert(SignedFeedAdapter.InvalidConfig.selector);
        new SignedFeedAdapter(IOracleRouter(address(router)), governance, operator, 1 minutes, signerAddrs);
    }

    function test_Constructor_RevertOnTimelockTooLong() public {
        vm.expectRevert(SignedFeedAdapter.InvalidConfig.selector);
        new SignedFeedAdapter(IOracleRouter(address(router)), governance, operator, 60 days, signerAddrs);
    }

    function test_Constructor_RevertOnDuplicateSigner() public {
        address[5] memory bad = signerAddrs;
        bad[1] = bad[0]; // duplicate
        vm.expectRevert(SignedFeedAdapter.InvalidSigners.selector);
        new SignedFeedAdapter(IOracleRouter(address(router)), governance, operator, TIMELOCK_DELAY, bad);
    }

    function test_Constructor_RevertOnZeroSigner() public {
        address[5] memory bad = signerAddrs;
        bad[2] = address(0);
        vm.expectRevert(SignedFeedAdapter.InvalidSigners.selector);
        new SignedFeedAdapter(IOracleRouter(address(router)), governance, operator, TIMELOCK_DELAY, bad);
    }

    // ------------------------------------------------------------------------------------------
    // pushUpdate — happy path
    // ------------------------------------------------------------------------------------------

    function test_PushUpdate_FirstPushSucceeds() public {
        uint256 value = 100e18;
        uint64 ts = uint64(block.timestamp);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SignedFeedAdapter.Pushed(METRIC_ID, value, ts, 1);
        _push(value, ts, 1);

        SignedFeedAdapter.SignedReading memory r = adapter.readingOf(METRIC_ID);
        assertEq(r.value, value);
        assertEq(r.valueTimestamp, ts);
        assertEq(r.nonce, 1);
    }

    function test_PushUpdate_SecondPushUpdates() public {
        // Capture-then-warp pattern — see test_PushUpdate_DeltaCapDownwardEnforced for the
        // via-IR + block.timestamp quirk this works around.
        uint64 t1 = uint64(block.timestamp);
        _push(100e18, t1, 1);
        uint64 t2 = t1 + 60;
        vm.warp(t2);
        _push(101e18, t2, 2); // 1% delta < 3% cap
        SignedFeedAdapter.SignedReading memory r = adapter.readingOf(METRIC_ID);
        assertEq(r.value, 101e18);
        assertEq(r.nonce, 2);
    }

    function test_PushUpdate_RouterReadsThroughAdapter() public {
        _push(100e18, uint64(block.timestamp), 1);
        IOracleRouter.OracleReading memory r = router.read(METRIC_ID);
        assertEq(r.value, 100e18);
    }

    function test_PushUpdate_PermissionlessSubmission() public {
        // any random EOA may submit if signatures are valid
        SignedFeedAdapter.SignerSig[] memory sigs = _threeSigs(100e18, uint64(block.timestamp), 1, [uint8(0), 1, 2]);
        vm.prank(stranger);
        adapter.pushUpdate(METRIC_ID, 100e18, uint64(block.timestamp), 1, sigs);
        assertEq(adapter.readingOf(METRIC_ID).value, 100e18);
    }

    // ------------------------------------------------------------------------------------------
    // pushUpdate — paused / config rejections
    // ------------------------------------------------------------------------------------------

    function test_PushUpdate_RevertWhenPaused() public {
        vm.prank(operator);
        adapter.setPaused(true);
        SignedFeedAdapter.SignerSig[] memory sigs = _threeSigs(100e18, uint64(block.timestamp), 1, [uint8(0), 1, 2]);
        vm.expectRevert(SignedFeedAdapter.AdapterPaused.selector);
        adapter.pushUpdate(METRIC_ID, 100e18, uint64(block.timestamp), 1, sigs);
    }

    function test_PushUpdate_RevertOnUnconfiguredMetric() public {
        bytes32 unknownMetric = keccak256("unknown");
        SignedFeedAdapter.SignerSig[] memory sigs = new SignedFeedAdapter.SignerSig[](3);
        bytes32 d = adapter.hashTypedData(unknownMetric, 100e18, uint64(block.timestamp), 1);
        for (uint256 i = 0; i < 3; ++i) {
            sigs[i] = SignedFeedAdapter.SignerSig({signerIndex: uint8(i), signature: _sign(signerKeys[i], d)});
        }
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.MetricNotConfiguredHere.selector, unknownMetric));
        adapter.pushUpdate(unknownMetric, 100e18, uint64(block.timestamp), 1, sigs);
    }

    function test_PushUpdate_RevertWhenAdapterNotActiveForMetric() public {
        // register a second metric pointing at a *different* adapter address; pushing through `adapter`
        // should fail because router config does not list us as the active adapter.
        bytes32 otherMetric = keccak256("other.metric");
        IOracleRouter.MetricConfig memory cfg = IOracleRouter.MetricConfig({
            sourceType: IOracleRouter.SourceType.SIGNED,
            adapter: address(0xBEEF), // not us
            fallbackAdapter: address(0),
            staleAfter: 1 hours,
            maxDeltaBps: MAX_DELTA_BPS,
            degraded: false
        });
        vm.prank(governance);
        router.proposeRegister(otherMetric, cfg);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        router.activateRegister(otherMetric);

        SignedFeedAdapter.SignerSig[] memory sigs = new SignedFeedAdapter.SignerSig[](3);
        bytes32 d = adapter.hashTypedData(otherMetric, 100e18, uint64(block.timestamp), 1);
        for (uint256 i = 0; i < 3; ++i) {
            sigs[i] = SignedFeedAdapter.SignerSig({signerIndex: uint8(i), signature: _sign(signerKeys[i], d)});
        }
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.MetricNotConfiguredHere.selector, otherMetric));
        adapter.pushUpdate(otherMetric, 100e18, uint64(block.timestamp), 1, sigs);
    }

    // ------------------------------------------------------------------------------------------
    // pushUpdate — replay defenses
    // ------------------------------------------------------------------------------------------

    function test_PushUpdate_RevertOnBadNonce() public {
        // first nonce must be 1; submit nonce=2
        SignedFeedAdapter.SignerSig[] memory sigs = _threeSigs(100e18, uint64(block.timestamp), 2, [uint8(0), 1, 2]);
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.BadNonce.selector, uint64(1), uint64(2)));
        adapter.pushUpdate(METRIC_ID, 100e18, uint64(block.timestamp), 2, sigs);
    }

    function test_PushUpdate_RevertOnReplay() public {
        _push(100e18, uint64(block.timestamp), 1);
        // re-submit same payload
        SignedFeedAdapter.SignerSig[] memory sigs = _threeSigs(100e18, uint64(block.timestamp), 1, [uint8(0), 1, 2]);
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.BadNonce.selector, uint64(2), uint64(1)));
        adapter.pushUpdate(METRIC_ID, 100e18, uint64(block.timestamp), 1, sigs);
    }

    function test_PushUpdate_RevertOnNonMonotonicTimestamp() public {
        uint64 ts = uint64(block.timestamp);
        _push(100e18, ts, 1);
        // nonce=2 valid, but timestamp == old timestamp
        SignedFeedAdapter.SignerSig[] memory sigs = _threeSigs(101e18, ts, 2, [uint8(0), 1, 2]);
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.NonMonotonicTimestamp.selector, ts, ts));
        adapter.pushUpdate(METRIC_ID, 101e18, ts, 2, sigs);
    }

    function test_PushUpdate_RevertOnFutureTimestamp() public {
        uint64 future = uint64(block.timestamp + 1);
        SignedFeedAdapter.SignerSig[] memory sigs = _threeSigs(100e18, future, 1, [uint8(0), 1, 2]);
        vm.expectRevert(
            abi.encodeWithSelector(SignedFeedAdapter.TimestampInFuture.selector, future, uint64(block.timestamp))
        );
        adapter.pushUpdate(METRIC_ID, 100e18, future, 1, sigs);
    }

    // ------------------------------------------------------------------------------------------
    // pushUpdate — max-delta cap
    // ------------------------------------------------------------------------------------------

    function test_PushUpdate_DeltaCapEnforcedOnSecondPush() public {
        // Capture-then-warp pattern (see note in test_PushUpdate_DeltaCapDownwardEnforced).
        uint64 t1 = uint64(block.timestamp);
        _push(100e18, t1, 1);
        uint64 t2 = t1 + 60;
        vm.warp(t2);
        SignedFeedAdapter.SignerSig[] memory sigs = _threeSigs(105e18, t2, 2, [uint8(0), 1, 2]);
        vm.expectRevert(
            abi.encodeWithSelector(
                SignedFeedAdapter.DeltaCapExceeded.selector, uint256(100e18), uint256(105e18), MAX_DELTA_BPS
            )
        );
        adapter.pushUpdate(METRIC_ID, 105e18, t2, 2, sigs);
    }

    function test_PushUpdate_DeltaCapAllowsExactly3Percent() public {
        // Capture-then-warp pattern — see test_PushUpdate_DeltaCapDownwardEnforced.
        uint64 t1 = uint64(block.timestamp);
        _push(100e18, t1, 1);
        uint64 t2 = t1 + 60;
        vm.warp(t2);
        // exactly 3% — at cap, should pass (≤ comparison)
        _push(103e18, t2, 2);
        assertEq(adapter.readingOf(METRIC_ID).value, 103e18);
    }

    function test_PushUpdate_DeltaCapDownwardEnforced() public {
        // We capture the timestamp into a local BEFORE the warp and reuse it. Reading
        // `block.timestamp` again after the warp triggers a known solc 0.8.24 + via-IR optimizer
        // pattern that hoists/folds repeated TIMESTAMP reads in test scaffolding when the test
        // also references vm.expectRevert nearby. The contracts themselves are unaffected — they
        // read block.timestamp via TIMESTAMP at call time. This pattern is documented here so
        // future maintainers don't "simplify" back to the broken form.
        uint64 t1 = uint64(block.timestamp);
        _push(100e18, t1, 1);
        uint64 t2 = t1 + 60;
        vm.warp(t2);
        SignedFeedAdapter.SignerSig[] memory sigs = _threeSigs(95e18, t2, 2, [uint8(0), 1, 2]);
        vm.expectRevert(
            abi.encodeWithSelector(
                SignedFeedAdapter.DeltaCapExceeded.selector, uint256(100e18), uint256(95e18), MAX_DELTA_BPS
            )
        );
        adapter.pushUpdate(METRIC_ID, 95e18, t2, 2, sigs);
    }

    function test_PushUpdate_FirstPushSkipsDeltaCheck() public {
        // any value, even huge, allowed on first push (bootstrap)
        _push(1_000_000_000e18, uint64(block.timestamp), 1);
        assertEq(adapter.readingOf(METRIC_ID).value, 1_000_000_000e18);
    }

    // ------------------------------------------------------------------------------------------
    // pushUpdate — signature edge cases
    // ------------------------------------------------------------------------------------------

    function test_PushUpdate_RevertOnTooFewSignatures() public {
        SignedFeedAdapter.SignerSig[] memory sigs = new SignedFeedAdapter.SignerSig[](2);
        bytes32 d = _digest(METRIC_ID, 100e18, uint64(block.timestamp), 1);
        sigs[0] = SignedFeedAdapter.SignerSig({signerIndex: 0, signature: _sign(signerKeys[0], d)});
        sigs[1] = SignedFeedAdapter.SignerSig({signerIndex: 1, signature: _sign(signerKeys[1], d)});
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.WrongSignatureCount.selector, 3, 2));
        adapter.pushUpdate(METRIC_ID, 100e18, uint64(block.timestamp), 1, sigs);
    }

    function test_PushUpdate_RevertOnTooManySignatures() public {
        SignedFeedAdapter.SignerSig[] memory sigs = new SignedFeedAdapter.SignerSig[](4);
        bytes32 d = _digest(METRIC_ID, 100e18, uint64(block.timestamp), 1);
        for (uint256 i = 0; i < 4; ++i) {
            sigs[i] = SignedFeedAdapter.SignerSig({signerIndex: uint8(i), signature: _sign(signerKeys[i], d)});
        }
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.WrongSignatureCount.selector, 3, 4));
        adapter.pushUpdate(METRIC_ID, 100e18, uint64(block.timestamp), 1, sigs);
    }

    function test_PushUpdate_RevertOnSignerIndexOutOfRange() public {
        SignedFeedAdapter.SignerSig[] memory sigs = new SignedFeedAdapter.SignerSig[](3);
        bytes32 d = _digest(METRIC_ID, 100e18, uint64(block.timestamp), 1);
        sigs[0] = SignedFeedAdapter.SignerSig({signerIndex: 0, signature: _sign(signerKeys[0], d)});
        sigs[1] = SignedFeedAdapter.SignerSig({signerIndex: 1, signature: _sign(signerKeys[1], d)});
        sigs[2] = SignedFeedAdapter.SignerSig({signerIndex: 5, signature: _sign(signerKeys[0], d)}); // 5 invalid
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.SignerIndexOutOfRange.selector, uint8(5)));
        adapter.pushUpdate(METRIC_ID, 100e18, uint64(block.timestamp), 1, sigs);
    }

    function test_PushUpdate_RevertOnDuplicateSignerIndex() public {
        // two sigs from index 0 — caught by the ascending-indices invariant
        SignedFeedAdapter.SignerSig[] memory sigs = new SignedFeedAdapter.SignerSig[](3);
        bytes32 d = _digest(METRIC_ID, 100e18, uint64(block.timestamp), 1);
        sigs[0] = SignedFeedAdapter.SignerSig({signerIndex: 0, signature: _sign(signerKeys[0], d)});
        sigs[1] = SignedFeedAdapter.SignerSig({signerIndex: 0, signature: _sign(signerKeys[0], d)});
        sigs[2] = SignedFeedAdapter.SignerSig({signerIndex: 1, signature: _sign(signerKeys[1], d)});
        vm.expectRevert(SignedFeedAdapter.SignerIndicesNotAscending.selector);
        adapter.pushUpdate(METRIC_ID, 100e18, uint64(block.timestamp), 1, sigs);
    }

    function test_PushUpdate_RevertOnNonAscendingIndices() public {
        SignedFeedAdapter.SignerSig[] memory sigs = new SignedFeedAdapter.SignerSig[](3);
        bytes32 d = _digest(METRIC_ID, 100e18, uint64(block.timestamp), 1);
        sigs[0] = SignedFeedAdapter.SignerSig({signerIndex: 2, signature: _sign(signerKeys[2], d)});
        sigs[1] = SignedFeedAdapter.SignerSig({signerIndex: 1, signature: _sign(signerKeys[1], d)});
        sigs[2] = SignedFeedAdapter.SignerSig({signerIndex: 0, signature: _sign(signerKeys[0], d)});
        vm.expectRevert(SignedFeedAdapter.SignerIndicesNotAscending.selector);
        adapter.pushUpdate(METRIC_ID, 100e18, uint64(block.timestamp), 1, sigs);
    }

    function test_PushUpdate_RevertOnSignatureFromWrongKey() public {
        // index 0 declares signer 0, but signature is by signer 4
        SignedFeedAdapter.SignerSig[] memory sigs = new SignedFeedAdapter.SignerSig[](3);
        bytes32 d = _digest(METRIC_ID, 100e18, uint64(block.timestamp), 1);
        sigs[0] = SignedFeedAdapter.SignerSig({signerIndex: 0, signature: _sign(signerKeys[4], d)});
        sigs[1] = SignedFeedAdapter.SignerSig({signerIndex: 1, signature: _sign(signerKeys[1], d)});
        sigs[2] = SignedFeedAdapter.SignerSig({signerIndex: 2, signature: _sign(signerKeys[2], d)});
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.InvalidSignature.selector, uint8(0)));
        adapter.pushUpdate(METRIC_ID, 100e18, uint64(block.timestamp), 1, sigs);
    }

    function test_PushUpdate_RevertOnSignatureForDifferentDigest() public {
        // sign over (value=100), but submit value=200 — recovered signer won't match
        bytes32 d = _digest(METRIC_ID, 100e18, uint64(block.timestamp), 1);
        SignedFeedAdapter.SignerSig[] memory sigs = new SignedFeedAdapter.SignerSig[](3);
        for (uint256 i = 0; i < 3; ++i) {
            sigs[i] = SignedFeedAdapter.SignerSig({signerIndex: uint8(i), signature: _sign(signerKeys[i], d)});
        }
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.InvalidSignature.selector, uint8(0)));
        adapter.pushUpdate(METRIC_ID, 200e18, uint64(block.timestamp), 1, sigs);
    }

    function test_PushUpdate_AcceptsAnyThreeSigners() public {
        // sign with 2,3,4 instead of 0,1,2
        SignedFeedAdapter.SignerSig[] memory sigs = _threeSigs(100e18, uint64(block.timestamp), 1, [uint8(2), 3, 4]);
        adapter.pushUpdate(METRIC_ID, 100e18, uint64(block.timestamp), 1, sigs);
        assertEq(adapter.readingOf(METRIC_ID).value, 100e18);
    }

    // ------------------------------------------------------------------------------------------
    // Signer rotation
    // ------------------------------------------------------------------------------------------

    function test_RotateSigners_HappyPath() public {
        address[5] memory newSet;
        uint256[5] memory newKeys = [uint256(0xB1), 0xB2, 0xB3, 0xB4, 0xB5];
        for (uint256 i = 0; i < 5; ++i) {
            newSet[i] = vm.addr(newKeys[i]);
        }

        vm.expectEmit(false, false, false, true, address(adapter));
        emit SignedFeedAdapter.SignerRotationProposed(newSet, uint64(block.timestamp + TIMELOCK_DELAY));
        vm.prank(governance);
        adapter.proposeSignerRotation(newSet);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit SignedFeedAdapter.SignerRotationActivated(newSet);
        adapter.activateSignerRotation();

        address[5] memory active = adapter.getSigners();
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(active[i], newSet[i]);
        }

        // a push with the OLD signer set should now revert
        SignedFeedAdapter.SignerSig[] memory oldSigs = _threeSigs(100e18, uint64(block.timestamp), 1, [uint8(0), 1, 2]);
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.InvalidSignature.selector, uint8(0)));
        adapter.pushUpdate(METRIC_ID, 100e18, uint64(block.timestamp), 1, oldSigs);

        // ...but a push signed by the NEW set succeeds
        bytes32 d = _digest(METRIC_ID, 100e18, uint64(block.timestamp), 1);
        SignedFeedAdapter.SignerSig[] memory newSigs = new SignedFeedAdapter.SignerSig[](3);
        for (uint256 i = 0; i < 3; ++i) {
            newSigs[i] = SignedFeedAdapter.SignerSig({signerIndex: uint8(i), signature: _sign(newKeys[i], d)});
        }
        adapter.pushUpdate(METRIC_ID, 100e18, uint64(block.timestamp), 1, newSigs);
        assertEq(adapter.readingOf(METRIC_ID).value, 100e18);
    }

    function test_RotateSigners_RevertOnNonGovernance() public {
        address[5] memory newSet = signerAddrs;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.Unauthorized.selector, stranger));
        adapter.proposeSignerRotation(newSet);
    }

    function test_RotateSigners_RevertOnPendingExists() public {
        vm.startPrank(governance);
        adapter.proposeSignerRotation(signerAddrs);
        vm.expectRevert(SignedFeedAdapter.PendingRotationExists.selector);
        adapter.proposeSignerRotation(signerAddrs);
        vm.stopPrank();
    }

    function test_RotateSigners_RevertOnInvalidSet() public {
        address[5] memory bad = signerAddrs;
        bad[1] = bad[0];
        vm.prank(governance);
        vm.expectRevert(SignedFeedAdapter.InvalidSigners.selector);
        adapter.proposeSignerRotation(bad);
    }

    function test_ActivateSignerRotation_RevertOnNoPending() public {
        vm.expectRevert(SignedFeedAdapter.NoPendingRotation.selector);
        adapter.activateSignerRotation();
    }

    function test_ActivateSignerRotation_RevertOnTimelockNotElapsed() public {
        vm.prank(governance);
        adapter.proposeSignerRotation(signerAddrs);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.TimelockNotElapsed.selector, readyAt));
        adapter.activateSignerRotation();
    }

    function test_CancelSignerRotation_HappyPath() public {
        vm.prank(governance);
        adapter.proposeSignerRotation(signerAddrs);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit SignedFeedAdapter.SignerRotationCancelled();
        vm.prank(governance);
        adapter.cancelSignerRotation();
        // pending cleared — re-propose should work
        vm.prank(governance);
        adapter.proposeSignerRotation(signerAddrs);
    }

    function test_CancelSignerRotation_RevertOnNonGovernance() public {
        vm.prank(governance);
        adapter.proposeSignerRotation(signerAddrs);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.Unauthorized.selector, stranger));
        adapter.cancelSignerRotation();
    }

    function test_CancelSignerRotation_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(SignedFeedAdapter.NoPendingRotation.selector);
        adapter.cancelSignerRotation();
    }

    // ------------------------------------------------------------------------------------------
    // Pause
    // ------------------------------------------------------------------------------------------

    function test_SetPaused_HappyPath() public {
        vm.expectEmit(false, false, false, true, address(adapter));
        emit SignedFeedAdapter.PausedSet(true);
        vm.prank(operator);
        adapter.setPaused(true);
        assertTrue(adapter.paused());

        vm.prank(operator);
        adapter.setPaused(false);
        assertFalse(adapter.paused());
    }

    function test_SetPaused_RevertOnNonOperator() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.Unauthorized.selector, stranger));
        adapter.setPaused(true);
    }

    // ------------------------------------------------------------------------------------------
    // Role transfers
    // ------------------------------------------------------------------------------------------

    function test_GovernanceTransfer_HappyPath() public {
        address newGov = makeAddr("newGov");
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SignedFeedAdapter.GovernanceTransferProposed(newGov, uint64(block.timestamp + TIMELOCK_DELAY));
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(newGov);

        // Pre-activation: governance still in place
        assertEq(adapter.governance(), governance);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(stranger); // permissionless after timelock
        vm.expectEmit(true, true, false, false, address(adapter));
        emit SignedFeedAdapter.GovernanceTransferActivated(governance, newGov);
        adapter.activateGovernanceTransfer();
        assertEq(adapter.governance(), newGov);
    }

    function test_ProposeGovernanceTransfer_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.Unauthorized.selector, stranger));
        adapter.proposeGovernanceTransfer(makeAddr("newGov"));
    }

    function test_ProposeGovernanceTransfer_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(SignedFeedAdapter.InvalidConfig.selector);
        adapter.proposeGovernanceTransfer(address(0));
    }

    function test_ProposeGovernanceTransfer_RevertOnPendingExists() public {
        vm.startPrank(governance);
        adapter.proposeGovernanceTransfer(makeAddr("g1"));
        vm.expectRevert(SignedFeedAdapter.PendingGovernanceTransferExists.selector);
        adapter.proposeGovernanceTransfer(makeAddr("g2"));
        vm.stopPrank();
    }

    function test_ActivateGovernanceTransfer_RevertOnNoPending() public {
        vm.expectRevert(SignedFeedAdapter.NoPendingGovernanceTransfer.selector);
        adapter.activateGovernanceTransfer();
    }

    function test_ActivateGovernanceTransfer_RevertBeforeTimelock() public {
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(makeAddr("newGov"));
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.TimelockNotElapsed.selector, readyAt));
        adapter.activateGovernanceTransfer();
    }

    function test_CancelGovernanceTransfer_HappyPath() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(newGov);
        vm.expectEmit(true, false, false, false, address(adapter));
        emit SignedFeedAdapter.GovernanceTransferCancelled(newGov);
        vm.prank(governance);
        adapter.cancelGovernanceTransfer();
        assertEq(adapter.pendingGovernance(), address(0));
        assertEq(adapter.pendingGovernanceActivatesAt(), 0);
    }

    function test_CancelGovernanceTransfer_RevertOnNonGovernance() public {
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(makeAddr("newGov"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.Unauthorized.selector, stranger));
        adapter.cancelGovernanceTransfer();
    }

    function test_CancelGovernanceTransfer_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(SignedFeedAdapter.NoPendingGovernanceTransfer.selector);
        adapter.cancelGovernanceTransfer();
    }

    function test_TransferOperator_HappyPath() public {
        address newOp = makeAddr("newOp");
        vm.expectEmit(true, true, false, false, address(adapter));
        emit SignedFeedAdapter.OperatorTransferred(operator, newOp);
        vm.prank(governance);
        adapter.transferOperator(newOp);
        assertEq(adapter.operator(), newOp);
    }

    function test_TransferOperator_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SignedFeedAdapter.Unauthorized.selector, stranger));
        adapter.transferOperator(makeAddr("newOp"));
    }

    function test_TransferOperator_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(SignedFeedAdapter.InvalidConfig.selector);
        adapter.transferOperator(address(0));
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function test_DomainSeparator_NonZero() public view {
        assertTrue(adapter.domainSeparator() != bytes32(0));
    }

    function test_GetPendingSigners_ReflectsProposal() public {
        address[5] memory bs;
        for (uint256 i = 0; i < 5; ++i) {
            bs[i] = makeAddr(string(abi.encodePacked("sig", vm.toString(i))));
        }
        vm.prank(governance);
        adapter.proposeSignerRotation(bs);
        address[5] memory got = adapter.getPendingSigners();
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(got[i], bs[i]);
        }
    }
}
