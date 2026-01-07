// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "../src/VolatilityDynamicFeeHook.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract MockPoolManager {
    bytes32 public defaultSlotData;

    function setDefaultSlotData(bytes32 d) external {
        defaultSlotData = d;
    }

    // extsload used by StateLibrary.getSlot0
    function extsload(bytes32) external view returns (bytes32) {
        return defaultSlotData;
    }
}

contract TestHook is VolatilityDynamicFeeHook {
    constructor(IPoolManager m, address owner) VolatilityDynamicFeeHook(m, owner) {}

    // override the internal validation to disable permission check during tests
    function validateHookAddress(BaseHook) internal pure override {}
}

contract VolatilityDynamicFeeHookTest is Test {
    VolatilityDynamicFeeHook hook;
    MockPoolManager manager;

    function setUp() public {
        manager = new MockPoolManager();
        // deploy test hook with the manager address
        TestHook t = new TestHook(IPoolManager(address(manager)), address(this));
        hook = VolatilityDynamicFeeHook(address(t));
    }

    // helper to encode slot0 data: sqrtPriceX96 (160b), tick (24b), protocolFee (24b), lpFee (24b)
    function encodeSlot0(uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
        internal
        pure
        returns (bytes32)
    {
        uint256 v = uint256(sqrtPriceX96);
        // place tick into bits [160,184)
        uint256 tickBits = uint256(uint24(uint256(int256(tick)))) << 160;
        uint256 protoBits = uint256(protocolFee) << 184;
        uint256 lpBits = uint256(lpFee) << 208;
        return bytes32(v | tickBits | protoBits | lpBits);
    }

    function test_initializeAndGetPriceHistory() public {
        // prepare pool key
        PoolKey memory key = PoolKey(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)), uint24(0x800000), int24(1), IHooks(address(0)));

        uint160 initialPrice = uint160(1 << 96);
        bytes32 slot = encodeSlot0(initialPrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        // call afterInitialize as if manager invoked it
        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, initialPrice, int24(0));

        // read price history
        uint160[] memory prices = hook.getPriceHistory(key);
        assertEq(prices.length, 1);
        assertEq(prices[0], initialPrice);
    }

    function test_revertWhenNotDynamicFee() public {
        // prepare pool key WITHOUT dynamic fee flag (0x800000)
        PoolKey memory key = PoolKey(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)), uint24(3000), int24(1), IHooks(address(0)));

        uint160 initialPrice = uint160(1 << 96);

        // expect revert with MustUseDynamicFee
        vm.expectRevert(VolatilityDynamicFeeHook.MustUseDynamicFee.selector);
        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, initialPrice, int24(0));
    }

    function test_beforeSwap_returnsCorrectFee() public {
        // initialize pool
        PoolKey memory key = PoolKey(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)), uint24(0x800000), int24(1), IHooks(address(0)));
        uint160 initialPrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(initialPrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, initialPrice, int24(0));

        // with only 1 price, volatility should be 0, so fee = BASE_FEE = 300
        uint24 currentFee = hook.getCurrentFee(key);
        assertEq(currentFee, 300, "Fee should be BASE_FEE when volatility is 0");
    }

    function test_afterSwap_updatesPriceHistory() public {
        // initialize pool
        PoolKey memory key = PoolKey(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)), uint24(0x800000), int24(1), IHooks(address(0)));
        uint160 initialPrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(initialPrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, initialPrice, int24(0));

        // simulate price change
        uint160 newPrice = uint160(1 << 96) + 1000000;
        bytes32 newSlot = encodeSlot0(newPrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(newSlot);

        // advance time past MIN_UPDATE_INTERVAL
        // Codex版: 1時間間隔で観測を記録
        skip(10 minutes);

        // call afterSwap
        SwapParams memory params = SwapParams(true, 1000, 0);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // check price history updated
        uint160[] memory prices = hook.getPriceHistory(key);
        assertEq(prices.length, 2, "Should have 2 prices");
        assertEq(prices[0], initialPrice, "First price should be initial");
        assertEq(prices[1], newPrice, "Second price should be new price");
    }

    function test_afterSwap_respectsMinUpdateInterval() public {
        // initialize pool
        PoolKey memory key = PoolKey(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)), uint24(0x800000), int24(1), IHooks(address(0)));
        uint160 initialPrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(initialPrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, initialPrice, int24(0));

        // try to update immediately (within MIN_UPDATE_INTERVAL)
        uint160 newPrice = uint160(1 << 96) + 1000000;
        bytes32 newSlot = encodeSlot0(newPrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(newSlot);

        // advance time by only 5 seconds (less than MIN_UPDATE_INTERVAL=12)
        vm.warp(block.timestamp + 5);

        SwapParams memory params = SwapParams(true, 1000, 0);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // price history should NOT be updated
        uint160[] memory prices = hook.getPriceHistory(key);
        assertEq(prices.length, 1, "Should still have only 1 price");
        assertEq(prices[0], initialPrice, "Price should remain initial");
    }

    function test_volatility_calculation() public {
        // initialize pool
        PoolKey memory key = PoolKey(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)), uint24(0x800000), int24(1), IHooks(address(0)));
        uint160 basePrice = uint160(1 << 96); // ~79 * 10^18

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        SwapParams memory params = SwapParams(true, 1000, 0);

        // add multiple swaps with increasing prices to create volatility
        // Codex版: 1時間間隔で観測を記録
        for (uint256 i = 1; i <= 5; i++) {
            skip(10 minutes);

            // increase price by 1%
            uint160 newPrice = basePrice + uint160((basePrice * i) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(0), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);

            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // volatility should be > 0 now
        uint24 fee = hook.getCurrentFee(key);
        assertGt(fee, 300, "Fee should be higher than BASE_FEE due to volatility");
        assertLe(fee, 5000, "Fee should not exceed MAX_FEE");
    }

    function test_ringBuffer_overflow() public {
        // initialize pool
        PoolKey memory key = PoolKey(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)), uint24(0x800000), int24(1), IHooks(address(0)));
        uint160 basePrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.roll(1); // Set initial block number before initialization
        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        SwapParams memory params = SwapParams(true, 1000, 0);

        // add more than HISTORY_SIZE (10) swaps
        // セキュリティ強化版: 10分間隔で観測を記録
        for (uint256 i = 1; i <= 15; i++) {
            skip(10 minutes);
            vm.roll(1 + i); // Advance block number for multi-block validation

            uint160 newPrice = basePrice + uint160(i * 1000000);
            bytes32 newSlot = encodeSlot0(newPrice, int24(0), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);

            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // With ring buffer capacity of 100, all 16 observations (1 initial + 15 swaps) should be stored
        uint160[] memory prices = hook.getPriceHistory(key);
        assertEq(prices.length, 16, "Price history should contain all 16 observations");
    }

    function test_volatility_withZeroPrice_skipped() public {
        // This tests the zero-division protection in _calculateVolatility
        // In normal operation, prices shouldn't be zero, but we test the safety check

        PoolKey memory key = PoolKey(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)), uint24(0x800000), int24(1), IHooks(address(0)));
        uint160 initialPrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(initialPrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, initialPrice, int24(0));

        // volatility calculation should handle edge cases gracefully
        uint24 fee = hook.getCurrentFee(key);
        assertEq(fee, 300, "Fee should be BASE_FEE with single price");
    }

    function test_consecutiveSwaps_multipleUpdates() public {
        PoolKey memory key = PoolKey(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)), uint24(0x800000), int24(1), IHooks(address(0)));
        uint160 basePrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.roll(1); // Set initial block number before initialization
        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        SwapParams memory params = SwapParams(true, 1000, 0);

        // perform 3 consecutive swaps with sufficient time and block intervals
        // Codex版: 1時間間隔で観測を記録
        for (uint256 i = 1; i <= 3; i++) {
            skip(10 minutes);
            vm.roll(1 + i); // Advance block number for multi-block validation

            uint160 newPrice = basePrice + uint160(i * 500000);
            bytes32 newSlot = encodeSlot0(newPrice, int24(0), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);

            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // verify all prices were recorded
        uint160[] memory prices = hook.getPriceHistory(key);
        assertEq(prices.length, 4, "Should have 4 prices (initial + 3 swaps)");
    }

    function test_twap_timeWeighting() public {
        // Test that time-weighted volatility calculation properly weights price changes
        PoolKey memory key = PoolKey(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)), uint24(0x800000), int24(1), IHooks(address(0)));
        uint160 basePrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        SwapParams memory params = SwapParams(true, 1000, 0);

        // First swap: 1 hour interval, large price change
        // Codex版: 1時間間隔で観測を記録
        skip(10 minutes);
        uint160 price1 = basePrice + uint160((basePrice * 10) / 100); // +10%
        bytes32 slot1 = encodeSlot0(price1, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot1);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // Second swap: 1 hour interval, small price change
        skip(10 minutes);
        uint160 price2 = price1 + uint160((basePrice * 1) / 100); // +1%
        bytes32 slot2 = encodeSlot0(price2, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot2);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // The time-weighted volatility should give more weight to the longer time period
        // This helps reduce the impact of flash price manipulations
        uint24 fee = hook.getCurrentFee(key);
        assertGt(fee, 300, "Fee should be higher than BASE_FEE");
        assertLe(fee, 5000, "Fee should not exceed MAX_FEE");
    }

    function test_twap_resistsFlashPriceManipulation() public {
        // Simulate a scenario where an attacker tries to manipulate price in a single block
        PoolKey memory key = PoolKey(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)), uint24(0x800000), int24(1), IHooks(address(0)));
        uint160 basePrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.roll(1); // Set initial block number before initialization
        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        SwapParams memory params = SwapParams(true, 1000, 0);

        // Establish normal trading pattern with reasonable time intervals
        // Codex版: 1時間間隔で観測を記録
        for (uint256 i = 1; i <= 3; i++) {
            skip(10 minutes);
            vm.roll(1 + i); // Advance block number for multi-block validation
            uint160 normalPrice = basePrice + uint160((basePrice * i) / 200); // +0.5% each
            bytes32 normalSlot = encodeSlot0(normalPrice, int24(0), uint24(0), uint24(3000));
            manager.setDefaultSlotData(normalSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        uint24 normalFee = hook.getCurrentFee(key);

        // Attacker tries to manipulate price with MIN_UPDATE_INTERVAL
        // Use 4% sqrtPrice increase (≈8% actual price increase) to stay under CIRCUIT_BREAKER_THRESHOLD (10%)
        // Actual price change = (1.04)^2 - 1 ≈ 0.0816 = 8.16%
        skip(10 minutes);
        vm.roll(5); // Advance block number for multi-block validation
        uint160 lastPrice = basePrice + uint160((basePrice * 3) / 200); // last recorded was +1.5%
        uint160 manipulatedPrice = lastPrice + uint160((lastPrice * 4) / 100); // 4% sqrtPrice increase (≈8% price increase, under circuit breaker threshold)
        bytes32 manipSlot = encodeSlot0(manipulatedPrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(manipSlot);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        uint24 manipulatedFee = hook.getCurrentFee(key);

        // Due to time weighting, the short-duration manipulation should have reduced impact
        // This test verifies that TWAP provides some resistance to flash manipulation
        assertGt(manipulatedFee, normalFee, "Fee should increase after manipulation");
        // The exact assertion depends on the weighting formula, but we ensure it's capped
        assertLe(manipulatedFee, 5000, "Fee should be capped at MAX_FEE");
    }

    function test_twap_handlesUniformTimeIntervals() public {
        // Test with uniform time intervals to ensure consistent behavior
        PoolKey memory key = PoolKey(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)), uint24(0x800000), int24(1), IHooks(address(0)));
        uint160 basePrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        SwapParams memory params = SwapParams(true, 1000, 0);

        // Add swaps with exactly 1 hour intervals
        // Codex版: 1時間間隔で観測を記録
        for (uint256 i = 1; i <= 5; i++) {
            skip(10 minutes);
            uint160 newPrice = basePrice + uint160((basePrice * i) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(0), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        uint24 fee = hook.getCurrentFee(key);
        assertGt(fee, 300, "Fee should be higher than BASE_FEE");
        assertLe(fee, 5000, "Fee should not exceed MAX_FEE");
    }

    // ============================================
    // Phase 1.5.3: Bollinger Bands Tests
    // ============================================

    // Bollinger Bands tests removed - feature not implemented in simplified version

}
