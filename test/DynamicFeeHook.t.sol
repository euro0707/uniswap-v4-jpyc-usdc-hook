// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";

contract DynamicFeeHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DynamicFeeHook hook;
    PoolKey poolKey;
    PoolId poolId;

    int24 constant TICK_SPACING = 10;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy hook at flag-matching address
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG      |
            Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags);
        deployCodeTo(
            "DynamicFeeHook.sol",
            abi.encode(
                manager,
                Currency.unwrap(currency0),
                Currency.unwrap(currency1)
            ),
            hookAddr
        );
        hook = DynamicFeeHook(hookAddr);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Add initial liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -TICK_SPACING * 100,
                tickUpper: TICK_SPACING * 100,
                liquidityDelta: 10_000e18,
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    /// afterInitialize records the tick
    function test_AfterInitialize_TickRecorded() public view {
        (, int24 currentTick, , ) = manager.getSlot0(poolId);
        assertEq(hook.lastTick(poolId), currentTick);
    }

    /// isInitialized flag is set
    function test_AfterInitialize_IsInitialized() public view {
        assertTrue(hook.isInitialized(poolId));
    }

    /// previewFee returns value within FEE_CALM..FEE_HIGH
    function test_PreviewFee_InRange() public view {
        uint24 fee = hook.previewFee(poolKey);
        assertGe(fee, hook.FEE_CALM());
        assertLe(fee, hook.FEE_HIGH());
    }

    /// Direct call to beforeSwap reverts (onlyPoolManager)
    function test_Security_DirectCallReverts() public {
        vm.expectRevert();
        hook.beforeSwap(
            address(this),
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e6,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ZERO_BYTES
        );
    }

    /// Swap updates the tick
    function test_AfterSwap_TickUpdated() public {
        int24 tickBefore = hook.lastTick(poolId);
        // Use a large swap amount to guarantee tick movement
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e24,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );
        int24 tickAfter = hook.lastTick(poolId);
        assertTrue(tickAfter != tickBefore, "tick should move after large swap");
    }

    /// Fuzz: fee always within bounds regardless of swap size
    function testFuzz_FeeAlwaysInBounds(int24 swapSeed) public {
        // Bound to a meaningful non-zero swap range
        int256 swapAmount = bound(int256(swapSeed), -1e22, -1e15);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: swapAmount,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );
        uint24 fee = hook.previewFee(poolKey);
        assertGe(fee, hook.FEE_CALM());
        assertLe(fee, hook.FEE_HIGH());
    }

    /// Multi-block decay: blockTickDelta decays and also includes first swap delta in new block
    function test_MultiBlockDecay_HalvesNotResets() public {
        // Block N: perform a large swap to accumulate blockTickDelta
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e24,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        uint24 deltaAfterBlockN = hook.blockTickDelta(poolId);
        assertTrue(deltaAfterBlockN > 0, "blockTickDelta should be non-zero after large swap");

        // Advance to block N+1
        vm.roll(block.number + 1);
        int24 tickBeforeBlockN1 = hook.lastTick(poolId);

        // Block N+1: perform a small swap to trigger _afterSwap decay
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: 1e15,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        int24 tickAfterBlockN1 = hook.lastTick(poolId);
        uint24 deltaAfterBlockN1 = hook.blockTickDelta(poolId);
        uint24 deltaFromFirstSwapN1 = _absTickDiff(tickAfterBlockN1, tickBeforeBlockN1);
        uint24 decayed = deltaAfterBlockN / 2;
        uint24 expected;
        unchecked {
            uint24 sum = decayed + deltaFromFirstSwapN1;
            expected = sum < decayed ? type(uint24).max : sum;
        }

        // New-block first swap should both decay prior signal and include current tick movement.
        assertEq(deltaAfterBlockN1, expected, "blockTickDelta should decay then accumulate first swap delta");
    }

    function _absTickDiff(int24 a, int24 b) internal pure returns (uint24) {
        int256 diff = int256(a) - int256(b);
        if (diff < 0) diff = -diff;
        if (diff > int256(uint256(type(uint24).max))) return type(uint24).max;
        // casting is safe because values above uint24.max are clamped above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(uint256(diff));
    }

    /// Invalid token pair should revert on initialize
    function test_InvalidPair_Reverts() public {
        // Deploy a new hook with different allowed tokens
        uint160 flags2 = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG      |
            Hooks.AFTER_SWAP_FLAG
        );
        // Use a different address offset to avoid collision
        address hookAddr2 = address(uint160(flags2) | (1 << 14));
        deployCodeTo(
            "DynamicFeeHook.sol",
            abi.encode(
                manager,
                address(0xdead),
                address(0xbeef)
            ),
            hookAddr2
        );

        PoolKey memory badKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr2)
        });

        vm.expectRevert();
        manager.initialize(badKey, SQRT_PRICE_1_1);
    }
}
