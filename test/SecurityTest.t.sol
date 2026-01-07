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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract MockPoolManager {
    bytes32 public defaultSlotData;

    function setDefaultSlotData(bytes32 d) external {
        defaultSlotData = d;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return defaultSlotData;
    }

    function getSlot0(PoolId) external view returns (uint160, int24, uint24, uint24) {
        bytes32 slot = defaultSlotData;
        uint160 sqrtPriceX96 = uint160(uint256(slot));
        int24 tick = int24(int256(uint256(slot) >> 160));
        uint24 protocolFee = uint24(uint256(slot) >> 184);
        uint24 lpFee = uint24(uint256(slot) >> 208);
        return (sqrtPriceX96, tick, protocolFee, lpFee);
    }
}

contract TestHook is VolatilityDynamicFeeHook {
    constructor(IPoolManager m, address owner) VolatilityDynamicFeeHook(m, owner) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @title SecurityTest
/// @notice Phase 2.5のセキュリティ機能の包括的なテスト
contract SecurityTest is Test {
    VolatilityDynamicFeeHook hook;
    MockPoolManager manager;
    address owner;
    address attacker;

    function setUp() public {
        manager = new MockPoolManager();
        owner = address(this);
        attacker = address(0xBAD);

        TestHook t = new TestHook(IPoolManager(address(manager)), owner);
        hook = VolatilityDynamicFeeHook(address(t));
    }

    function encodeSlot0(uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
        internal
        pure
        returns (bytes32)
    {
        return bytes32(
            (uint256(lpFee) << 208) | (uint256(protocolFee) << 184) | (uint256(uint24(tick)) << 160)
                | uint256(sqrtPriceX96)
        );
    }

    // ============================================
    // Phase 2.5.1: 価格操作保護テスト
    // ============================================

    /// @notice フラッシュローン攻撃（単一ブロック内の価格操作）を検出できることを確認
    function test_security_flashLoanProtection() public {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0x1)),
            Currency.wrap(address(0x2)),
            uint24(0x800000),
            int24(1),
            IHooks(address(0))
        );
        uint160 basePrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        SwapParams memory params = SwapParams(true, 1000, 0);

        // 同じブロック内で複数の観測を追加しようとする（フラッシュローン攻撃のシミュレーション）
        // vm.rollを使わずに時間だけ進める
        for (uint256 i = 1; i <= 5; i++) {
            skip(10 minutes);
            // ブロック番号は進めない（すべて同じブロック）
            uint160 newPrice = basePrice + uint160((basePrice * i * 10) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 10)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // validateMultiBlockがfalseを返すことを確認
        // PriceManipulationAttemptイベントが発行されることを期待（正確な値は計算されるため、イベントの存在だけチェック）
        skip(10 minutes);
        uint160 attackPrice = basePrice + uint160((basePrice * 60) / 100);
        bytes32 attackSlot = encodeSlot0(attackPrice, int24(60), uint24(0), uint24(3000));
        manager.setDefaultSlotData(attackSlot);

        vm.recordLogs();
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // PriceManipulationAttemptイベントが発行されたことを確認
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PriceManipulationAttempt(bytes32,uint256,uint256)")) {
                foundEvent = true;
                break;
            }
        }
        assertTrue(foundEvent, "PriceManipulationAttempt event should be emitted for flash loan attack");
    }

    /// @notice 正常な複数ブロックにわたる取引は許可されることを確認
    function test_security_normalMultiBlockTrade() public {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0x1)),
            Currency.wrap(address(0x2)),
            uint24(0x800000),
            int24(1),
            IHooks(address(0))
        );
        uint160 basePrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        SwapParams memory params = SwapParams(true, 1000, 0);

        // 複数ブロックにわたる正常な取引
        for (uint256 i = 1; i <= 10; i++) {
            skip(10 minutes);
            vm.roll(i + 1); // ブロック番号を進める
            uint160 newPrice = basePrice + uint160((basePrice * i * 3) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // エラーが発生せずに完了することを確認
        assertTrue(true, "Multi-block trades should succeed");
    }

    /// @notice 異常な価格変動（50%以上）は拒否されることを確認
    function test_security_extremePriceChangeRejected() public {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0x1)),
            Currency.wrap(address(0x2)),
            uint24(0x800000),
            int24(1),
            IHooks(address(0))
        );
        uint160 basePrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        SwapParams memory params = SwapParams(true, 1000, 0);

        // 正常な観測を構築
        for (uint256 i = 1; i <= 10; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            uint160 newPrice = basePrice + uint160((basePrice * i * 2) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // 異常な価格変動（70%）を試みる
        skip(10 minutes);
        vm.roll(12);
        uint160 currentPrice = basePrice + uint160((basePrice * 20) / 100);
        uint160 extremePrice = currentPrice + uint160((currentPrice * 70) / 100);
        bytes32 extremeSlot = encodeSlot0(extremePrice, int24(200), uint24(0), uint24(3000));
        manager.setDefaultSlotData(extremeSlot);

        // PriceManipulationDetectedエラーを期待
        vm.expectRevert(VolatilityDynamicFeeHook.PriceManipulationDetected.selector);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
    }

    // ============================================
    // Phase 2.5.2: サーキットブレーカーテスト
    // ============================================

    /// @notice サーキットブレーカーが10%変動で発動することを確認
    function test_security_circuitBreakerActivation() public {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0x1)),
            Currency.wrap(address(0x2)),
            uint24(0x800000),
            int24(1),
            IHooks(address(0))
        );
        uint160 basePrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        SwapParams memory params = SwapParams(true, 1000, 0);

        // 正常な観測を構築
        for (uint256 i = 1; i <= 10; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            uint160 newPrice = basePrice + uint160((basePrice * i) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // 15%の価格変動を引き起こす（サーキットブレーカー閾値の10%を超える）
        skip(10 minutes);
        vm.roll(12);
        uint160 currentPrice = basePrice + uint160((basePrice * 10) / 100);
        uint160 volatilePrice = currentPrice + uint160((currentPrice * 15) / 100);
        bytes32 volatileSlot = encodeSlot0(volatilePrice, int24(100), uint24(0), uint24(3000));
        manager.setDefaultSlotData(volatileSlot);

        // CircuitBreakerActivatedイベントを期待
        vm.expectEmit(true, false, false, false);
        emit VolatilityDynamicFeeHook.CircuitBreakerActivated(key.toId(), 0, volatilePrice);

        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // サーキットブレーカーが発動していることを確認
        assertTrue(hook.isCircuitBreakerTriggered(key.toId()), "Circuit breaker should be triggered");

        // 次のスワップは拒否される
        skip(10 minutes);
        vm.roll(13);
        bytes32 nextSlot = encodeSlot0(volatilePrice, int24(100), uint24(0), uint24(3000));
        manager.setDefaultSlotData(nextSlot);

        vm.expectRevert(VolatilityDynamicFeeHook.CircuitBreakerTriggered.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, params, bytes(""));
    }

    /// @notice オーナーのみがサーキットブレーカーをリセットできることを確認
    function test_security_circuitBreakerResetOnlyOwner() public {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0x1)),
            Currency.wrap(address(0x2)),
            uint24(0x800000),
            int24(1),
            IHooks(address(0))
        );

        // 攻撃者がリセットを試みる
        vm.prank(attacker);
        vm.expectRevert();
        hook.resetCircuitBreaker(key.toId());

        // オーナーはリセット可能
        vm.prank(owner);
        hook.resetCircuitBreaker(key.toId());

        // リセットが成功したことを確認
        assertFalse(hook.isCircuitBreakerTriggered(key.toId()), "Circuit breaker should be reset");
    }

    // ============================================
    // Phase 2.5.3: アクセス制御とPausableテスト
    // ============================================

    /// @notice オーナーのみがpauseできることを確認
    function test_security_pauseOnlyOwner() public {
        // 攻撃者がpauseを試みる
        vm.prank(attacker);
        vm.expectRevert();
        hook.pause();

        // オーナーはpause可能
        vm.prank(owner);
        hook.pause();

        // pausedであることを確認
        assertTrue(hook.paused(), "Contract should be paused");
    }

    /// @notice pause中はスワップが拒否されることを確認
    function test_security_pauseBlocksSwaps() public {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0x1)),
            Currency.wrap(address(0x2)),
            uint24(0x800000),
            int24(1),
            IHooks(address(0))
        );
        uint160 basePrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        // コントラクトをpause
        vm.prank(owner);
        hook.pause();

        // スワップは拒否される
        SwapParams memory params = SwapParams(true, 1000, 0);
        vm.expectRevert();
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, params, bytes(""));
    }

    /// @notice unpause後はスワップが再開されることを確認
    function test_security_unpauseResumesSwaps() public {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0x1)),
            Currency.wrap(address(0x2)),
            uint24(0x800000),
            int24(1),
            IHooks(address(0))
        );
        uint160 basePrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        // pauseしてからunpause
        vm.prank(owner);
        hook.pause();

        vm.prank(owner);
        hook.unpause();

        // スワップが再開されることを確認
        SwapParams memory params = SwapParams(true, 1000, 0);
        vm.prank(address(manager));
        (bytes4 selector,,) = hook.beforeSwap(address(this), key, params, bytes(""));

        assertEq(selector, BaseHook.beforeSwap.selector, "Swap should succeed after unpause");
    }

    /// @notice オーナーのみがunpauseできることを確認
    function test_security_unpauseOnlyOwner() public {
        // まずpause
        vm.prank(owner);
        hook.pause();

        // 攻撃者がunpauseを試みる
        vm.prank(attacker);
        vm.expectRevert();
        hook.unpause();

        // オーナーはunpause可能
        vm.prank(owner);
        hook.unpause();

        assertFalse(hook.paused(), "Contract should be unpaused");
    }

    // ============================================
    // 統合セキュリティテスト
    // ============================================

    /// @notice 複数のセキュリティ機能が同時に機能することを確認
    function test_security_multiLayerProtection() public {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0x1)),
            Currency.wrap(address(0x2)),
            uint24(0x800000),
            int24(1),
            IHooks(address(0))
        );
        uint160 basePrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        SwapParams memory params = SwapParams(true, 1000, 0);

        // 1. 正常な観測を構築（複数ブロック検証をパス）
        for (uint256 i = 1; i <= 10; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            uint160 newPrice = basePrice + uint160((basePrice * i * 2) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // 2. サーキットブレーカーが発動するレベルの価格変動（15%）
        skip(10 minutes);
        vm.roll(12);
        uint160 currentPrice = basePrice + uint160((basePrice * 20) / 100);
        uint160 volatilePrice = currentPrice + uint160((currentPrice * 15) / 100);
        bytes32 volatileSlot = encodeSlot0(volatilePrice, int24(100), uint24(0), uint24(3000));
        manager.setDefaultSlotData(volatileSlot);

        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // サーキットブレーカーが発動
        assertTrue(hook.isCircuitBreakerTriggered(key.toId()));

        // 3. 緊急pause（オーナーのみ）
        vm.prank(owner);
        hook.pause();

        // 4. サーキットブレーカーをリセットしてもpause中は取引不可
        vm.prank(owner);
        hook.resetCircuitBreaker(key.toId());

        vm.expectRevert();
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, params, bytes(""));

        // 5. unpauseして取引再開
        vm.prank(owner);
        hook.unpause();

        vm.prank(address(manager));
        (bytes4 selector,,) = hook.beforeSwap(address(this), key, params, bytes(""));
        assertEq(selector, BaseHook.beforeSwap.selector);
    }
}
