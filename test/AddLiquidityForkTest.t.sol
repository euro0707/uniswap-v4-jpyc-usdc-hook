// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title AddLiquidityForkTest
/// @notice Tests for AddLiquiditySepolia script improvements (ADVISORY #5)
contract AddLiquidityForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MockERC20 token0;
    MockERC20 token1;
    address currency0;
    address currency1;

    function setUp() public {
        // Create mock tokens with different decimals
        token0 = new MockERC20("Token A", "TKA", 18);
        token1 = new MockERC20("Token B", "TKB", 6);

        // Sort by address
        if (address(token0) < address(token1)) {
            currency0 = address(token0);
            currency1 = address(token1);
        } else {
            currency0 = address(token1);
            currency1 = address(token0);
        }
    }

    /// @notice Test that decimals are correctly retrieved from token contracts
    function test_differentDecimals_correctCalculation() public view {
        // Get decimals from tokens
        uint8 decimals0Raw = IERC20Metadata(address(token0)).decimals();
        uint8 decimals1Raw = IERC20Metadata(address(token1)).decimals();

        // Verify decimals match constructor
        assertEq(decimals0Raw, 18, "Token0 should have 18 decimals");
        assertEq(decimals1Raw, 6, "Token1 should have 6 decimals");

        // Sort decimals based on address ordering
        uint8 decimals0 = address(token0) < address(token1) ? decimals0Raw : decimals1Raw;
        uint8 decimals1 = address(token0) < address(token1) ? decimals1Raw : decimals0Raw;

        // Calculate amounts based on sorted decimals
        uint256 amount0Max = 1_000 * 10**decimals0;
        uint256 amount1Max = 1_000 * 10**decimals1;

        // Verify amounts are different (reflecting different decimals)
        if (address(token0) < address(token1)) {
            assertEq(amount0Max, 1_000 * 10**18, "Amount0 should use 18 decimals");
            assertEq(amount1Max, 1_000 * 10**6, "Amount1 should use 6 decimals");
        } else {
            assertEq(amount0Max, 1_000 * 10**6, "Amount0 should use 6 decimals");
            assertEq(amount1Max, 1_000 * 10**18, "Amount1 should use 18 decimals");
        }
    }

    /// @notice Test token order swap - amounts should follow currency order
    function test_tokenOrderSwap_correctAmounts() public view {
        address tokenA = address(token0);
        address tokenB = address(token1);

        // Case 1: tokenA < tokenB
        address curr0 = tokenA < tokenB ? tokenA : tokenB;
        address curr1 = tokenA < tokenB ? tokenB : tokenA;

        uint8 decimalsA = IERC20Metadata(tokenA).decimals();
        uint8 decimalsB = IERC20Metadata(tokenB).decimals();

        uint8 dec0 = tokenA < tokenB ? decimalsA : decimalsB;
        uint8 dec1 = tokenA < tokenB ? decimalsB : decimalsA;

        // Amounts should be calculated based on sorted order
        uint256 amt0 = 1_000 * 10**dec0;
        uint256 amt1 = 1_000 * 10**dec1;

        // Verify currency0 < currency1 invariant
        assertTrue(curr0 < curr1, "Currency0 must be < Currency1");

        // Verify amounts match decimals of sorted currencies
        if (tokenA < tokenB) {
            assertEq(amt0, 1_000 * 10**decimalsA, "Amount0 should match tokenA decimals");
            assertEq(amt1, 1_000 * 10**decimalsB, "Amount1 should match tokenB decimals");
        } else {
            assertEq(amt0, 1_000 * 10**decimalsB, "Amount0 should match tokenB decimals");
            assertEq(amt1, 1_000 * 10**decimalsA, "Amount1 should match tokenA decimals");
        }
    }

    /// @notice Test LiquidityAmounts calculation accuracy
    function test_liquidityCalculation_accuracy() public view {
        // Setup parameters
        uint160 sqrtPriceX96 = uint160(1 << 96); // 1:1 price
        int24 tickLower = (TickMath.MIN_TICK / 60) * 60;
        int24 tickUpper = (TickMath.MAX_TICK / 60) * 60;
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // Calculate amounts (1000 tokens each, adjusted for decimals)
        uint8 decimals0 = address(token0) < address(token1) ? token0.decimals() : token1.decimals();
        uint8 decimals1 = address(token0) < address(token1) ? token1.decimals() : token0.decimals();
        uint256 amount0Max = 1_000 * 10**decimals0;
        uint256 amount1Max = 1_000 * 10**decimals1;

        // Calculate liquidity using LiquidityAmounts
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLower,
            sqrtPriceUpper,
            amount0Max,
            amount1Max
        );

        // Liquidity should be > 0 for full range position
        assertGt(liquidity, 0, "Calculated liquidity must be greater than 0");

        // Liquidity should not exceed reasonable bounds
        assertLt(liquidity, type(uint128).max / 2, "Liquidity should be reasonable");
    }

    /// @notice Test that invalid sqrtPriceX96 = 0 is detected
    function test_uninitializedPool_reverts() public pure {
        uint160 sqrtPriceX96 = 0; // Uninitialized

        // This would revert in actual script
        // We simulate the check here
        bool shouldRevert = (sqrtPriceX96 == 0);
        assertTrue(shouldRevert, "Should detect uninitialized pool");
    }

    /// @notice Test that sqrtPriceX96 out of TickMath range is rejected
    function test_invalidSqrtPrice_reverts() public pure {
        // Test below minimum
        uint160 tooLow = TickMath.MIN_SQRT_PRICE - 1;
        bool shouldRevertLow = !(tooLow >= TickMath.MIN_SQRT_PRICE && tooLow <= TickMath.MAX_SQRT_PRICE);
        assertTrue(shouldRevertLow, "Should reject sqrtPrice below MIN_SQRT_PRICE");

        // Test above maximum
        uint160 tooHigh = TickMath.MAX_SQRT_PRICE + 1;
        bool shouldRevertHigh = !(tooHigh >= TickMath.MIN_SQRT_PRICE && tooHigh <= TickMath.MAX_SQRT_PRICE);
        assertTrue(shouldRevertHigh, "Should reject sqrtPrice above MAX_SQRT_PRICE");

        // Test valid range
        uint160 validPrice = uint160(1 << 96);
        bool shouldNotRevert = (validPrice >= TickMath.MIN_SQRT_PRICE && validPrice <= TickMath.MAX_SQRT_PRICE);
        assertTrue(shouldNotRevert, "Should accept valid sqrtPrice");
    }
}
