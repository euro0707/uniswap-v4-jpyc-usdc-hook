// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title MockERC20Test
/// @notice Unit tests for MockERC20 access control and decimals
contract MockERC20Test is Test {
    MockERC20 token;
    address owner;
    address user;

    function setUp() public {
        owner = address(this);
        user = address(0xBEEF);
        token = new MockERC20("Test Token", "TT", 6);
    }

    /// @notice Only owner can mint
    function test_onlyOwnerCanMint() public {
        vm.prank(user);
        vm.expectRevert();
        token.mint(user, 1000);
    }

    /// @notice Owner can mint successfully
    function test_ownerCanMint() public {
        token.mint(user, 1000);
        assertEq(token.balanceOf(user), 1000, "User should have minted tokens");
    }

    /// @notice Decimals returns the configured value
    function test_decimalsCorrect() public view {
        assertEq(token.decimals(), 6, "Decimals should be 6");
    }

    /// @notice Different decimals configuration
    function test_decimals18() public {
        MockERC20 token18 = new MockERC20("JPYC Mock", "mJPYC", 18);
        assertEq(token18.decimals(), 18, "Decimals should be 18");
    }
}
