// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {EventMarket} from "../../src/events/EventMarket.sol";
import {EventMarketFactory} from "../../src/events/EventMarketFactory.sol";

/// @title  TestEventMarket — TEST-ONLY EventMarket with a governance-gated one-call resolve.
/// @notice DO NOT DEPLOY TO PRODUCTION. This contract exists solely to unblock the private,
///         closed, play-money testnet (Base Sepolia) World-Cup dogfood. It extends the production
///         {EventMarket} and adds a single trusted-resolve entrypoint, {resolveForTest}, that lets
///         the factory's governance address settle a market to any outcome in ONE transaction —
///         no UMA metric registration, no bond, no liveness wait, no timelock.
///
/// @dev    Why this instead of the real UMA path? The production resolve path
///         (`proposeResolution` → UMA liveness → `settleResolution`) is faithful, but it requires
///         registering a per-`eventId` metric on the {UMAAdapter}, which is timelocked at a hard
///         floor of `MIN_TIMELOCK_DELAY = 1 hour` (a `constant`, so it cannot be lowered even on a
///         fresh deploy), plus a ≥60s dispute-liveness window per resolution. For an operator
///         driving a live dogfood that is unacceptable friction. This override reuses the EXACT
///         same settlement accounting as production — it calls the shared internal
///         {EventMarket-_finalizeResolution}, so the money movement (surplus seed returned to the
///         LPVault, the feedback impulse) is byte-for-byte identical to the UMA path. Only the
///         gate that decides "what is the outcome" differs.
///
/// @dev    The production {EventMarket} is UNCHANGED in surface: it gained only a behavior-
///         preserving `internal` refactor (`_finalizeResolution`). There is no trusted-resolve
///         backdoor on the production contract. The fresh test stack sets THIS contract as the
///         factory's market implementation; the live perp/event deployment is untouched.
contract TestEventMarket is EventMarket {
    error NotGovernance(address caller);

    event ResolvedForTest(Outcome outcome, address indexed caller);

    /// @notice TEST-ONLY: settle this market to `finalOutcome` in a single call. Callable only by
    ///         the factory's governance address (the deployer/operator of the test stack).
    /// @param  finalOutcome One of YES, NO, or VOID (UNRESOLVED is rejected).
    function resolveForTest(Outcome finalOutcome) external nonReentrant {
        // Gate: only the factory's governance may force-resolve. `factory` is set at init to the
        // EventMarketFactory that cloned this market; we read its live governance address so an
        // ownership rotation is respected automatically.
        address gov = EventMarketFactory(address(factory)).governance();
        if (msg.sender != gov) revert NotGovernance(msg.sender);

        require(
            finalOutcome == Outcome.YES || finalOutcome == Outcome.NO || finalOutcome == Outcome.VOID,
            "TestEventMarket: invalid outcome"
        );
        Status s = this.status();
        require(s == Status.OPEN || s == Status.PENDING_RESOLUTION, "TestEventMarket: already resolved");

        _finalizeResolution(finalOutcome);
        emit ResolvedForTest(finalOutcome, msg.sender);
    }
}
