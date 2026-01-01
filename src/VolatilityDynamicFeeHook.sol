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
import {ObservationLibrary} from "./libraries/ObservationLibrary.sol";
import {BollingerBands} from "./libraries/BollingerBands.sol";

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
    error InsufficientObservations();

    // プールごとの状態管理
    mapping(PoolId => ObservationLibrary.RingBuffer) public observations;
    mapping(PoolId => BollingerBands.Config) public bbConfig;
    mapping(PoolId => uint256) public lastRebalanceTime;

    // 設定パラメータ（USDC/JPYC = USD/JPY為替ペア向け最適化）
    // USDC/JPYCは実質的にドル円レートを反映するため、通常の為替ボラティリティ（0.5-1.5%/日）を想定
    uint256 public constant HISTORY_SIZE = 10;      // 保存する価格履歴の数
    uint24 public constant BASE_FEE = 300;          // 基本手数料 0.03% (300 = 0.03%) - 為替ペア標準
    uint24 public constant MAX_FEE = 5000;          // 最大手数料 0.5% (5000 = 0.5%) - 急変時保護
    uint256 public constant VOLATILITY_THRESHOLD = 500; // ボラティリティの閾値
    uint256 public constant MIN_UPDATE_INTERVAL = 1 hours; // Codex版: 1時間間隔で観測を記録
    uint256 public constant MAX_PRICE_CHANGE_BPS = 5000; // 最大価格変動 50% (5000 = 50%)
    uint256 public constant REBALANCE_COOLDOWN = 2 hours; // リバランスのクールダウン期間

    // イベント定義
    event RebalanceTriggered(
        PoolId indexed poolId,
        int24 upperBand,
        int24 middleBand,
        int24 lowerBand,
        bool isAbove
    );

    event ObservationRecorded(
        PoolId indexed poolId,
        uint256 timestamp,
        uint160 sqrtPriceX96,
        uint256 observationCount
    );

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

        PoolId poolId = key.toId();

        // Bollinger Bands設定を初期化
        bbConfig[poolId] = BollingerBands.Config({
            period: 24,              // 24時間（24個の観測）
            standardDeviation: 200,  // 2.0σ
            timeframe: 86400,        // 24時間（秒）
            softBandBps: 180         // 1.8σ
        });

        // 初期観測を追加
        ObservationLibrary.push(
            observations[poolId],
            block.timestamp,
            sqrtPriceX96
        );

        lastRebalanceTime[poolId] = block.timestamp;

        emit ObservationRecorded(poolId, block.timestamp, sqrtPriceX96, 1);

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

        // 最小更新間隔チェック（1時間）
        ObservationLibrary.RingBuffer storage obs = observations[poolId];
        if (obs.count > 0) {
            uint256 lastIndex = (obs.index + 99) % 100;
            uint256 lastTimestamp = obs.data[lastIndex].timestamp;
            if (block.timestamp < lastTimestamp + MIN_UPDATE_INTERVAL) {
                return (BaseHook.afterSwap.selector, 0);
            }
        }

        // 現在価格を取得
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        // 観測を追加
        ObservationLibrary.push(obs, block.timestamp, sqrtPriceX96);

        emit ObservationRecorded(poolId, block.timestamp, sqrtPriceX96, obs.count);

        // BB計算が可能か確認（24個以上の観測が必要）
        if (obs.count >= bbConfig[poolId].period) {
            // Bollinger Bandsを計算
            BollingerBands.Bands memory bands = BollingerBands.calculate(
                obs,
                bbConfig[poolId]
            );

            // 現在価格がバンド外かチェック
            int24 currentTick = _getCurrentTick(poolId);
            (bool isOutside, bool isAbove) = BollingerBands.isOutOfBands(
                currentTick,
                bands
            );

            // バンド外の場合、リバランスをトリガー
            if (isOutside) {
                _triggerRebalance(poolId, bands, isAbove);
            }
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice ボラティリティを計算（時間重み付き）
    /// @param poolId プールID
    /// @return volatility ボラティリティ（0-100のスケール）
    /// @dev 時間重み付きで価格変動を計算することで、フロントラン攻撃耐性を向上
    function _calculateVolatility(PoolId poolId) internal view returns (uint256) {
        ObservationLibrary.RingBuffer storage obs = observations[poolId];
        uint256 count = obs.count;

        // 履歴が2つ未満の場合は低ボラティリティとみなす
        if (count < 2) {
            return 0;
        }

        // 時間重み付き価格変動率の合計を計算
        uint256 weightedVariation = 0;
        uint256 totalWeight = 0;
        uint256 currentIndex = obs.index == 0 ? 99 : obs.index - 1;

        for (uint256 i = 1; i < count; i++) {
            ObservationLibrary.Observation storage current = obs.data[currentIndex];

            // ひとつ前のインデックスを計算
            uint256 prevIndex = currentIndex == 0 ? 99 : currentIndex - 1;
            ObservationLibrary.Observation storage previous = obs.data[prevIndex];

            // previousSqrtPrice が 0 の場合はスキップしてゼロ除算を防ぐ
            if (previous.sqrtPriceX96 == 0 || current.timestamp <= previous.timestamp) {
                currentIndex = prevIndex;
                continue;
            }

            // 時間の重み: 時間差を使用（短時間の変動ほど重要度を下げる）
            uint256 timeDelta = current.timestamp - previous.timestamp;

            // 最小重みを1に設定（ゼロ除算防止）
            uint256 weight = timeDelta > 0 ? timeDelta : 1;

            // sqrtPriceX96を使って変動を計算（絶対値）
            uint256 curSqrt = uint256(current.sqrtPriceX96);
            uint256 prevSqrt = uint256(previous.sqrtPriceX96);
            uint256 variation;
            if (curSqrt > prevSqrt) {
                variation = ((curSqrt - prevSqrt) * 10000) / prevSqrt;
            } else {
                variation = ((prevSqrt - curSqrt) * 10000) / prevSqrt;
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
        ObservationLibrary.RingBuffer storage obs = observations[key.toId()];
        uint256 count = obs.count;
        uint160[] memory sortedPrices = new uint160[](count);

        if (count > 0) {
            uint256 currentIdx = obs.index == 0 ? 99 : obs.index - 1;
            for (uint256 i = 0; i < count; i++) {
                sortedPrices[count - 1 - i] = obs.data[currentIdx].sqrtPriceX96;
                currentIdx = currentIdx == 0 ? 99 : currentIdx - 1;
            }
        }

        return sortedPrices;
    }

    /// @notice Get current tick for pool
    /// @param poolId プールID
    /// @return 現在のtick値
    function _getCurrentTick(PoolId poolId) internal view returns (int24) {
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        return tick;
    }

    /// @notice Trigger rebalance when price is out of bands
    /// @dev Emits event for off-chain keeper to execute rebalance
    /// @param poolId プールID
    /// @param bands Bollinger Bandsの計算結果
    /// @param isAbove 価格が上限を超えている場合true
    function _triggerRebalance(
        PoolId poolId,
        BollingerBands.Bands memory bands,
        bool isAbove
    ) internal {
        // Check cooldown period (2 hours)
        if (block.timestamp < lastRebalanceTime[poolId] + REBALANCE_COOLDOWN) {
            return;
        }

        lastRebalanceTime[poolId] = block.timestamp;

        // Emit event for keeper
        emit RebalanceTriggered(poolId, bands.upper, bands.middle, bands.lower, isAbove);
    }

    /// @notice Get Bollinger Bands for pool
    /// @param poolId プールID
    /// @return bands Bollinger Bandsの計算結果
    function getBollingerBands(PoolId poolId)
        external
        view
        returns (BollingerBands.Bands memory)
    {
        if (observations[poolId].count < bbConfig[poolId].period) {
            revert InsufficientObservations();
        }
        return BollingerBands.calculate(observations[poolId], bbConfig[poolId]);
    }
}
