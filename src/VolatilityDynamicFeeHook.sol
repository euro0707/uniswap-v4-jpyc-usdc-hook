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
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ObservationLibrary} from "./libraries/ObservationLibrary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title VolatilityDynamicFeeHook
/// @notice ボラティリティに基づいて動的に手数料を調整するUniswap v4 Hook
/// @dev 過去のスワップ価格変動を記録し、ボラティリティを計算して手数料を決定

contract VolatilityDynamicFeeHook is BaseHook, Ownable, Pausable {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // エラー定義
    error MustUseDynamicFee();
    error InsufficientObservations();
    error InsufficientBlockSpan();
    error PriceManipulationDetected();
    error CircuitBreakerTriggered();

    // プールごとの状態管理
    mapping(PoolId => ObservationLibrary.RingBuffer) public observations;
    mapping(PoolId => bool) public circuitBreakerTriggered;
    mapping(PoolId => uint256) public circuitBreakerActivatedAt;
    mapping(PoolId => uint256) public warmupUntil;

    // 設定パラメータ（USDC/JPYC = USD/JPY為替ペア向け最適化）
    // USDC/JPYCは実質的にドル円レートを反映するため、通常の為替ボラティリティ（0.5-1.5%/日）を想定
    uint256 public constant HISTORY_SIZE = 100;     // リングバッファの最大容量（ObservationLibrary.RingBuffer.data[100] と一致）
    uint24 public constant BASE_FEE = 300;          // 基本手数料 0.03% (300 = 0.03%) - 為替ペア標準
    uint24 public constant MAX_FEE = 5000;          // 最大手数料 0.5% (5000 = 0.5%) - 急変時保護
    uint256 public constant VOLATILITY_THRESHOLD = 500; // ボラティリティの閾値
    uint256 public constant MIN_UPDATE_INTERVAL = 10 minutes; // 観測記録の最小間隔（セキュリティ強化版）
    uint256 public constant MAX_PRICE_CHANGE_BPS = 5000; // 最大価格変動 50% (5000 = 50%)

    // セキュリティパラメータ
    uint256 public constant MIN_BLOCK_SPAN = 3;     // 最小ブロック数（フラッシュローン攻撃防止）
    uint256 public constant PRICE_CHANGE_LOOKBACK = 10; // 価格変動チェックの観測数
    uint256 public constant CIRCUIT_BREAKER_THRESHOLD = 1000; // サーキットブレーカー閾値 10% (1000 = 10%)
    uint256 public constant CIRCUIT_BREAKER_COOLDOWN = 1 hours; // サーキットブレーカー自動リセット時間
    uint256 public constant STALENESS_THRESHOLD = 30 minutes; // 観測データが古いと判断する閾値
    uint256 public constant WARMUP_DURATION = 30 minutes; // Staleness リセット後のウォームアップ期間

    // イベント定義
    event ObservationRecorded(
        PoolId indexed poolId,
        uint256 timestamp,
        uint160 sqrtPriceX96,
        uint256 observationCount
    );

    event PriceManipulationAttempt(
        PoolId indexed poolId,
        uint256 priceChange,
        uint256 blockSpan
    );

    event CircuitBreakerActivated(
        PoolId indexed poolId,
        uint256 priceChange,
        uint160 currentPrice,
        uint160 previousPrice,
        uint256 threshold
    );

    event CircuitBreakerReset(
        PoolId indexed poolId
    );

    event CircuitBreakerAutoReset(
        PoolId indexed poolId
    );

    event ObservationRingReset(
        PoolId indexed poolId,
        uint256 oldCount,
        uint256 stalenessThreshold
    );

    event DynamicFeeCalculated(
        PoolId indexed poolId,
        uint256 volatility,
        uint24 fee,
        uint256 observationCount,
        uint160 currentPrice
    );

    event WarmupPeriodStarted(
        PoolId indexed poolId,
        uint256 until,
        bytes32 reason
    );

    event WarmupPeriodEnded(
        PoolId indexed poolId
    );

    constructor(IPoolManager _poolManager, address initialOwner) BaseHook(_poolManager) Ownable(initialOwner) {}

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

        // 初期観測を追加
        ObservationLibrary.push(
            observations[poolId],
            block.timestamp,
            sqrtPriceX96
        );

        emit ObservationRecorded(poolId, block.timestamp, sqrtPriceX96, 1);

        return BaseHook.afterInitialize.selector;
    }

    /// @notice スワップ前の処理：動的手数料を設定
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    ) internal override whenNotPaused returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        // サーキットブレーカーチェック（自動リセット付き）
        if (circuitBreakerTriggered[poolId]) {
            // 自動リセット: クールダウン時間経過後に自動解除
            if (block.timestamp >= circuitBreakerActivatedAt[poolId] + CIRCUIT_BREAKER_COOLDOWN) {
                circuitBreakerTriggered[poolId] = false;
                emit CircuitBreakerAutoReset(poolId);
            } else {
                revert CircuitBreakerTriggered();
            }
        }

        // ウォームアップ期限切れの検出とイベント発行
        if (warmupUntil[poolId] != 0 && warmupUntil[poolId] <= block.timestamp) {
            emit WarmupPeriodEnded(poolId);
            warmupUntil[poolId] = 0;
        }

        // Staleness 検出: 観測データが古い場合はウォームアップを先行開始し BASE_FEE を返す
        // （_afterSwap でのリセットより前に、最初のスワップを保護する）
        ObservationLibrary.RingBuffer storage obsBeforeSwap = observations[poolId];
        if (obsBeforeSwap.count > 0 && warmupUntil[poolId] == 0
            && ObservationLibrary.isStale(obsBeforeSwap, STALENESS_THRESHOLD)) {
            warmupUntil[poolId] = block.timestamp + WARMUP_DURATION;
            emit WarmupPeriodStarted(poolId, warmupUntil[poolId], "staleness");
        }

        // ウォームアップ中は BASE_FEE のみを返す（staleness リセット後の保護）
        if (warmupUntil[poolId] > block.timestamp) {
            uint24 warmupFee = BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG;
            uint160 sqrtPriceX96Warmup = _getCurrentSqrtPriceX96(poolId);
            emit DynamicFeeCalculated(poolId, 0, BASE_FEE, obsBeforeSwap.count, sqrtPriceX96Warmup);
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, warmupFee);
        }

        // ボラティリティを計算
        uint256 volatility = _calculateVolatility(poolId);

        // ボラティリティに基づいて手数料を決定
        uint24 fee = _getFeeBasedOnVolatility(volatility);

        // イベント発行（監視とデバッグ用）
        ObservationLibrary.RingBuffer storage obsForEvent = observations[poolId];
        uint160 sqrtPriceX96ForEvent = _getCurrentSqrtPriceX96(poolId);
        emit DynamicFeeCalculated(poolId, volatility, fee, obsForEvent.count, sqrtPriceX96ForEvent);

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

        // 最小更新間隔チェック（10分）
        ObservationLibrary.RingBuffer storage obs = observations[poolId];
        if (obs.count > 0) {
            uint256 lastIndex = (obs.index + 99) % 100;
            uint256 lastTimestamp = obs.data[lastIndex].timestamp;
            if (block.timestamp < lastTimestamp + MIN_UPDATE_INTERVAL) {
                return (BaseHook.afterSwap.selector, 0);
            }
        }

        // 現在価格を取得
        uint160 sqrtPriceX96 = _getCurrentSqrtPriceX96(poolId);

        // Staleness チェック: 長期無取引後のリカバリ
        // 全観測が STALENESS_THRESHOLD (30分) より古い場合、リングをリセット
        if (ObservationLibrary.isStale(obs, STALENESS_THRESHOLD)) {
            uint256 oldCount = obs.count;
            ObservationLibrary.reset(obs);
            emit ObservationRingReset(poolId, oldCount, STALENESS_THRESHOLD);
            // リセット後は新しい観測を記録して終了（セキュリティチェックをスキップ）
            ObservationLibrary.push(obs, block.timestamp, sqrtPriceX96);
            emit ObservationRecorded(poolId, block.timestamp, sqrtPriceX96, obs.count);
            // ウォームアップ期間を開始（リセット後の手数料操作を防止）
            // M-2: _beforeSwap でまだ設定されていない場合のみ設定（二重イベント発行防止）
            if (warmupUntil[poolId] == 0) {
                warmupUntil[poolId] = block.timestamp + WARMUP_DURATION;
                emit WarmupPeriodStarted(poolId, warmupUntil[poolId], "ring_reset");
            }
            return (BaseHook.afterSwap.selector, 0);
        }

        // セキュリティチェック1: 複数ブロック検証
        if (obs.count >= MIN_BLOCK_SPAN) {
            bool isMultiBlock = ObservationLibrary.validateMultiBlock(obs, MIN_BLOCK_SPAN);
            if (!isMultiBlock) {
                emit PriceManipulationAttempt(poolId, 0, obs.count);
                // フラッシュローン攻撃の可能性、観測をスキップ
                return (BaseHook.afterSwap.selector, 0);
            }
        }

        // セキュリティチェック2: 新しい価格の変動をチェック（観測追加前）
        if (obs.count > 0) {
            uint256 lastIdx = obs.index == 0 ? 99 : obs.index - 1;
            uint160 lastPrice = obs.data[lastIdx].sqrtPriceX96;

            if (lastPrice > 0) {
                // 新しい価格と最後の価格の変動率を計算
                // FullMath.mulDiv を使ってオーバーフロー安全に計算
                uint256 currSqrt = uint256(sqrtPriceX96);
                uint256 prevSqrt = uint256(lastPrice);

                // price = sqrtPrice^2 なので、変動率 = |currPrice - prevPrice| / prevPrice
                //                                    = |currSqrt^2 - prevSqrt^2| / prevSqrt^2
                // 因数分解: = |(currSqrt + prevSqrt)(currSqrt - prevSqrt)| / prevSqrt^2
                // 段階的に除算: = ((currSqrt + prevSqrt) * diff / prevSqrt) * 10000 / prevSqrt
                // 両方の除算で切り上げ (mulDivRoundingUp) で保守的に評価
                uint256 priceChange;
                if (currSqrt > prevSqrt) {
                    uint256 diff = currSqrt - prevSqrt;
                    // (currSqrt + prevSqrt) * diff / prevSqrt (切り上げ)
                    uint256 temp = FullMath.mulDivRoundingUp(currSqrt + prevSqrt, diff, prevSqrt);
                    // temp * 10000 / prevSqrt (通常除算で過大評価を防ぐ)
                    priceChange = FullMath.mulDiv(temp, 10000, prevSqrt);
                } else {
                    uint256 diff = prevSqrt - currSqrt;
                    // (currSqrt + prevSqrt) * diff / prevSqrt (切り上げ)
                    uint256 temp = FullMath.mulDivRoundingUp(currSqrt + prevSqrt, diff, prevSqrt);
                    // temp * 10000 / prevSqrt (通常除算で過大評価を防ぐ)
                    priceChange = FullMath.mulDiv(temp, 10000, prevSqrt);
                }

                // 50%以上の変動を即座に拒否（最優先）
                if (priceChange > MAX_PRICE_CHANGE_BPS) {
                    emit PriceManipulationAttempt(poolId, priceChange, obs.count);
                    revert PriceManipulationDetected();
                }

                // 10%以上50%未満の変動でサーキットブレーカー
                if (priceChange > CIRCUIT_BREAKER_THRESHOLD && !circuitBreakerTriggered[poolId]) {
                    circuitBreakerTriggered[poolId] = true;
                    circuitBreakerActivatedAt[poolId] = block.timestamp;
                    // Get previous price from last observation
                    uint256 prevIdx = obs.index == 0 ? 99 : obs.index - 1;
                    uint160 previousPrice = obs.data[prevIdx].sqrtPriceX96;
                    emit CircuitBreakerActivated(poolId, priceChange, sqrtPriceX96, previousPrice, CIRCUIT_BREAKER_THRESHOLD);
                    // 異常価格（10-50%変動）は観測履歴に記録しない（ボラティリティ計算の汚染を防ぐ）
                    return (BaseHook.afterSwap.selector, 0);
                }
            }
        }

        // セキュリティチェックに合格したら観測を追加
        ObservationLibrary.push(obs, block.timestamp, sqrtPriceX96);
        emit ObservationRecorded(poolId, block.timestamp, sqrtPriceX96, obs.count);

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

        if (_countValidObservations(obs, count) < 2) {
            return 0;
        }

        (uint256 weightedVariation, uint256 totalWeight) = _accumulateWeightedVariation(obs, count);
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

    function _countValidObservations(ObservationLibrary.RingBuffer storage obs, uint256 count)
        internal
        view
        returns (uint256 validObservations)
    {
        for (uint256 i = 0; i < count; i++) {
            if (obs.data[i].sqrtPriceX96 > 0 && obs.data[i].timestamp > 0) {
                validObservations++;
            }
        }
    }

    function _accumulateWeightedVariation(ObservationLibrary.RingBuffer storage obs, uint256 count)
        internal
        view
        returns (uint256 weightedVariation, uint256 totalWeight)
    {
        uint256 currentIndex = _previousRingIndex(obs.index);

        for (uint256 i = 1; i < count; i++) {
            ObservationLibrary.Observation storage current = obs.data[currentIndex];
            uint256 prevIndex = _previousRingIndex(currentIndex);
            ObservationLibrary.Observation storage previous = obs.data[prevIndex];

            // previousSqrtPrice が 0 の場合はスキップしてゼロ除算を防ぐ
            if (previous.sqrtPriceX96 == 0 || current.timestamp <= previous.timestamp) {
                currentIndex = prevIndex;
                continue;
            }

            // 時間の重み: 最近の観測に指数関数的に高い重みを付与
            // recencyWeight = 2^(count - i) で最新ほど重くする
            uint256 recencyWeight = _recencyWeight(count, i);
            uint256 timeWeight = _timeWeight(current.timestamp - previous.timestamp);

            // 合成重み = recencyWeight * timeWeight
            uint256 weight = recencyWeight * timeWeight;
            uint256 variation = _variationBps(current.sqrtPriceX96, previous.sqrtPriceX96);

            // 時間重み付き変動を加算（オーバーフローチェック付き）
            uint256 weightedTerm = variation * weight;
            uint256 newWeightedVariation = weightedVariation + weightedTerm;
            if (newWeightedVariation < weightedVariation) {
                // オーバーフロー検出 → 最大値でキャップして終了
                weightedVariation = type(uint256).max / 2; // 除算を考慮して半分に
                totalWeight = totalWeight > 0 ? totalWeight : 1; // ゼロ除算防止
                break;
            }

            weightedVariation = newWeightedVariation;
            totalWeight += weight;
            currentIndex = prevIndex;
        }
    }

    function _variationBps(uint160 currentSqrtPriceX96, uint160 previousSqrtPriceX96)
        internal
        pure
        returns (uint256 variation)
    {
        // sqrtPriceX96を使って変動を計算（絶対値）
        // price = sqrtPrice^2 なので、変動率 = |currSqrt^2 - prevSqrt^2| / prevSqrt^2
        // FullMath を使用してオーバーフロー安全に計算（_afterSwap と同じ精度）
        uint256 curSqrt = uint256(currentSqrtPriceX96);
        uint256 prevSqrt = uint256(previousSqrtPriceX96);

        if (curSqrt > prevSqrt) {
            uint256 diff = curSqrt - prevSqrt;
            uint256 temp = FullMath.mulDiv(curSqrt + prevSqrt, diff, prevSqrt);
            variation = FullMath.mulDiv(temp, 10000, prevSqrt);
        } else {
            uint256 diff = prevSqrt - curSqrt;
            uint256 temp = FullMath.mulDiv(curSqrt + prevSqrt, diff, prevSqrt);
            variation = FullMath.mulDiv(temp, 10000, prevSqrt);
        }
    }

    function _recencyWeight(uint256 count, uint256 offsetFromLatest) internal pure returns (uint256) {
        uint256 exponent = count > offsetFromLatest + 10 ? 10 : count - offsetFromLatest - 1;
        return 1 << exponent;
    }

    function _timeWeight(uint256 timeDelta) internal pure returns (uint256) {
        // 時間重みに上限を設定（長時間の観測が支配的にならないよう）
        uint256 maxTimeWeight = 1 hours;
        uint256 clamped = timeDelta > maxTimeWeight ? maxTimeWeight : timeDelta;
        return clamped > 0 ? clamped : 1;
    }

    function _previousRingIndex(uint256 index) internal pure returns (uint256) {
        return index == 0 ? 99 : index - 1;
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

        // Safety-first: keep legacy rounding behavior to avoid unintended fee uplift
        // at specific volatility points. Any curve/rounding change must be treated
        // as a protocol-parameter change and accompanied by explicit test updates.
        // Internal callers currently provide 0..100, but clamp defensively.
        uint256 cappedVolatility = volatility > 100 ? 100 : volatility;

        // Quadratic curve:
        // fee = BASE_FEE + (MAX_FEE - BASE_FEE) * (volatility / 100)^2
        // Keep legacy two-step division to preserve previous effective outputs.
        uint256 normalizedSquared = (cappedVolatility * cappedVolatility) / 100;
        uint256 feeRange = uint256(MAX_FEE) - uint256(BASE_FEE);
        uint256 fee = uint256(BASE_FEE) + (feeRange * normalizedSquared) / 100;

        return fee > MAX_FEE ? MAX_FEE : uint24(fee);
    }

    function _getCurrentSqrtPriceX96(PoolId poolId) internal view returns (uint160 sqrtPriceX96) {
        // H-1 fix: Use StateLibrary.getSlot0() instead of raw extsload()
        // This avoids direct dependency on PoolManager's internal storage layout,
        // making the hook resilient to future v4-core upgrades.
        (sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolId);
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

    /// @notice Reset circuit breaker (owner only)
    /// @param poolId プールID
    function resetCircuitBreaker(PoolId poolId) external onlyOwner {
        circuitBreakerTriggered[poolId] = false;
        emit CircuitBreakerReset(poolId);
    }

    /// @notice Check if circuit breaker is triggered
    /// @param poolId プールID
    /// @return isTriggered サーキットブレーカーが発動している場合true
    function isCircuitBreakerTriggered(PoolId poolId) external view returns (bool) {
        return circuitBreakerTriggered[poolId];
    }

    /// @notice Pause all swap operations (owner only)
    /// @dev Emergency stop mechanism
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause all swap operations (owner only)
    function unpause() external onlyOwner {
        _unpause();
    }
}
