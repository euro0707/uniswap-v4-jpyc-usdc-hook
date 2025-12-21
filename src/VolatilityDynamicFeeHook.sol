// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/// @title VolatilityDynamicFeeHook
/// @notice ボラティリティに基づいて動的に手数料を調整するUniswap v4 Hook
/// @dev 過去のスワップ価格変動を記録し、ボラティリティを計算して手数料を決定
contract VolatilityDynamicFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // エラー定義
    error MustUseDynamicFee();

    // 価格履歴を保存する構造体
    struct PriceHistory {
        uint160[] sqrtPriceX96History; // 過去のsqrtPriceX96を保存
        uint256 lastUpdateTime;         // 最終更新時刻
    }

    // プールごとの価格履歴
    mapping(PoolId => PriceHistory) public priceHistories;

    // 設定パラメータ
    uint256 public constant HISTORY_SIZE = 10;      // 保存する価格履歴の数
    uint24 public constant BASE_FEE = 500;          // 基本手数料 0.05% (500 = 0.05%)
    uint24 public constant MAX_FEE = 10000;         // 最大手数料 1.0% (10000 = 1.0%)
    uint256 public constant VOLATILITY_THRESHOLD = 100; // ボラティリティの閾値

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @notice Hookの権限設定
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice プール初期化後の処理
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        // Dynamic Feeが有効か確認
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();

        // 初期価格を履歴に追加
        PoolId poolId = key.toId();
        priceHistories[poolId].sqrtPriceX96History.push(sqrtPriceX96);
        priceHistories[poolId].lastUpdateTime = block.timestamp;

        return BaseHook.afterInitialize.selector;
    }

    /// @notice スワップ前の処理：動的手数料を設定
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        // ボラティリティを計算
        uint256 volatility = _calculateVolatility(key.toId());

        // ボラティリティに基づいて手数料を決定
        uint24 dynamicFee = _getFeeBasedOnVolatility(volatility);

        // 手数料を更新（OVERRIDE_FEE_FLAGを設定）
        uint24 feeWithFlag = dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    /// @notice スワップ後の処理：価格履歴を更新
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        
        // 現在の価格を取得
        (uint160 sqrtPriceX96,,) = poolManager.getSlot0(poolId);

        // 価格履歴を更新
        _updatePriceHistory(poolId, sqrtPriceX96);

        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice ボラティリティを計算
    /// @param poolId プールID
    /// @return volatility ボラティリティ（0-100のスケール）
    function _calculateVolatility(PoolId poolId) internal view returns (uint256) {
        PriceHistory storage history = priceHistories[poolId];
        uint256 historyLength = history.sqrtPriceX96History.length;

        // 履歴が2つ未満の場合は低ボラティリティとみなす
        if (historyLength < 2) {
            return 0;
        }

        // 価格変動率の合計を計算
        uint256 totalVariation = 0;
        for (uint256 i = 1; i < historyLength; i++) {
            uint160 currentPrice = history.sqrtPriceX96History[i];
            uint160 previousPrice = history.sqrtPriceX96History[i - 1];

            // 変動率を計算（絶対値）
            uint256 variation;
            if (currentPrice > previousPrice) {
                variation = ((currentPrice - previousPrice) * 10000) / previousPrice;
            } else {
                variation = ((previousPrice - currentPrice) * 10000) / previousPrice;
            }

            totalVariation += variation;
        }

        // 平均変動率を計算（0-100のスケールに正規化）
        uint256 avgVariation = totalVariation / (historyLength - 1);
        
        // 100を上限とする
        return avgVariation > 100 ? 100 : avgVariation;
    }

    /// @notice ボラティリティに基づいて手数料を決定
    /// @param volatility ボラティリティ（0-100）
    /// @return fee 手数料（bps単位）
    function _getFeeBasedOnVolatility(uint256 volatility) internal pure returns (uint24) {
        // 線形補間で手数料を計算
        // volatility = 0  -> BASE_FEE (0.05%)
        // volatility = 100 -> MAX_FEE (1.0%)
        uint24 feeRange = MAX_FEE - BASE_FEE;
        uint24 additionalFee = uint24((feeRange * volatility) / 100);
        
        return BASE_FEE + additionalFee;
    }

    /// @notice 価格履歴を更新
    /// @param poolId プールID
    /// @param sqrtPriceX96 新しい価格
    function _updatePriceHistory(PoolId poolId, uint160 sqrtPriceX96) internal {
        PriceHistory storage history = priceHistories[poolId];

        // 履歴が上限に達している場合は古いものを削除
        if (history.sqrtPriceX96History.length >= HISTORY_SIZE) {
            // 配列の先頭を削除（シフト）
            for (uint256 i = 0; i < HISTORY_SIZE - 1; i++) {
                history.sqrtPriceX96History[i] = history.sqrtPriceX96History[i + 1];
            }
            history.sqrtPriceX96History.pop();
        }

        // 新しい価格を追加
        history.sqrtPriceX96History.push(sqrtPriceX96);
        history.lastUpdateTime = block.timestamp;
    }

    /// @notice 現在の手数料を取得（外部から確認用）
    /// @param key プールキー
    /// @return 現在の動的手数料
    function getCurrentFee(PoolKey calldata key) external view returns (uint24) {
        uint256 volatility = _calculateVolatility(key.toId());
        return _getFeeBasedOnVolatility(volatility);
    }

    /// @notice プールの価格履歴を取得
    /// @param key プールキー
    /// @return 価格履歴の配列
    function getPriceHistory(PoolKey calldata key) external view returns (uint160[] memory) {
        return priceHistories[key.toId()].sqrtPriceX96History;
    }
}
