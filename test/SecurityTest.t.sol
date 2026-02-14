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

    // イベント定義（テスト用）
    event ObservationRingReset(
        PoolId indexed poolId,
        uint256 oldCount,
        uint256 stalenessThreshold
    );

    event ObservationRecorded(
        PoolId indexed poolId,
        uint256 timestamp,
        uint160 sqrtPriceX96,
        uint256 observationCount
    );

    event WarmupPeriodStarted(
        PoolId indexed poolId,
        uint256 until,
        string reason
    );

    event WarmupPeriodEnded(
        PoolId indexed poolId
    );

    event DynamicFeeCalculated(
        PoolId indexed poolId,
        uint256 volatility,
        uint24 fee,
        uint256 observationCount,
        uint160 currentPrice
    );

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
        emit VolatilityDynamicFeeHook.CircuitBreakerActivated(key.toId(), 0, volatilePrice, 0, 0);

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

    /// @notice 長期無取引後のstaleness回復を確認
    function test_security_stalenessRecovery() public {
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

        // 正常な観測を構築（10分ごとに10回）
        for (uint256 i = 1; i <= 10; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            uint160 newPrice = basePrice + uint160((basePrice * i * 3) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // 35分間（STALENESS_THRESHOLD=30分を超える）取引なし
        skip(35 minutes);
        vm.roll(20);

        // 新しい価格で取引を実行（staleness回復のはず）
        uint160 recoveryPrice = basePrice + uint160((basePrice * 5) / 100);
        bytes32 recoverySlot = encodeSlot0(recoveryPrice, int24(50), uint24(0), uint24(3000));
        manager.setDefaultSlotData(recoverySlot);

        // ObservationRingReset イベントと ObservationRecorded イベントの発火を期待
        // checkData=true で payload も検証（Codex advisory issue 対応）
        vm.expectEmit(true, false, false, true, address(hook));
        emit ObservationRingReset(key.toId(), 11, 30 minutes); // oldCount=11 (初期1件 + 10回)

        vm.expectEmit(true, false, false, true, address(hook));
        emit ObservationRecorded(key.toId(), block.timestamp, recoveryPrice, 1);

        // staleness回復が機能することを確認
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
    }

    /// @notice サーキットブレーカー自動リセットを確認
    function test_security_circuitBreakerAutoReset() public {
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

        // 12%の価格変動でサーキットブレーカー発動（10%超）
        skip(10 minutes);
        vm.roll(15);
        uint160 abnormalPrice = basePrice + uint160((basePrice * 6) / 100); // ~12% actual price change
        bytes32 abnormalSlot = encodeSlot0(abnormalPrice, int24(60), uint24(0), uint24(3000));
        manager.setDefaultSlotData(abnormalSlot);

        // サーキットブレーカーが発動して観測記録はスキップされる
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // サーキットブレーカーが発動していることを確認
        assertTrue(hook.circuitBreakerTriggered(key.toId()), "Circuit breaker should be triggered");

        // 次のスワップはCIRCUIT_BREAKER_COOLDOWN (1時間) 以内なので拒否される
        skip(30 minutes); // 1時間未満
        vm.prank(address(manager));
        vm.expectRevert();
        hook.beforeSwap(address(this), key, params, bytes(""));

        // CIRCUIT_BREAKER_COOLDOWN (1時間) 経過後は自動リセット
        skip(31 minutes); // 合計61分
        vm.roll(20);

        // 正常価格に戻る
        uint160 normalPrice = basePrice + uint160((basePrice * 22) / 100);
        bytes32 normalSlot = encodeSlot0(normalPrice, int24(110), uint24(0), uint24(3000));
        manager.setDefaultSlotData(normalSlot);

        // 自動リセットされているのでスワップは成功するはず
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, params, bytes(""));

        // サーキットブレーカーがリセットされていることを確認
        assertFalse(hook.circuitBreakerTriggered(key.toId()), "Circuit breaker should be auto-reset");
    }

    // ============================================
    // Phase 3: ウォームアップ期間テスト
    // ============================================

    /// @notice Staleness リセット後にウォームアップ期間が開始されることを検証
    function test_security_warmupAfterStaleness() public {
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

        // Build normal observations
        for (uint256 i = 1; i <= 5; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            uint160 newPrice = basePrice + uint160((basePrice * i * 2) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // Wait for staleness (> 30 min)
        skip(35 minutes);
        vm.roll(10);

        uint160 recoveryPrice = basePrice + uint160((basePrice * 5) / 100);
        bytes32 recoverySlot = encodeSlot0(recoveryPrice, int24(50), uint24(0), uint24(3000));
        manager.setDefaultSlotData(recoverySlot);

        // Expect WarmupPeriodStarted event
        vm.expectEmit(true, false, false, true, address(hook));
        emit WarmupPeriodStarted(key.toId(), block.timestamp + 30 minutes, "ring_reset");

        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // Verify warmupUntil is set
        assertEq(hook.warmupUntil(key.toId()), block.timestamp + 30 minutes, "warmupUntil should be set after staleness reset");
    }

    /// @notice ウォームアップ中に BASE_FEE のみが返されることを検証
    function test_security_warmupReturnBaseFee() public {
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

        // Build normal observations
        for (uint256 i = 1; i <= 5; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            uint160 newPrice = basePrice + uint160((basePrice * i * 2) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // Trigger staleness reset
        skip(35 minutes);
        vm.roll(10);

        uint160 recoveryPrice = basePrice + uint160((basePrice * 5) / 100);
        bytes32 recoverySlot = encodeSlot0(recoveryPrice, int24(50), uint24(0), uint24(3000));
        manager.setDefaultSlotData(recoverySlot);

        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // Now during warmup, beforeSwap should return BASE_FEE (300)
        // DynamicFeeCalculated event with volatility=0 and fee=BASE_FEE
        vm.expectEmit(true, false, false, true, address(hook));
        emit DynamicFeeCalculated(key.toId(), 0, 300, 1, recoveryPrice);

        vm.prank(address(manager));
        (bytes4 selector,, uint24 feeWithFlag) = hook.beforeSwap(address(this), key, params, bytes(""));

        assertEq(selector, BaseHook.beforeSwap.selector, "beforeSwap should succeed during warmup");
        // fee should be BASE_FEE | OVERRIDE_FEE_FLAG
        uint24 baseFee = feeWithFlag & 0x0FFFFF; // mask out the flag bit
        assertEq(baseFee, 300, "Fee should be BASE_FEE during warmup");
    }

    /// @notice ウォームアップ期間が自然に終了し、通常のボラティリティ計算が再開されることを検証
    function test_security_warmupAutoExpiry() public {
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

        // Build normal observations
        for (uint256 i = 1; i <= 5; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            uint160 newPrice = basePrice + uint160((basePrice * i * 2) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // Trigger staleness reset
        skip(35 minutes);
        vm.roll(10);

        uint160 recoveryPrice = basePrice + uint160((basePrice * 5) / 100);
        bytes32 recoverySlot = encodeSlot0(recoveryPrice, int24(50), uint24(0), uint24(3000));
        manager.setDefaultSlotData(recoverySlot);

        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // Verify warmup is active
        assertTrue(hook.warmupUntil(key.toId()) > block.timestamp, "Warmup should be active");

        // Skip past warmup duration (30 minutes)
        skip(31 minutes);
        vm.roll(15);

        // Verify warmup has expired
        assertTrue(hook.warmupUntil(key.toId()) <= block.timestamp, "Warmup should have expired");

        // beforeSwap should now use normal volatility calculation (not BASE_FEE forced)
        vm.prank(address(manager));
        (bytes4 selector,,) = hook.beforeSwap(address(this), key, params, bytes(""));
        assertEq(selector, BaseHook.beforeSwap.selector, "beforeSwap should succeed after warmup expiry");
    }

    /// @notice 初回 staleness スワップで beforeSwap が BASE_FEE を返すことを検証
    /// @dev Codex arch review: warmup must protect the FIRST post-stale swap
    function test_security_firstPostStaleSwapProtected() public {
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

        // Build normal observations
        for (uint256 i = 1; i <= 5; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            uint160 newPrice = basePrice + uint160((basePrice * i * 2) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // Wait for staleness (> 30 min)
        skip(35 minutes);
        vm.roll(10);

        // BEFORE any afterSwap, call beforeSwap - it should detect staleness and use BASE_FEE
        vm.expectEmit(true, false, false, true, address(hook));
        emit WarmupPeriodStarted(key.toId(), block.timestamp + 30 minutes, "staleness");

        vm.expectEmit(true, false, false, true, address(hook));
        emit DynamicFeeCalculated(key.toId(), 0, 300, 6, basePrice + uint160((basePrice * 5 * 2) / 100));

        vm.prank(address(manager));
        (bytes4 selector,, uint24 feeWithFlag) = hook.beforeSwap(address(this), key, params, bytes(""));

        assertEq(selector, BaseHook.beforeSwap.selector, "First post-stale beforeSwap should succeed");
        uint24 baseFee = feeWithFlag & 0x0FFFFF;
        assertEq(baseFee, 300, "First post-stale swap should return BASE_FEE");
        assertTrue(hook.warmupUntil(key.toId()) > block.timestamp, "warmupUntil should be set by beforeSwap");
    }

    /// @notice ウォームアップ終了時に WarmupPeriodEnded イベントが発行されることを検証
    function test_security_warmupEndedEventEmitted() public {
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

        // Build observations and trigger staleness
        for (uint256 i = 1; i <= 5; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            uint160 newPrice = basePrice + uint160((basePrice * i * 2) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // Trigger staleness and warmup via beforeSwap
        skip(35 minutes);
        vm.roll(10);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, params, bytes(""));

        // Add observations during warmup so data won't be stale after warmup expires
        uint160 freshPrice = basePrice + uint160((basePrice * 5) / 100);
        bytes32 freshSlot = encodeSlot0(freshPrice, int24(50), uint24(0), uint24(3000));
        manager.setDefaultSlotData(freshSlot);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        for (uint256 i = 1; i <= 3; i++) {
            skip(10 minutes);
            vm.roll(10 + i);
            uint160 p = freshPrice + uint160((freshPrice * i) / 100);
            bytes32 s = encodeSlot0(p, int24(int256(50 + i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(s);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // Skip remaining warmup (warmup started ~35min mark, now at ~65min, need to reach ~65min from staleness trigger)
        // warmupUntil = staleness_trigger_time + 30 min. We've used ~30min of observations. Skip 1 more minute.
        skip(1 minutes);
        vm.roll(15);

        // Next beforeSwap should emit WarmupPeriodEnded
        vm.expectEmit(true, false, false, false, address(hook));
        emit WarmupPeriodEnded(key.toId());

        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, params, bytes(""));

        // warmupUntil should be reset to 0
        assertEq(hook.warmupUntil(key.toId()), 0, "warmupUntil should be cleared after expiry");
    }

    // ============================================
    // Phase 2: ウォームアップ + サーキットブレーカー交差テスト
    // ============================================

    /// @notice ウォームアップ中にサーキットブレーカーが発動し、CB が優先されることを検証
    function test_security_warmupAndCircuitBreakerInteraction() public {
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

        // Build normal observations across multiple blocks
        for (uint256 i = 1; i <= 5; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            uint160 newPrice = basePrice + uint160((basePrice * i * 2) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // Trigger staleness -> warmup
        skip(35 minutes);
        vm.roll(10);
        uint160 recoveryPrice = basePrice + uint160((basePrice * 5) / 100);
        bytes32 recoverySlot = encodeSlot0(recoveryPrice, int24(50), uint24(0), uint24(3000));
        manager.setDefaultSlotData(recoverySlot);

        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // Verify warmup is active
        assertTrue(hook.warmupUntil(key.toId()) > block.timestamp, "Warmup should be active");

        // During warmup, beforeSwap returns BASE_FEE (warmup protects)
        vm.prank(address(manager));
        (bytes4 sel,, uint24 fee) = hook.beforeSwap(address(this), key, params, bytes(""));
        assertEq(sel, BaseHook.beforeSwap.selector, "beforeSwap should succeed during warmup");
        assertEq(fee & 0x0FFFFF, 300, "Should return BASE_FEE during warmup");

        // Trigger circuit breaker via afterSwap with 15% price change
        skip(10 minutes);
        vm.roll(12);
        uint160 cbPrice = recoveryPrice + uint160((recoveryPrice * 15) / 100);
        bytes32 cbSlot = encodeSlot0(cbPrice, int24(100), uint24(0), uint24(3000));
        manager.setDefaultSlotData(cbSlot);

        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // Circuit breaker should be triggered
        assertTrue(hook.isCircuitBreakerTriggered(key.toId()), "CB should be triggered during warmup");

        // Now CB takes priority over warmup - next beforeSwap should revert
        vm.expectRevert(VolatilityDynamicFeeHook.CircuitBreakerTriggered.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, params, bytes(""));
    }

    // ============================================
    // Phase 3: 境界値・エッジケーステスト
    // ============================================

    /// @notice MAX_FEE (5000) にキャップされることを検証
    function test_security_maxFeeCap() public {
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

        // Build observations with large price swings (8-9% each, under CB threshold)
        for (uint256 i = 1; i <= 10; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            // Alternate price up and down by ~9% to create high volatility
            uint160 newPrice;
            if (i % 2 == 0) {
                newPrice = basePrice + uint160((basePrice * 9) / 100);
            } else {
                newPrice = basePrice - uint160((basePrice * 9) / 100);
            }
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // Fee should be capped at MAX_FEE
        uint24 fee = hook.getCurrentFee(key);
        assertLe(fee, 5000, "Fee should not exceed MAX_FEE (5000)");
    }

    /// @notice MIN_UPDATE_INTERVAL 境界テスト: 9:59 はスキップ、10:00 は記録
    function test_security_minUpdateIntervalBoundary() public {
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

        // At 9 minutes 59 seconds - should NOT record observation
        skip(10 minutes - 1);
        uint160 newPrice1 = basePrice + uint160(1000000);
        bytes32 newSlot1 = encodeSlot0(newPrice1, int24(5), uint24(0), uint24(3000));
        manager.setDefaultSlotData(newSlot1);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        uint160[] memory prices1 = hook.getPriceHistory(key);
        assertEq(prices1.length, 1, "Should still have only 1 observation at 9:59");

        // At exactly 10 minutes (1 more second) - should record observation
        skip(1);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        uint160[] memory prices2 = hook.getPriceHistory(key);
        assertEq(prices2.length, 2, "Should have 2 observations at 10:00");
    }

    /// @notice CB cooldown 境界テスト: 59:59 は revert、1:00:00 は自動リセット
    function test_security_circuitBreakerCooldownBoundary() public {
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

        // Build observations
        for (uint256 i = 1; i <= 10; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            uint160 newPrice = basePrice + uint160((basePrice * i) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // Trigger CB with 15% price change
        skip(10 minutes);
        vm.roll(12);
        uint160 currentPrice = basePrice + uint160((basePrice * 10) / 100);
        uint160 volatilePrice = currentPrice + uint160((currentPrice * 15) / 100);
        bytes32 volatileSlot = encodeSlot0(volatilePrice, int24(100), uint24(0), uint24(3000));
        manager.setDefaultSlotData(volatileSlot);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        assertTrue(hook.isCircuitBreakerTriggered(key.toId()), "CB should be triggered");

        // At 59 minutes 59 seconds - should still revert
        skip(1 hours - 1);
        vm.expectRevert(VolatilityDynamicFeeHook.CircuitBreakerTriggered.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, params, bytes(""));

        // At exactly 1 hour - should auto-reset
        skip(1);
        vm.roll(20);
        vm.prank(address(manager));
        (bytes4 sel,,) = hook.beforeSwap(address(this), key, params, bytes(""));
        assertEq(sel, BaseHook.beforeSwap.selector, "Should succeed at exactly CIRCUIT_BREAKER_COOLDOWN");
    }

    /// @notice 複数プールの状態分離テスト
    function test_security_multiplePoolsIsolation() public {
        // Pool A
        PoolKey memory keyA = PoolKey(
            Currency.wrap(address(0x1)),
            Currency.wrap(address(0x2)),
            uint24(0x800000),
            int24(1),
            IHooks(address(0))
        );
        // Pool B (different currency pair)
        PoolKey memory keyB = PoolKey(
            Currency.wrap(address(0x3)),
            Currency.wrap(address(0x4)),
            uint24(0x800000),
            int24(1),
            IHooks(address(0))
        );
        uint160 basePrice = uint160(1 << 96);

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        // Initialize both pools
        vm.prank(address(manager));
        hook.afterInitialize(address(this), keyA, basePrice, int24(0));
        vm.prank(address(manager));
        hook.afterInitialize(address(this), keyB, basePrice, int24(0));

        SwapParams memory params = SwapParams(true, 1000, 0);

        // Build observations for both pools
        for (uint256 i = 1; i <= 10; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            uint160 newPrice = basePrice + uint160((basePrice * i) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), keyA, params, BalanceDelta.wrap(0), bytes(""));
            vm.prank(address(manager));
            hook.afterSwap(address(this), keyB, params, BalanceDelta.wrap(0), bytes(""));
        }

        // Trigger CB on pool A only
        skip(10 minutes);
        vm.roll(12);
        uint160 currentPrice = basePrice + uint160((basePrice * 10) / 100);
        uint160 volatilePrice = currentPrice + uint160((currentPrice * 15) / 100);
        bytes32 volatileSlot = encodeSlot0(volatilePrice, int24(100), uint24(0), uint24(3000));
        manager.setDefaultSlotData(volatileSlot);
        vm.prank(address(manager));
        hook.afterSwap(address(this), keyA, params, BalanceDelta.wrap(0), bytes(""));

        // Pool A: CB triggered
        assertTrue(hook.isCircuitBreakerTriggered(keyA.toId()), "Pool A CB should be triggered");
        // Pool B: CB NOT triggered (isolated)
        assertFalse(hook.isCircuitBreakerTriggered(keyB.toId()), "Pool B CB should NOT be triggered");

        // Pool B should still work
        bytes32 normalSlot = encodeSlot0(currentPrice, int24(50), uint24(0), uint24(3000));
        manager.setDefaultSlotData(normalSlot);
        vm.prank(address(manager));
        (bytes4 sel,,) = hook.beforeSwap(address(this), keyB, params, bytes(""));
        assertEq(sel, BaseHook.beforeSwap.selector, "Pool B swap should succeed");
    }

    /// @notice uint160 上限に近い sqrtPriceX96 でオーバーフローしないことを検証
    function test_security_largeSqrtPriceNoOverflow() public {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0x1)),
            Currency.wrap(address(0x2)),
            uint24(0x800000),
            int24(1),
            IHooks(address(0))
        );
        // Use a large sqrtPriceX96 near uint160 max / 2
        // (uint160 max = ~1.46e48, use ~7.3e47)
        uint160 basePrice = uint160(type(uint160).max / 2);

        bytes32 slot = encodeSlot0(basePrice, int24(0), uint24(0), uint24(3000));
        manager.setDefaultSlotData(slot);

        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        SwapParams memory params = SwapParams(true, 1000, 0);

        // Build observations with small price changes (1%) on large base price
        for (uint256 i = 1; i <= 5; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            uint160 newPrice = basePrice + uint160(uint256(basePrice) * i / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // getCurrentFee should not revert (FullMath handles large values)
        uint24 fee = hook.getCurrentFee(key);
        assertGe(fee, 300, "Fee should be at least BASE_FEE");
        assertLe(fee, 5000, "Fee should not exceed MAX_FEE");
    }

    /// @notice ウォームアップ中でも afterSwap の MAX_PRICE_CHANGE_BPS (50%) チェックは有効
    function test_security_warmupDoesNotBypassMaxPriceChange() public {
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

        // Build normal observations across multiple blocks
        for (uint256 i = 1; i <= 5; i++) {
            skip(10 minutes);
            vm.roll(i + 1);
            uint160 newPrice = basePrice + uint160((basePrice * i * 2) / 100);
            bytes32 newSlot = encodeSlot0(newPrice, int24(int256(i * 5)), uint24(0), uint24(3000));
            manager.setDefaultSlotData(newSlot);
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        }

        // Trigger staleness -> warmup
        skip(35 minutes);
        vm.roll(10);
        uint160 recoveryPrice = basePrice + uint160((basePrice * 5) / 100);
        bytes32 recoverySlot = encodeSlot0(recoveryPrice, int24(50), uint24(0), uint24(3000));
        manager.setDefaultSlotData(recoverySlot);

        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // Verify warmup is active
        assertTrue(hook.warmupUntil(key.toId()) > block.timestamp, "Warmup should be active");

        // Attempt extreme price change (70%) during warmup via afterSwap
        // afterSwap security checks are independent of warmup
        skip(10 minutes);
        vm.roll(12);
        uint160 extremePrice = recoveryPrice + uint160((recoveryPrice * 70) / 100);
        bytes32 extremeSlot = encodeSlot0(extremePrice, int24(200), uint24(0), uint24(3000));
        manager.setDefaultSlotData(extremeSlot);

        // Should revert with PriceManipulationDetected (50% threshold)
        vm.expectRevert(VolatilityDynamicFeeHook.PriceManipulationDetected.selector);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
    }
}
