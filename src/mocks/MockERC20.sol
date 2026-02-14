// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockERC20
/// @notice Mock ERC20 token for LOCAL TESTING ONLY (owner-restricted mint)
/// @dev WARNING: Do NOT use on public testnets without proper access control.
///      The mint function is restricted to owner, but deploy with extreme caution.
///      For production, use real token contracts with proper governance.
contract MockERC20 is ERC20, Ownable {
    uint8 private immutable _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint tokens to an address (owner only)
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
