// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IOptimisticOracleV3} from "../../src/oracle/UMAAdapter.sol";

/// @notice Test-only stand-in for UMA OptimisticOracleV3. Implements the subset UMAAdapter calls
///         and exposes test helpers for driving dispute / resolution outcomes.
contract MockOptimisticOracleV3 is IOptimisticOracleV3 {
    using SafeERC20 for IERC20;

    /// @dev Per-assertion bookkeeping. Mirrors the subset of state we need to simulate either the
    ///      auto-truthful-after-liveness path or the disputed-then-DVM-resolves path.
    struct Assertion {
        address asserter;
        address currency;
        uint256 bond;
        uint64 expiresAt;
        uint64 livenessSeconds;
        bool exists;
        bool disputed;
        /// @dev When `dvmResolved == true`, `settleAndGetAssertionResult` returns `dvmTruthful`
        ///      regardless of liveness. When false, the assertion is auto-truthful after liveness.
        bool dvmResolved;
        bool dvmTruthful;
        bool settled;
    }

    /// @dev Auto-incrementing assertion id seed. Each assertion gets keccak256(seed).
    uint256 public nextSeed = 1;

    /// @dev If `forcedNextIdSet == true`, the next `assertTruth` returns `forcedNextId` (which may
    ///      be `bytes32(0)`) and clears the flag. Lets tests force both the zero-id branch and the
    ///      duplicate-id branch in UMAAdapter.
    bytes32 public forcedNextId;
    bool public forcedNextIdSet;

    mapping(bytes32 => Assertion) public assertions;

    /// @notice Submit a truth claim. Mirrors UMA's interface; pulls `bond` of `currency` from the
    ///         caller (assumed to have approved this contract).
    function assertTruth(
        bytes calldata,
        address asserter,
        address,
        address,
        uint64 liveness,
        address currency,
        uint256 bond,
        bytes32,
        bytes32
    )
        external
        override
        returns (bytes32 assertionId)
    {
        // pull bond — UMA's real OO holds the bond until settlement
        IERC20(currency).safeTransferFrom(msg.sender, address(this), bond);

        if (forcedNextIdSet) {
            assertionId = forcedNextId;
            forcedNextId = bytes32(0);
            forcedNextIdSet = false;
        } else {
            unchecked {
                assertionId = keccak256(abi.encode(address(this), nextSeed));
                nextSeed += 1;
            }
        }
        assertions[assertionId] = Assertion({
            asserter: asserter,
            currency: currency,
            bond: bond,
            expiresAt: uint64(block.timestamp) + liveness,
            livenessSeconds: liveness,
            exists: true,
            disputed: false,
            dvmResolved: false,
            dvmTruthful: false,
            settled: false
        });
    }

    /// @notice Settle and return the truth verdict. Mirrors UMA's behavior:
    ///         - undisputed: revert before liveness elapses; return `true` after.
    ///         - disputed but DVM not yet resolved: revert.
    ///         - disputed and DVM resolved: return `dvmTruthful`.
    function settleAndGetAssertionResult(bytes32 assertionId) external override returns (bool truthful) {
        Assertion storage a = assertions[assertionId];
        require(a.exists, "MockOOv3: !assertion");
        require(!a.settled, "MockOOv3: settled");

        if (a.disputed) {
            require(a.dvmResolved, "MockOOv3: dvm not resolved");
            truthful = a.dvmTruthful;
        } else {
            require(block.timestamp >= a.expiresAt, "MockOOv3: liveness");
            truthful = true;
        }
        a.settled = true;
    }

    // ------------------------------------------------------------------------------------------
    // Test helpers
    // ------------------------------------------------------------------------------------------

    /// @notice Mark an assertion as disputed. Bond stays with this contract.
    function disputeAssertion(bytes32 assertionId) external {
        Assertion storage a = assertions[assertionId];
        require(a.exists, "MockOOv3: !assertion");
        require(!a.disputed, "MockOOv3: already disputed");
        require(!a.settled, "MockOOv3: settled");
        a.disputed = true;
    }

    /// @notice Simulate UMA DVM resolving a disputed assertion.
    function resolveDispute(bytes32 assertionId, bool truthful) external {
        Assertion storage a = assertions[assertionId];
        require(a.disputed, "MockOOv3: not disputed");
        a.dvmResolved = true;
        a.dvmTruthful = truthful;
    }

    /// @notice Test-only view of stored assertion state.
    function getAssertion(bytes32 assertionId) external view returns (Assertion memory) {
        return assertions[assertionId];
    }

    /// @notice Force the next assertTruth to return a specific id. Use for collision-path tests.
    ///         Pass `bytes32(0)` to drive the zero-id branch in UMAAdapter.
    function setForcedNextId(bytes32 id) external {
        forcedNextId = id;
        forcedNextIdSet = true;
    }
}
