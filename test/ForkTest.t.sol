// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {VolatilityDynamicFeeHook} from "../src/VolatilityDynamicFeeHook.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Test hook that bypasses address validation
contract TestHook is VolatilityDynamicFeeHook {
    constructor(IPoolManager m) VolatilityDynamicFeeHook(m) {}

    // override the internal validation to disable permission check during tests
    function validateHookAddress(BaseHook) internal pure override {}
}

/// @title ForkTest
/// @notice フォークテストでVolatilityDynamicFeeHookの動作を検証
/// @dev 実際のUniswap v4環境を想定したシナリオテスト
contract ForkTest is Test {
    VolatilityDynamicFeeHook public hook;
    IPoolManager public poolManager;

    // テスト用のアドレス
    address public alice = address(0x1234);
    address public bob = address(0x5678);

    function setUp() public {
        // ラベル設定（トレース時に便利）
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
    }

    /// @notice Hookのデプロイとセットアップテスト
    function test_deployHook() public {
        // NOTE: 実際のv4 PoolManagerアドレスが必要
        // テストネットやメインネットのアドレスをここに設定

        // モックPoolManagerを使用（実際のフォーク時はコメントアウト）
        MockPoolManager mockManager = new MockPoolManager();
        poolManager = IPoolManager(address(mockManager));

        // Hookをデプロイ（TestHookを使用してアドレス検証をバイパス）
        TestHook t = new TestHook(poolManager);
        hook = VolatilityDynamicFeeHook(address(t));

        assertEq(address(hook.poolManager()), address(poolManager));
    }

    /// @notice 動的手数料がボラティリティに応じて変化することを確認
    function test_dynamicFeeChangesWithVolatility() public {
        // Setup
        MockPoolManager mockManager = new MockPoolManager();
        poolManager = IPoolManager(address(mockManager));
        TestHook t = new TestHook(poolManager);
        hook = VolatilityDynamicFeeHook(address(t));

        // プールキーの作成（Dynamic Fee有効）
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: uint24(0x800000), // Dynamic Fee Flag
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });

        // 初期化
        uint160 initialPrice = uint160(1 << 96);
        vm.prank(address(poolManager));
        hook.afterInitialize(address(this), key, initialPrice, int24(0));

        // 初期手数料を確認（ボラティリティ0なのでBASE_FEE）
        uint24 initialFee = hook.getCurrentFee(key);
        assertEq(initialFee, 300, "Initial fee should be BASE_FEE (0.03%)");

        // 価格変動をシミュレート
        // Codex版: 1時間間隔で観測を記録
        skip(1 hours);
        uint160 newPrice = initialPrice + uint160((initialPrice * 20) / 100); // +20%
        mockManager.setSlot0(newPrice, int24(0), uint24(0), uint24(3000));

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: 1000, sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        // ボラティリティが増加したため手数料も上昇
        uint24 newFee = hook.getCurrentFee(key);
        assertGt(newFee, initialFee, "Fee should increase with volatility");
        console.log("Initial Fee:", initialFee);
        console.log("New Fee after 20% price change:", newFee);
    }

    /// @notice 複数回のスワップで手数料が段階的に変化することを確認
    function test_feeEvolutionOverMultipleSwaps() public {
        // Setup
        MockPoolManager mockManager = new MockPoolManager();
        poolManager = IPoolManager(address(mockManager));
        TestHook t = new TestHook(poolManager);
        hook = VolatilityDynamicFeeHook(address(t));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: uint24(0x800000),
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });

        uint160 basePrice = uint160(1 << 96);
        vm.prank(address(poolManager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        console.log("\n=== Fee Evolution Test ===");
        console.log("Simulating market conditions with varying volatility\n");

        uint24[] memory fees = new uint24[](6);
        fees[0] = hook.getCurrentFee(key);
        console.log("Swap 0 (Initial): Fee = %d bps", fees[0]);

        // 5回のスワップをシミュレート
        // Codex版: 1時間間隔で観測を記録
        for (uint256 i = 1; i <= 5; i++) {
            skip(1 hours);

            // 価格を徐々に上昇
            uint160 newPrice = basePrice + uint160((basePrice * i * 3) / 100); // i * 3%
            mockManager.setSlot0(newPrice, int24(0), uint24(0), uint24(3000));

            SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: 1000, sqrtPriceLimitX96: 0});
            vm.prank(address(poolManager));
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

            fees[i] = hook.getCurrentFee(key);
            console.log("Swap %d: Price +%d%%, Fee = %d bps", i, i * 3, fees[i]);
        }

        // 手数料がBASE_FEEより高いことを確認（ボラティリティに反応している）
        for (uint256 i = 1; i < fees.length; i++) {
            assertGt(fees[i], 300, "Fee should be higher than BASE_FEE due to volatility");
        }

        // 最終手数料がMAX_FEEを超えていないことを確認
        assertLe(fees[fees.length - 1], 5000, "Fee should not exceed MAX_FEE");

        console.log("\nResult: Dynamic fee successfully adjusts to market volatility!");
    }

    /// @notice 価格変動制限が機能することを確認
    function test_priceChangeLimitProtection() public {
        MockPoolManager mockManager = new MockPoolManager();
        poolManager = IPoolManager(address(mockManager));
        TestHook t = new TestHook(poolManager);
        hook = VolatilityDynamicFeeHook(address(t));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: uint24(0x800000),
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });

        uint160 basePrice = uint160(1 << 96);
        vm.prank(address(poolManager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));

        // 正常な価格変動（40%）は許可される
        // Codex版: 1時間間隔で観測を記録
        skip(1 hours);
        uint160 normalPrice = basePrice + uint160((basePrice * 40) / 100);
        mockManager.setSlot0(normalPrice, int24(0), uint24(0), uint24(3000));

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: 1000, sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        console.log("40% price change: ALLOWED");

        // 異常な価格変動（60%）は拒否される
        skip(1 hours);
        uint160 excessivePrice = normalPrice + uint160((normalPrice * 60) / 100);
        mockManager.setSlot0(excessivePrice, int24(0), uint24(0), uint24(3000));

        vm.expectRevert(VolatilityDynamicFeeHook.PriceChangeExceedsLimit.selector);
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));

        console.log("60% price change: REJECTED (protection working!)");
    }

    /// @notice ガス使用量の測定
    function test_gasUsage() public {
        MockPoolManager mockManager = new MockPoolManager();
        poolManager = IPoolManager(address(mockManager));
        TestHook t = new TestHook(poolManager);
        hook = VolatilityDynamicFeeHook(address(t));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: uint24(0x800000),
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });

        uint160 basePrice = uint160(1 << 96);

        // afterInitialize のガス使用量
        uint256 gasBefore = gasleft();
        vm.prank(address(poolManager));
        hook.afterInitialize(address(this), key, basePrice, int24(0));
        uint256 gasUsed = gasBefore - gasleft();
        console.log("\nafterInitialize gas used:", gasUsed);

        // afterSwap のガス使用量（価格更新あり）
        // Codex版: 1時間間隔で観測を記録
        skip(1 hours);
        uint160 newPrice = basePrice + uint160((basePrice * 10) / 100);
        mockManager.setSlot0(newPrice, int24(0), uint24(0), uint24(3000));

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: 1000, sqrtPriceLimitX96: 0});

        gasBefore = gasleft();
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        gasUsed = gasBefore - gasleft();
        console.log("afterSwap gas used (with update):", gasUsed);

        // afterSwap のガス使用量（間隔制限内）
        vm.warp(block.timestamp + 30 minutes); // MIN_UPDATE_INTERVAL未満

        gasBefore = gasleft();
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
        gasUsed = gasBefore - gasleft();
        console.log("afterSwap gas used (skipped):", gasUsed);
    }
}

/// @notice モックPoolManager（テスト用）
contract MockPoolManager {
    bytes32 public defaultSlotData;

    function setDefaultSlotData(bytes32 d) external {
        defaultSlotData = d;
    }

    function setSlot0(uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) external {
        uint256 v = uint256(sqrtPriceX96);
        uint256 tickBits = uint256(uint24(tick)) << 160;
        uint256 protoBits = uint256(protocolFee) << 184;
        uint256 lpBits = uint256(lpFee) << 208;
        defaultSlotData = bytes32(v | tickBits | protoBits | lpBits);
    }

    // extsload used by StateLibrary.getSlot0
    function extsload(bytes32) external view returns (bytes32) {
        return defaultSlotData;
    }
}
