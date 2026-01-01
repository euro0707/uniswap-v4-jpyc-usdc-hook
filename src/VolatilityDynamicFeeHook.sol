// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title VolatilityDynamicFeeHook
/// @notice ボラティリティに基づいて動的に手数料を調整するUniswap v4 Hook
/// @dev 過去のスワップ価格変動を記録し、ボラティリティを計算して手数料を決定
contract VolatilityDynamicFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // エラー定義
    error MustUseDynamicFee();
    error PriceChangeExceedsLimit();

    // 過去の価格履歴を保持するための構造体
    struct PriceHistory {
        uint160[] prices;
        uint256[] timestamps;
        uint256 index;
        uint256 count;
        uint256 lastUpdateTime;
    }

    // プールごとの価格履歴
    mapping(PoolId => PriceHistory) public poolPriceHistory;

    // 設定パラメータ（USDC/JPYC = USD/JPY為替ペア向け最適化）
    // USDC/JPYCは実質的にドル円レートを反映するため、通常の為替ボラティリティ（0.5-1.5%/日）を想定
    uint256 public constant HISTORY_SIZE = 10;      // 保存する価格履歴の数
    uint24 public constant BASE_FEE = 300;          // 基本手数料 0.03% (300 = 0.03%) - 為替ペア標準
    uint24 public constant MAX_FEE = 5000;          // 最大手数料 0.5% (5000 = 0.5%) - 急変時保護
    uint256 public constant VOLATILITY_THRESHOLD = 500; // ボラティリティの閾値
    uint256 public constant MIN_UPDATE_INTERVAL = 1 hours; // Codex版: 1時間間隔で観測を記録
    uint256 public constant MAX_PRICE_CHANGE_BPS = 5000; // 最大価格変動 50% (5000 = 50%)

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
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24
    ) internal override returns (bytes4) {
        // Dynamic Feeが有効か確認
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();

        // 初期価格を履歴に追加
        PoolId poolId = key.toId();

        // 履歴配列の初期化
        poolPriceHistory[poolId].prices = new uint160[](HISTORY_SIZE);
        poolPriceHistory[poolId].timestamps = new uint256[](HISTORY_SIZE);
        poolPriceHistory[poolId].prices[0] = sqrtPriceX96;
        poolPriceHistory[poolId].timestamps[0] = block.timestamp;
        poolPriceHistory[poolId].index = 1;
        poolPriceHistory[poolId].count = 1;
        poolPriceHistory[poolId].lastUpdateTime = block.timestamp;

        return BaseHook.afterInitialize.selector;
    }

    /// @notice スワップ前の処理：動的手数料を設定
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    ) internal override view returns (bytes4, BeforeSwapDelta, uint24) {
        // ボラティリティを計算
        uint256 volatility = _calculateVolatility(key.toId());

        // ボラティリティに基づいて手数料を決定
        uint24 fee = _getFeeBasedOnVolatility(volatility);

        // 手数料を更新（OVERRIDE_FEE_FLAGを設定）
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    /// @notice スワップ後の処理：価格履歴を更新
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        // 履歴を取得
        PriceHistory storage history = poolPriceHistory[poolId];

        // 最短更新間隔をチェック（Checks）
        if (history.lastUpdateTime != 0 && block.timestamp < history.lastUpdateTime + MIN_UPDATE_INTERVAL) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // Effects: インデックス/カウント/タイムスタンプを先に更新して再入を防ぐ
        uint256 writeIndex = history.index;
        history.index = (history.index + 1) % HISTORY_SIZE;
        if (history.count < HISTORY_SIZE) {
            history.count++;
        }
        history.lastUpdateTime = block.timestamp;

        // Interactions: 必要な外部呼び出しは最後に行う
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        // 価格変動の検証（異常値フィルタ）
        if (history.count > 0) {
            uint256 prevIndex = writeIndex == 0 ? HISTORY_SIZE - 1 : writeIndex - 1;
            uint160 previousPrice = history.prices[prevIndex];

            // 前回の価格が存在し、かつゼロでない場合に検証
            if (previousPrice > 0) {
                uint256 cur = uint256(sqrtPriceX96);
                uint256 prev = uint256(previousPrice);
                uint256 priceChange;

                // 価格変動率を計算（bps単位）
                if (cur > prev) {
                    priceChange = ((cur - prev) * 10000) / prev;
                } else {
                    priceChange = ((prev - cur) * 10000) / prev;
                }

                // 価格変動が上限を超える場合はrevert
                if (priceChange > MAX_PRICE_CHANGE_BPS) {
                    revert PriceChangeExceedsLimit();
                }
            }
        }

        // 価格とタイムスタンプを記録
        history.prices[writeIndex] = sqrtPriceX96;
        history.timestamps[writeIndex] = block.timestamp;

        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice ボラティリティを計算（時間重み付き）
    /// @param poolId プールID
    /// @return volatility ボラティリティ（0-100のスケール）
    /// @dev 時間重み付きで価格変動を計算することで、フロントラン攻撃耐性を向上
    function _calculateVolatility(PoolId poolId) internal view returns (uint256) {
        PriceHistory storage history = poolPriceHistory[poolId];
        uint256 count = history.count;

        // 履歴が2つ未満の場合は低ボラティリティとみなす
        if (count < 2) {
            return 0;
        }

        // 時間重み付き価格変動率の合計を計算
        uint256 weightedVariation = 0;
        uint256 totalWeight = 0;
        uint256 currentIndex = history.index == 0 ? HISTORY_SIZE - 1 : history.index - 1;

        for (uint256 i = 1; i < count; i++) {
            uint160 currentPrice = history.prices[currentIndex];
            uint256 currentTime = history.timestamps[currentIndex];

            // ひとつ前のインデックスを計算
            uint256 prevIndex = currentIndex == 0 ? HISTORY_SIZE - 1 : currentIndex - 1;
            uint160 previousPrice = history.prices[prevIndex];
            uint256 previousTime = history.timestamps[prevIndex];

            // previousPrice が 0 の場合はスキップしてゼロ除算を防ぐ
            if (previousPrice == 0 || currentTime <= previousTime) {
                currentIndex = prevIndex;
                continue;
            }

            // 時間の重み: 時間差を使用（短時間の変動ほど重要度を下げる）
            uint256 timeDelta = currentTime - previousTime;

            // 最小重みを1に設定（ゼロ除算防止）
            uint256 weight = timeDelta > 0 ? timeDelta : 1;

            // 変動を計算（絶対値） - uint256 にキャストして安全に計算
            uint256 cur = uint256(currentPrice);
            uint256 prev = uint256(previousPrice);
            uint256 variation;
            if (cur > prev) {
                variation = ((cur - prev) * 10000) / prev;
            } else {
                variation = ((prev - cur) * 10000) / prev;
            }

            // 時間重み付き変動を加算
            weightedVariation += variation * weight;
            totalWeight += weight;
            currentIndex = prevIndex;
        }

        // 重みの合計がゼロの場合は0を返す
        if (totalWeight == 0) {
            return 0;
        }

        // 時間重み付き平均変動率を計算（0-100のスケールに正規化）
        uint256 avgVariation = weightedVariation / totalWeight;

        // USD/JPY為替ペア向けに感度を1/5に調整
        // 通常の為替変動（0.5-1.5%/日）で手数料が急上昇しないよう調整
        // 極端な変動（2%以上）でのみ高手数料に移行
        uint256 scaledVolatility = avgVariation / 5;

        // 100を上限とする
        return scaledVolatility > 100 ? 100 : scaledVolatility;
    }

    /// @notice ボラティリティに基づいて手数料を決定（二次関数カーブ）
    /// @param volatility ボラティリティ（0-100）
    /// @return fee 手数料（bps単位）
    /// @dev 二次関数を使用することで、低ボラティリティ時は緩やかに、高ボラティリティ時は急激に手数料が上昇
    ///      USD/JPY為替ペアでは通常時0.03%、経済指標発表時など急変時に0.5%まで上昇
    function _getFeeBasedOnVolatility(uint256 volatility) internal pure returns (uint24) {
        if (volatility == 0) {
            return BASE_FEE;
        }

        // 二次関数カーブ: fee = BASE_FEE + (MAX_FEE - BASE_FEE) * (volatility/100)^2
        // volatility = 0  -> 0.03% (BASE_FEE) - 通常の為替変動
        // volatility = 50 -> 0.148% - 中程度のボラティリティ
        // volatility = 100 -> 0.5% (MAX_FEE) - 急激な変動時（2%以上）
        uint256 normalizedSquared = (volatility * volatility) / 100; // volatility^2 / 100
        uint256 feeRange = uint256(MAX_FEE) - uint256(BASE_FEE);
        uint256 fee = uint256(BASE_FEE) + (feeRange * normalizedSquared) / 100;

        return fee > MAX_FEE ? MAX_FEE : uint24(fee);
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
        // リングバッファから時系列順に並べ替えて返す
        PriceHistory storage history = poolPriceHistory[key.toId()];
        uint256 count = history.count;
        uint160[] memory sortedPrices = new uint160[](count);
        
        if (count > 0) {
            uint256 currentIdx = history.index == 0 ? HISTORY_SIZE - 1 : history.index - 1;
            for (uint256 i = 0; i < count; i++) {
                sortedPrices[count - 1 - i] = history.prices[currentIdx];
                currentIdx = currentIdx == 0 ? HISTORY_SIZE - 1 : currentIdx - 1;
            }
        }
        
        return sortedPrices;
    }
}
