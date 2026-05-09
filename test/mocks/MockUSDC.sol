// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only USDC mock. 6 decimals to match real Base USDC. Includes adversarial toggles
///         for proving the production contracts handle non-standard token behavior gracefully.
contract MockUSDC is ERC20 {
    /// @dev When true, every `transfer` and `transferFrom` returns false (does not revert).
    ///      Lets us prove `safeTransfer` / `safeTransferFrom` callers handle the bool path.
    bool public transferShouldReturnFalse;

    /// @dev When true, transfers revert. Models a token that hard-fails (USDC's blocklist).
    bool public transferShouldRevert;

    /// @dev When non-zero, transfers retain this many bps as a fee (recipient receives less).
    ///      Models fee-on-transfer tokens. Production must reject such tokens.
    uint16 public transferFeeBps;

    constructor() ERC20("USD Coin (Mock)", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransferShouldReturnFalse(bool v) external {
        transferShouldReturnFalse = v;
    }

    function setTransferShouldRevert(bool v) external {
        transferShouldRevert = v;
    }

    function setTransferFeeBps(uint16 v) external {
        transferFeeBps = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (transferShouldRevert) revert("MockUSDC: transferShouldRevert");
        if (transferFeeBps != 0 && from != address(0) && to != address(0)) {
            uint256 fee = (value * transferFeeBps) / 10_000;
            super._update(from, to, value - fee);
            super._update(from, address(0xdead), fee);
            return;
        }
        super._update(from, to, value);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (transferShouldReturnFalse) {
            // Pull the funds normally so balances are observable, but lie about the result.
            super.transfer(to, value);
            return false;
        }
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (transferShouldReturnFalse) {
            super.transferFrom(from, to, value);
            return false;
        }
        return super.transferFrom(from, to, value);
    }
}
