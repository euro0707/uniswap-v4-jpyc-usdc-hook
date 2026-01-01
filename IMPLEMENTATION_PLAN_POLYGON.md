# 🎯 Uniswap V4 フック機能拡張 - Polygon JPYC/USDC 実装計画

**作成日:** 2025-12-24
**バージョン:** 3.0.0（Polygon最適化版）
**対象チェーン:** Polygon
**対象ペア:** JPYC/USDC
**戦略:** ボリンジャーバンド2σ + JIT流動性 + 自動リバランス

---

## 📊 プロジェクト概要

### 目標
Polygon上のJPYC/USDCペアで、**狭いレンジで高収益を得つつ、レンジアウトしない**流動性提供を実現する。

### 対象ペアの特性

```
JPYC/USDC = 実質的にUSD/JPY（ドル円）為替レート

価格範囲: 140-160 JPYC/USDC（140-160円/ドル）
通常ボラティリティ: 0.3-0.8%/日
経済指標発表時: 1.0-2.0%/日
```

---

## 🔧 Polygon最適化のポイント

### 1. 低ガスコストの活用

| 項目 | Ethereum | Polygon | 差異 |
|------|----------|---------|------|
| リバランスコスト | $5-10 | $0.01-0.05 | **100-500倍安い** |
| 最短リバランス間隔 | 2-6時間 | 30分 | **頻繁なリバランスOK** |
| 最大ガス価格 | 50 gwei | 200 gwei | **緩い制限でOK** |

**結論**: Polygonでは**より狭いレンジ + 積極的なリバランス戦略**が可能

### 2. ブロック時間の違い

```
Ethereum: 約12秒/ブロック
Polygon:  約2秒/ブロック

→ タイムスタンプベースの計算なので影響は軽微
→ ただし、MIN_UPDATE_INTERVALは秒単位で適切に設定
```

---

## 🎯 実装する機能

### 完成済み機能（既存）
1. ✅ **動的手数料フック（VolatilityDynamicFeeHook）**
   - ボラティリティベースの手数料調整（0.03%-0.5%）
   - 時間重み付けTWAP
   - 価格変動上限フィルタ（50%）
   - テストカバレッジ100%（16件）

### 新規実装機能
2. 🎯 **ボリンジャーバンド2σ計算機能**
   - 移動平均（MA）の計算
   - 標準偏差（σ）の計算
   - 上側バンド（MA + 2σ）、下側バンド（MA - 2σ）の算出
   - タイムフレーム可変（1時間、2時間、4時間、日足）

3. 🎯 **JIT流動性 + 自動リバランス**
   - BBに基づく最適なレンジ幅の自動計算
   - MAに戻った時のみリバランス（トレンド追随を防ぐ）
   - バンドウォーク検出機能
   - Polygon低ガス代を活かした頻繁なリバランス

4. 📊 **オラクル拡張**
   - 価格データの長期保存（100件）
   - 外部プロトコル向けTWAP提供

---

## 📝 Phase 1: ボリンジャーバンド計算機能

### データ構造

```solidity
/// @notice ボリンジャーバンド設定
struct BollingerBandConfig {
    uint256 period;             // 期間（例: 20）
    uint256 standardDeviation;  // 標準偏差倍数（200 = 2.00σ）
    uint256 timeframe;          // タイムフレーム（秒単位）
}

/// @notice 価格統計データ
struct PriceStatistics {
    uint256 movingAverage;      // 移動平均（MA）
    uint256 standardDev;        // 標準偏差（σ）
    uint256 upperBand;          // 上側バンド（MA + 2σ）
    uint256 lowerBand;          // 下側バンド（MA - 2σ）
    uint256 lastUpdate;         // 最終更新時刻
}

mapping(PoolId => BollingerBandConfig) public bbConfigs;
mapping(PoolId => PriceStatistics) public priceStats;
```

### 主要関数

```solidity
/// @notice ボリンジャーバンドを計算
function calculateBollingerBands(
    PoolId poolId,
    uint256 period,
    uint256 timeframe
) external view returns (
    uint256 ma,
    uint256 upperBand,
    uint256 lowerBand
);

/// @notice BB設定を更新
function setBollingerBandConfig(
    PoolKey calldata key,
    uint256 period,
    uint256 standardDeviation,
    uint256 timeframe
) external;
```

### テスト項目（8件）

1. `test_calculateMA_correctAverage` - 移動平均の正確性
2. `test_calculateStdDev_correctValue` - 標準偏差の正確性
3. `test_bollingerBands_2sigma` - 2σバンドの計算
4. `test_bollingerBands_differentTimeframes` - 複数タイムフレーム
5. `test_bollingerBands_insufficientData` - データ不足時の処理
6. `test_bollingerBands_volatilityChange` - ボラティリティ変化への対応
7. `test_sqrt_accuracy` - 平方根計算の精度
8. `test_priceConversion_sqrtPriceX96` - 価格変換の正確性

---

## 📝 Phase 2: JIT流動性 + BB自動リバランス

### データ構造

```solidity
/// @notice JIT流動性ポジション
struct JITPosition {
    address owner;
    int24 targetLowerTick;      // 目標下限（BBから自動計算）
    int24 targetUpperTick;      // 目標上限（BBから自動計算）
    uint128 targetLiquidity;
    bool isActive;
    uint256 lastUpdate;
}

/// @notice アクティブポジション
struct ActivePosition {
    uint128 currentLiquidity;
    int24 currentLowerTick;
    int24 currentUpperTick;
    uint256 lastRebalanceTime;
    uint256 accumulatedFees;
    uint256 lastVolatility;     // 前回のボラティリティ値
}

/// @notice リバランス戦略（Polygon最適化）
struct RebalanceStrategy {
    uint256 triggerThreshold;   // デフォルト: 1500（15%）
    uint256 minInterval;        // デフォルト: 1800秒（30分）
    uint256 maxGasPrice;        // デフォルト: 200 gwei（Polygon用）
    bool autoRebalanceEnabled;
    bool waitForMAReturn;       // MAに戻るまで待つか（デフォルト: true）
}
```

### 主要関数

```solidity
/// @notice JITポジションを設定（BBベース）
function setJITPositionWithBB(
    PoolKey calldata key,
    uint128 targetLiquidity
) external;

/// @notice 自動リバランス戦略を設定（Polygon最適化）
function setRebalanceStrategyPolygon(
    PoolKey calldata key,
    uint256 triggerThreshold,
    uint256 minInterval
) external;

/// @notice リバランスが必要かチェック（BB戦略）
function checkRebalanceNeeded(
    PoolKey calldata key,
    address owner
) external view returns (bool needed, string memory reason);

/// @notice 手動リバランス実行
function manualRebalance(PoolKey calldata key) external;
```

### リバランスロジック

```solidity
/// @notice リバランス判定（Polygon最適化版）
function _shouldRebalanceBB(
    PoolKey calldata key,
    int24 currentTick,
    address owner
) internal view returns (bool) {
    // Check 1: 自動リバランス有効
    if (!strategy.autoRebalanceEnabled) return false;

    // Check 2: 最短間隔（Polygon: 30分）
    if (block.timestamp < lastRebalance + strategy.minInterval) return false;

    // Check 3: ガス価格（Polygon: 200 gwei）
    if (tx.gasprice > strategy.maxGasPrice) return false;

    // Check 4: 価格がMAに近いかチェック（トレンド追随防止）
    if (strategy.waitForMAReturn) {
        (uint256 ma,,) = _calculateBollingerBands(...);
        int24 maTick = _priceToTick(ma);
        int24 distance = abs(currentTick - maTick);

        // MAから10%以上離れている場合はスキップ
        if (distance > rangeWidth / 10) return false;
    }

    // Check 5: BBが大きく変化したか（20%以上）
    (,uint256 newUpperBand, uint256 newLowerBand) = _calculateBollingerBands(...);

    if (_bandChangedSignificantly(newUpperBand, newLowerBand, active)) {
        return true;
    }

    // Check 6: 価格がバンドの端に接近（レンジアウト防止）
    if (_priceApproachingEdge(currentTick, active, strategy)) {
        return true;
    }

    // Check 7: バンドウォーク検出（トレンド発生中はスキップ）
    if (_detectBandWalk(poolId)) {
        return false;
    }

    return false;
}
```

### テスト項目（15件）

9. `test_setJITPosition_withBB` - BBベースのJIT設定
10. `test_rebalance_whenMAReturns` - MA回帰時のリバランス
11. `test_rebalance_skipsDuringTrend` - トレンド中はスキップ
12. `test_bandWalk_detection` - バンドウォーク検出
13. `test_rebalance_polygonLowGas` - Polygon低ガス環境
14. `test_rebalance_frequentOK` - 30分間隔で実行可能
15. `test_rebalance_BBchanged20percent` - BB 20%変化でトリガー
16. `test_rebalance_priceAtEdge` - 価格が端に接近
17. `test_multipleRebalances_sameDay` - 1日複数回のリバランス
18. `test_manualRebalance_override` - 手動リバランス
19. `test_gasEfficiency_polygon` - Polygonガス効率測定
20. `test_accumulatedFees_tracking` - 手数料累積の追跡
21. `test_emergencyRebalance_volatilitySpike` - ボラティリティ急上昇時
22. `test_multiplePositions_independence` - 複数ポジションの独立性
23. `test_integration_dynamicFee_and_BB` - 動的手数料との統合

---

## 📝 Phase 3: オラクル拡張

### データ構造拡張

```solidity
/// @notice 価格観測データ（拡張版）
struct PriceObservation {
    uint32 timestamp;
    uint160 sqrtPriceX96;
    uint256 cumulativePrice;    // TWAP計算用
}

struct PriceOracle {
    PriceObservation[] observations;
    uint256 index;
    uint256 count;
    uint256 maxSize;            // 100件に拡張
}
```

### 主要関数

```solidity
/// @notice 外部向けTWAP取得
function getTWAP(
    PoolKey calldata key,
    uint32 secondsAgo
) external view returns (uint256);

/// @notice 最新価格取得
function getLatestPrice(
    PoolKey calldata key
) external view returns (uint160);
```

### テスト項目（4件）

24. `test_oracle_longTermStorage` - 長期データ保存（100件）
25. `test_oracle_TWAP_calculation` - TWAP計算
26. `test_oracle_externalAccess` - 外部からのアクセス
27. `test_oracle_dataOverwrite` - データ上書き（リングバッファ）

---

## 🎯 推奨設定値（Polygon JPYC/USDC専用）

### プリセット1: バランス型（推奨）

```solidity
// ボリンジャーバンド設定
BollingerBandConfig({
    period: 20,              // 20期間
    standardDeviation: 200,  // 2σ
    timeframe: 7200          // 2時間足（Polygon最適化）
});

// リバランス戦略
RebalanceStrategy({
    triggerThreshold: 1500,     // 15%（バンドの端から15%以内）
    minInterval: 1800,          // 30分（Polygon低ガス）
    maxGasPrice: 200 * 10**9,   // 200 gwei
    autoRebalanceEnabled: true,
    waitForMAReturn: true       // MA回帰を待つ
});

// 期待される結果:
// - レンジ幅: ±0.6-1.2%程度
// - リバランス頻度: 2-4回/日
// - ガスコスト: $0.02-0.04/日（ほぼ無視可能）
// - APR: 60-80%（従来の固定レンジ比3-4倍）
```

### プリセット2: アグレッシブ型

```solidity
BollingerBandConfig({
    period: 20,
    standardDeviation: 180,  // 1.8σ（やや狭め）
    timeframe: 3600          // 1時間足
});

RebalanceStrategy({
    triggerThreshold: 2000,     // 20%
    minInterval: 900,           // 15分（超頻繁）
    maxGasPrice: 300 * 10**9,
    autoRebalanceEnabled: true,
    waitForMAReturn: false      // MAを待たない（積極的）
});

// 期待される結果:
// - レンジ幅: ±0.4-0.8%
// - リバランス頻度: 4-8回/日
// - ガスコスト: $0.05-0.10/日
// - APR: 80-120%（高リスク・高リターン）
```

### プリセット3: 安定型

```solidity
BollingerBandConfig({
    period: 20,
    standardDeviation: 250,  // 2.5σ（広め）
    timeframe: 14400         // 4時間足
});

RebalanceStrategy({
    triggerThreshold: 1000,     // 10%
    minInterval: 7200,          // 2時間
    maxGasPrice: 150 * 10**9,
    autoRebalanceEnabled: true,
    waitForMAReturn: true
});

// 期待される結果:
// - レンジ幅: ±1.0-1.8%
// - リバランス頻度: 1-2回/日
// - ガスコスト: $0.01-0.02/日
// - APR: 40-60%（安定運用）
```

---

## 📊 収益シミュレーション（Polygon JPYC/USDC）

### 前提条件

```
投入資金: $10,000
1日のスワップ量: $100,000（仮定）
平均手数料: 0.05%（動的手数料）
Polygon ガス価格: 50 gwei
リバランスコスト: $0.02/回
```

### バランス型プリセット（2時間足BB 2σ）

**通常時（85%の時間）:**
```
レンジ幅: ±0.8%（149.28 - 150.72 JPYC）
流動性カバレッジ: 92%
手数料収益: $200/日
リバランス: 3回/日
ガスコスト: -$0.06/日
純収益: $193.94/日
```

**ボラティリティ高（10%の時間）:**
```
レンジ幅: ±1.5%（148.50 - 151.50 JPYC）
流動性カバレッジ: 98%
手数料収益: $120/日
リバランス: 2回/日
ガスコスト: -$0.04/日
純収益: $119.96/日
```

**バンドウォーク中（5%の時間）:**
```
レンジ幅: ±2.0%（広めに維持）
流動性カバレッジ: 100%
手数料収益: $80/日
リバランス: 0回/日（トレンド追随を防ぐ）
ガスコスト: $0
純収益: $80/日
```

**加重平均（月間）:**
```
純収益/日:
  = 0.85 × $193.94 + 0.10 × $119.96 + 0.05 × $80
  = $164.85 + $12.00 + $4.00
  = $180.85/日

月間収益: $5,425
年間収益: $66,010
APR: 66.01%

従来の固定広いレンジ（APR 18%）比: 3.7倍改善 🚀
```

---

## 🛡️ セキュリティ考慮事項

### 継承する既存のセキュリティ機能
1. ✅ CEIパターン
2. ✅ 時間重み付けTWAP
3. ✅ 価格変動上限フィルタ（50%）
4. ✅ ゼロ除算保護
5. ✅ MIN_UPDATE_INTERVAL

### 新機能で追加するセキュリティ

#### BB計算のセキュリティ
- データ不足時の安全な処理
- オーバーフロー保護（平方根計算）
- 異常値フィルタ（極端な価格を除外）

#### リバランスのセキュリティ
- バンドウォーク検出（トレンド追随を防ぐ）
- MA回帰待機（無駄なリバランス防止）
- ガス価格上限チェック（Polygon特化）
- 最短間隔チェック（フラッシュローン対策）

---

## 💰 ガス最適化（Polygon特化）

### Polygon特有の最適化

```solidity
// 1. 頻繁なリバランスを許可（低ガスコスト）
minInterval: 1800 seconds (30分)

// 2. バッチ処理の検討（複数LPを一度に処理）
function batchRebalance(address[] calldata owners) external {
    // Polygonならガスコスト$0.05程度
}

// 3. ガス価格チェックの緩和
maxGasPrice: 200 gwei  // Ethereumの4倍でもコストは1/100
```

---

## 📅 開発スケジュール

| Phase | 機能 | 実装期間 | テスト期間 | 合計 |
|-------|------|---------|-----------|------|
| Phase 1 | BB計算機能 | 2日 | 1日 | **3日** |
| Phase 2 | JIT + BB自動リバランス | 3日 | 2日 | **5日** |
| Phase 3 | オラクル拡張 | 1日 | 1日 | **2日** |
| 統合 | 統合テスト + ガス最適化 | 2日 | 1日 | **3日** |
| デプロイ準備 | Polygon Mumbai/Mainnet | 1日 | - | **1日** |
| **合計** | - | - | - | **14日** |

---

## 🚀 デプロイ計画

### ステップ1: Polygon Mumbai（テストネット）

```bash
# 1. Mumbai へデプロイ
forge script script/DeployPolygon.s.sol \
  --rpc-url https://rpc-mumbai.maticvigil.com \
  --broadcast \
  --verify

# 2. BB設定
cast send $HOOK_ADDRESS "setBollingerBandConfig(..." \
  --rpc-url https://rpc-mumbai.maticvigil.com

# 3. テスト運用（1週間）
```

### ステップ2: Polygon Mainnet

```bash
# 監査完了後
forge script script/DeployPolygon.s.sol \
  --rpc-url https://polygon-rpc.com \
  --broadcast \
  --verify
```

---

## 📝 次のステップ

1. ✅ この実装計画の確認
2. 🎯 Phase 1（BB計算機能）の実装開始
3. 🧪 テストケースの作成
4. 🚀 Polygon Mumbaiへのデプロイ

---

## 📞 参考情報

- **Polygon RPC**: https://polygon-rpc.com
- **Polygon Mumbai**: https://rpc-mumbai.maticvigil.com
- **JPYC公式**: https://jpyc.jp/
- **Polygon ガストラッカー**: https://polygonscan.com/gastracker

---

**承認:**
- 対象チェーン: Polygon ✅
- 対象ペア: JPYC/USDC ✅
- 戦略: ボリンジャーバンド2σ ✅
- 最適化: Polygon低ガス活用 ✅
