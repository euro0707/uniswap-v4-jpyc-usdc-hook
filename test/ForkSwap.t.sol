// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";

/// @notice Fork test: verifies the deployed DynamicFeeHook on Polygon Mainnet
/// @dev Run with: forge test --match-contract ForkSwapTest --fork-url $POLYGON_RPC_URL -vvv
contract ForkSwapTest is Test, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ── Polygon Mainnet addresses ──────────────────────────────────────────
    address constant POOL_MANAGER = 0x67366782805870060151383F4BbFF9daB53e5cD6;
    address constant HOOK_ADDR    = 0x1D4D185b1D0f86561f1D24DE10E7473e2772d0C0;
    address constant USDC         = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; // 6 decimals
    address constant JPYC         = 0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29; // 18 decimals
    int24  constant TICK_SPACING  = 10;

    IPoolManager poolManager;
    DynamicFeeHook hook;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"));

        poolManager = IPoolManager(POOL_MANAGER);
        hook        = DynamicFeeHook(HOOK_ADDR);

        // USDC address < JPYC address → USDC is currency0
        poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(JPYC),
            fee:        LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks:      IHooks(HOOK_ADDR)
        });
        poolId = poolKey.toId();
    }

    // ── Test 1: hook state is readable ────────────────────────────────────

    function test_Fork_HookIsInitialized() public view {
        bool initialized = hook.isInitialized(poolId);
        assertTrue(initialized, "hook should be initialized after pool creation");

        int24  tick      = hook.lastTick(poolId);
        uint24 blockDelta = hook.blockTickDelta(poolId);
        uint8  level     = hook.volatilityLevel(poolKey);
        uint24 fee       = hook.previewFee(poolKey);

        console2.log("=== Hook State ===");
        console2.log("isInitialized :", initialized);
        console2.log("lastTick      :", tick);
        console2.log("blockTickDelta:", blockDelta);
        console2.log("volatilityLevel (0-3):", level);
        console2.log("previewFee (pips)     :", fee);
        console2.log("  500=0.05%  1000=0.10%  3000=0.30%  10000=1.00%");
    }

    // ── Test 2: swap triggers hook events ─────────────────────────────────

    function test_Fork_SwapEmitsHookEvents() public {
        // Deal 10 USDC to this contract (forge deals ERC20 storage directly)
        deal(USDC, address(this), 10e6);

        int24  tickBefore = hook.lastTick(poolId);
        uint24 feeBefore  = hook.previewFee(poolKey);
        console2.log("=== Before Swap ===");
        console2.log("lastTick   :", tickBefore);
        console2.log("previewFee :", feeBefore);

        // FeeApplied event should be emitted by beforeSwap
        vm.expectEmit(true, false, false, false, HOOK_ADDR);
        emit DynamicFeeHook.FeeApplied(poolId, 0, 0);

        // Sell 1 USDC → buy JPYC
        poolManager.unlock(abi.encode(
            poolKey,
            SwapParams({
                zeroForOne:        true,
                amountSpecified:   -1e6,                       // exact-in 1 USDC
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        ));

        int24  tickAfter = hook.lastTick(poolId);
        uint24 feeAfter  = hook.previewFee(poolKey);
        console2.log("=== After Swap ===");
        console2.log("lastTick   :", tickAfter);
        console2.log("previewFee :", feeAfter);

        // blockTickDelta should be updated
        uint24 delta = hook.blockTickDelta(poolId);
        console2.log("blockTickDelta:", delta);
    }

    // ── IUnlockCallback ───────────────────────────────────────────────────

    /// @notice Called by PoolManager during unlock; performs the actual swap and settles
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "caller not poolManager");

        (PoolKey memory key, SwapParams memory params) =
            abi.decode(data, (PoolKey, SwapParams));

        BalanceDelta delta = poolManager.swap(key, params, bytes(""));

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        // Settle negative deltas (tokens we owe to the pool)
        if (d0 < 0) {
            uint256 amount = uint256(uint128(-d0));
            poolManager.sync(key.currency0);
            IERC20(USDC).transfer(address(poolManager), amount);
            poolManager.settle();
        }
        if (d1 < 0) {
            uint256 amount = uint256(uint128(-d1));
            poolManager.sync(key.currency1);
            IERC20(JPYC).transfer(address(poolManager), amount);
            poolManager.settle();
        }

        // Collect positive deltas (tokens the pool owes us)
        if (d0 > 0) poolManager.take(key.currency0, address(this), uint256(uint128(d0)));
        if (d1 > 0) poolManager.take(key.currency1, address(this), uint256(uint128(d1)));

        return bytes("");
    }
}
