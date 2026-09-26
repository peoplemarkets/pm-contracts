// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {EventMarketRouter} from "../../src/events/EventMarketRouter.sol";
import {IEventMarketRouter} from "../../src/events/IEventMarketRouter.sol";

/// @dev Exact pre-signature EventMarketRouter storage shape. The harness lets the test seed a
///      legacy proxy without retaining the unsafe unsigned implementation in production source.
contract LegacyEventMarketRouterHarness is Initializable, UUPSUpgradeable {
    bytes32 internal constant EVENT_MARKET_ROUTER_SLOT = keccak256("people.markets.eventmarketrouter.v1");

    struct Layout {
        address governance;
        uint32 timelockDelay;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        address factory;
        address usdc;
        mapping(address => bool) operators;
        mapping(address => uint64) pendingOperatorActivatesAt;
    }

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = EVENT_MARKET_ROUTER_SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address governance_,
        address factory_,
        address usdc_,
        uint32 timelockDelay_
    )
        external
        initializer
    {
        Layout storage s = _s();
        s.governance = governance_;
        s.factory = factory_;
        s.usdc = usdc_;
        s.timelockDelay = timelockDelay_;
    }

    function seedOperator(address operator) external {
        require(msg.sender == _s().governance, "governance only");
        _s().operators[operator] = true;
    }

    function seedPendingGovernance(address account, uint64 activatesAt) external {
        require(msg.sender == _s().governance, "governance only");
        _s().pendingGovernance = account;
        _s().pendingGovernanceActivatesAt = activatesAt;
    }

    function seedPendingOperator(address account, uint64 activatesAt) external {
        require(msg.sender == _s().governance, "governance only");
        _s().pendingOperatorActivatesAt[account] = activatesAt;
    }

    function governance() external view returns (address) {
        return _s().governance;
    }

    function factory() external view returns (address) {
        return _s().factory;
    }

    function usdc() external view returns (address) {
        return _s().usdc;
    }

    function timelockDelay() external view returns (uint32) {
        return _s().timelockDelay;
    }

    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        Layout storage s = _s();
        return (s.pendingGovernance, s.pendingGovernanceActivatesAt);
    }

    function isOperator(address operator) external view returns (bool) {
        return _s().operators[operator];
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == _s().governance, "governance only");
    }
}

contract EventMarketRouterUpgradeTest is Test {
    address internal governance = makeAddr("governance");
    address internal factory = makeAddr("factory");
    address internal usdc = makeAddr("usdc");
    address internal operator = makeAddr("operator");
    address internal pendingOperator = makeAddr("pendingOperator");
    address internal pendingGovernance = makeAddr("pendingGovernance");
    address internal trader = makeAddr("trader");
    uint32 internal constant TIMELOCK = 1 days;

    function test_upgradePreservesLegacyConfigAndAppendsReplayState() public {
        LegacyEventMarketRouterHarness legacyImplementation = new LegacyEventMarketRouterHarness();
        bytes memory initData =
            abi.encodeCall(LegacyEventMarketRouterHarness.initialize, (governance, factory, usdc, TIMELOCK));
        address proxy = address(new ERC1967Proxy(address(legacyImplementation), initData));
        LegacyEventMarketRouterHarness legacy = LegacyEventMarketRouterHarness(proxy);

        vm.prank(governance);
        legacy.seedOperator(operator);
        vm.prank(governance);
        legacy.seedPendingGovernance(pendingGovernance, 1_900_100_000);
        vm.prank(governance);
        legacy.seedPendingOperator(pendingOperator, 1_900_200_000);
        assertEq(legacy.governance(), governance);
        assertEq(legacy.factory(), factory);
        assertEq(legacy.usdc(), usdc);
        assertEq(legacy.timelockDelay(), TIMELOCK);
        assertTrue(legacy.isOperator(operator));
        (address legacyPendingGovernance, uint64 legacyGovernanceActivatesAt) = legacy.pendingGovernance();
        assertEq(legacyPendingGovernance, pendingGovernance);
        assertEq(legacyGovernanceActivatesAt, 1_900_100_000);

        EventMarketRouter signedImplementation = new EventMarketRouter();
        vm.prank(governance);
        UUPSUpgradeable(proxy).upgradeToAndCall(address(signedImplementation), "");
        EventMarketRouter upgraded = EventMarketRouter(proxy);

        assertEq(upgraded.governance(), governance, "governance changed");
        assertEq(upgraded.factory(), factory, "factory changed");
        assertEq(upgraded.usdc(), usdc, "USDC changed");
        assertEq(upgraded.timelockDelay(), TIMELOCK, "timelock changed");
        assertTrue(upgraded.isOperator(operator), "operator allowlist changed");
        (address upgradedPendingGovernance, uint64 upgradedGovernanceActivatesAt) = upgraded.pendingGovernance();
        assertEq(upgradedPendingGovernance, pendingGovernance, "pending governance changed");
        assertEq(upgradedGovernanceActivatesAt, 1_900_100_000, "pending governance activation changed");
        assertEq(
            upgraded.pendingOperatorActivatesAt(pendingOperator), 1_900_200_000, "pending operator activation changed"
        );
        assertFalse(upgraded.isNonceUsed(trader, 0), "new replay state not empty");
        assertEq(upgraded.minimumValidNonce(trader), 0, "new nonce floor not empty");
        assertNotEq(upgraded.domainSeparator(), bytes32(0), "signed domain unavailable");

        vm.prank(trader);
        upgraded.invalidateNoncesBelow(42);
        assertEq(upgraded.minimumValidNonce(trader), 42, "new replay state not writable");
        assertEq(upgraded.governance(), governance, "new mapping clobbered governance");
        assertEq(upgraded.factory(), factory, "new mapping clobbered factory");
        assertEq(upgraded.usdc(), usdc, "new mapping clobbered USDC");
        assertEq(upgraded.timelockDelay(), TIMELOCK, "new mapping clobbered timelock");
        assertTrue(upgraded.isOperator(operator), "new mapping clobbered operator");

        vm.prank(operator);
        vm.expectRevert(IEventMarketRouter.SignedOrderRequired.selector);
        upgraded.buyOutcomeFor(trader, factory, true, 1, 0);
    }
}
