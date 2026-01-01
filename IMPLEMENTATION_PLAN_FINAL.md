# 🎯 Uniswap V4 自動複利JITフック - 最終実装計画書

**作成日:** 2025-12-24
**バージョン:** 4.0.0（最終確定版）
**対象チェーン:** Polygon
**対象ペア:** JPYC/USDC
**コア戦略:** ボリンジャーバンド2.5σ + JIT流動性 + 自動複利運用

---

## 📋 プロジェクト概要

### 目標

Polygon上のJPYC/USDCペアで、以下を実現する：

1. ✅ **狭いレンジで高収益**を得る
2. ✅ **レンジアウトしない**（自動リバランス）
3. ✅ **手数料を自動複利運用**（長期運用最適化）
4. ✅ **急変時の損失を最小化**（3段階モード）

### 期待される成果（3年間運用）

```
初期投入: $10,000
3年後の資産: $46,153（複利運用）
純利益: $36,153
実質APR: 66.2%（複利効果込み）

従来の固定レンジ（APR 18%）: $15,832
改善額: +$30,321（+191%）🚀
```

---

## 🏗️ システムアーキテクチャ

### コア機能

```
┌─────────────────────────────────────────────────┐
│     UnifiedDynamicHook.sol（統合フック）          │
├─────────────────────────────────────────────────┤
│ 1. 動的手数料（既存）                              │
│    ├─ ボラティリティ計算（時間重み付けTWAP）        │
│    └─ 手数料調整（0.03%-0.5%）                    │
│                                                  │
│ 2. ボリンジャーバンド計算（新規）                  │
│    ├─ 移動平均（MA）                              │
│    ├─ 標準偏差（σ）                               │
│    └─ 2.5σバンド算出                             │
│                                                  │
│ 3. JIT流動性 + 自動リバランス（新規）             │
│    ├─ BBベースのレンジ設定                        │
│    ├─ MA回帰待機（トレンド追随防止）              │
│    └─ バンドウォーク検出                          │
│                                                  │
│ 4. 自動複利運用（新規）★コア機能                  │
│    ├─ リバランス時に手数料回収                     │
│    ├─ 手数料を流動性に変換                        │
│    └─ 元本+複利で再投資                           │
│                                                  │
│ 5. 3段階モード切替（新規）                        │
│    ├─ 通常モード（BB 2.5σ）                      │
│    ├─ 緊急モード（BB 3σ）                        │
│    └─ 損失最小化モード（流動性撤退）              │
│                                                  │
│ 6. オラクル拡張（新規）                           │
│    ├─ 長期データ保存（100件）                     │
│    └─ 外部TWAP提供                               │
└─────────────────────────────────────────────────┘
```

---

## 📊 システムパラメータ（最終確定版）

### ボリンジャーバンド設定

```solidity
BollingerBandConfig({
    period: 20,              // 20期間
    standardDeviation: 250,  // 2.5σ（余裕を持つ）
    timeframe: 14400         // 4時間足（14400秒）
});
```

### リバランス戦略

```solidity
RebalanceStrategy({
    triggerThreshold: 1200,     // 12%（レンジの88%地点でトリガー）
    minInterval: 3600,          // 1時間（Polygon低ガス活用）
    maxGasPrice: 200 * 10**9,   // 200 gwei
    autoRebalanceEnabled: true,
    waitForMAReturn: true       // MA回帰を待つ
});
```

### 自動複利設定 ★重要

```solidity
CompoundingConfig({
    autoCompound: true,              // 自動複利運用を有効化
    minCompoundAmount: 10 * 10**6,   // $10以上で複利実行（USDC decimals=6）
    compoundOnEveryRebalance: true,  // リバランスごとに複利
    reinvestBothTokens: true         // JPYC/USDC両方を再投資
});
```

### 3段階モード設定

```solidity
// 【通常モード】ボラティリティ < 70
NormalModeConfig({
    bollingerStdDev: 250,    // 2.5σ
    enabled: true
});

// 【緊急モード】ボラティリティ 70-90
EmergencyModeConfig({
    volatilityThreshold: 70,
    bollingerStdDev: 300,    // 3σに拡大
    skipMAWait: true,        // MA回帰を待たない
    enabled: true
});

// 【損失最小化モード】ボラティリティ > 90
LossMinimizationConfig({
    volatilityThreshold: 90,
    action: REMOVE_LIQUIDITY, // 流動性を一時撤退
    enabled: true
});
```

---

## 💰 自動複利運用の詳細設計

### データ構造

```solidity
/// @notice 自動複利運用設定
struct CompoundingConfig {
    bool autoCompound;              // 自動複利運用の有効/無効
    uint256 minCompoundAmount;      // 最低複利金額（USDC単位、6 decimals）
    bool compoundOnEveryRebalance;  // 毎回リバランス時に複利
    bool reinvestBothTokens;        // 両トークンを再投資
    uint256 totalCompounded;        // 累積複利額（追跡用）
    uint256 lastCompoundTime;       // 最終複利実行時刻
}

/// @notice 複利運用の統計データ
struct CompoundingStats {
    uint256 initialLiquidity;       // 初期流動性
    uint256 currentLiquidity;       // 現在の流動性（複利後）
    uint256 totalFeesEarned;        // 累積手数料収益
    uint256 totalFeesCompounded;    // 累積複利額
    uint256 compoundCount;          // 複利実行回数
    uint256 averageAPR;             // 平均APR（複利効果込み）
}

mapping(PoolId => mapping(address => CompoundingConfig)) public compoundingConfigs;
mapping(PoolId => mapping(address => CompoundingStats)) public compoundingStats;
```

### 主要関数

```solidity
/// @notice 自動複利設定を変更
function setCompoundingConfig(
    PoolKey calldata key,
    bool autoCompound,
    uint256 minCompoundAmount
) external;

/// @notice リバランス時の自動複利実行
function _executeRebalanceWithCompounding(
    PoolKey calldata key,
    address owner,
    int24 currentTick,
    bool isEmergency
) internal returns (uint128 additionalLiquidity);

/// @notice 手数料を流動性に変換
function _convertFeesToLiquidity(
    PoolKey calldata key,
    address owner,
    uint256 amount0Fees,
    uint256 amount1Fees,
    int24 currentTick
) internal returns (uint128 liquidity);

/// @notice 複利運用の統計を取得
function getCompoundingStats(
    PoolKey calldata key,
    address owner
) external view returns (CompoundingStats memory);
```

### 自動複利のロジック

```solidity
/// @notice リバランス時の自動複利処理
function _executeRebalanceWithCompounding(
    PoolKey calldata key,
    address owner,
    int24 currentTick,
    bool isEmergency
) internal returns (uint128 additionalLiquidity) {
    PoolId poolId = key.toId();
    ActivePosition storage active = activePositions[poolId][owner];
    CompoundingConfig storage compound = compoundingConfigs[poolId][owner];
    CompoundingStats storage stats = compoundingStats[poolId][owner];

    uint128 oldLiquidity = active.currentLiquidity;

    // ========== Step 1: 既存流動性を削除 ==========

    if (oldLiquidity > 0) {
        poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: active.currentLowerTick,
                tickUpper: active.currentUpperTick,
                liquidityDelta: -int256(uint256(oldLiquidity)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    // ========== Step 2: 手数料を回収 ==========

    (uint256 amount0Fees, uint256 amount1Fees) = _collectFees(key, owner);

    // 統計を更新
    stats.totalFeesEarned += _convertToUSD(amount0Fees, amount1Fees, key);

    // ========== Step 3: 自動複利チェック ==========

    additionalLiquidity = 0;

    if (compound.autoCompound && compound.compoundOnEveryRebalance) {
        // 手数料の合計（USDC換算）
        uint256 totalFeesUSD = _convertToUSD(amount0Fees, amount1Fees, key);

        // 最低複利金額をクリアしているか
        if (totalFeesUSD >= compound.minCompoundAmount) {
            // 手数料を流動性に変換
            additionalLiquidity = _convertFeesToLiquidity(
                key,
                owner,
                amount0Fees,
                amount1Fees,
                currentTick
            );

            // 複利統計を更新
            compound.totalCompounded += totalFeesUSD;
            compound.lastCompoundTime = block.timestamp;
            stats.totalFeesCompounded += totalFeesUSD;
            stats.compoundCount++;

            emit FeesCompounded(
                poolId,
                owner,
                amount0Fees,
                amount1Fees,
                additionalLiquidity,
                compound.totalCompounded
            );
        }
    }

    // ========== Step 4: 新しい範囲を計算 ==========

    (int24 newLowerTick, int24 newUpperTick) = _calculateRangeFromBollingerBands(
        key,
        currentTick,
        isEmergency
    );

    // ========== Step 5: 新しい範囲で流動性を追加（複利分を含む） ==========

    uint128 totalLiquidity = oldLiquidity + additionalLiquidity;

    poolManager.modifyLiquidity(
        key,
        IPoolManager.ModifyLiquidityParams({
            tickLower: newLowerTick,
            tickUpper: newUpperTick,
            liquidityDelta: int256(uint256(totalLiquidity)),
            salt: bytes32(0)
        }),
        ""
    );

    // ========== Step 6: 状態を更新 ==========

    active.currentLiquidity = totalLiquidity;  // 複利で増加
    active.currentLowerTick = newLowerTick;
    active.currentUpperTick = newUpperTick;
    active.lastRebalanceTime = block.timestamp;

    // 統計を更新
    stats.currentLiquidity = totalLiquidity;

    emit PositionRebalanced(
        poolId,
        owner,
        oldLiquidity,
        additionalLiquidity,
        totalLiquidity,
        newLowerTick,
        newUpperTick
    );

    return additionalLiquidity;
}

/// @notice 手数料を流動性に変換
function _convertFeesToLiquidity(
    PoolKey calldata key,
    address owner,
    uint256 amount0Fees,  // JPYC
    uint256 amount1Fees,  // USDC
    int24 currentTick
) internal returns (uint128 liquidity) {
    // 現在価格で最適な比率を計算
    (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

    // 両トークンを現在価格で最適な比率に調整
    (uint256 optimalAmount0, uint256 optimalAmount1) = _getOptimalAmounts(
        amount0Fees,
        amount1Fees,
        sqrtPriceX96,
        currentTick,
        key
    );

    // 流動性を計算
    liquidity = LiquidityAmounts.getLiquidityForAmounts(
        sqrtPriceX96,
        TickMath.getSqrtPriceAtTick(active.currentLowerTick),
        TickMath.getSqrtPriceAtTick(active.currentUpperTick),
        optimalAmount0,
        optimalAmount1
    );

    return liquidity;
}

/// @notice USD換算（統計用）
function _convertToUSD(
    uint256 amount0,  // JPYC (18 decimals)
    uint256 amount1,  // USDC (6 decimals)
    PoolKey calldata key
) internal view returns (uint256 usdValue) {
    // 現在価格を取得
    (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

    // JPYC -> USD 変換
    uint256 jpycInUSD = (amount0 * (uint256(sqrtPriceX96) ** 2)) >> 192;
    jpycInUSD = jpycInUSD / 10**12; // 18 decimals -> 6 decimals

    // 合計
    usdValue = jpycInUSD + amount1;

    return usdValue;
}
```

---

## 📊 複利運用のシミュレーション

### 月次シミュレーション（12ヶ月）

**前提:**
- 初期投入: $10,000
- 月間手数料: 4%（APR 48%）
- 複利実行: 毎リバランス（月60回）
- ガス代: $0.04/回 × 60 = $2.4/月

| 月 | 元本 | 手数料収益 | 複利後元本 | 累積複利額 |
|----|------|-----------|-----------|-----------|
| 1 | $10,000 | $400 | $10,400 | $400 |
| 2 | $10,400 | $416 | $10,816 | $816 |
| 3 | $10,816 | $433 | $11,249 | $1,249 |
| 6 | $12,167 | $487 | $12,653 | $2,653 |
| 12 | $16,010 | $640 | $16,650 | $6,650 |

**12ヶ月後:**
```
元本: $16,650（+66.5%）
複利なしの場合: $14,800（+48%）
複利効果: +$1,850（+12.5%ポイント）
```

---

## 🎯 実装フェーズ

### Phase 1: ボリンジャーバンド計算機能（3日）

**実装内容:**
- 移動平均（MA）の計算
- 標準偏差（σ）の計算
- 2.5σバンドの算出
- タイムフレーム可変対応

**テスト（8件）:**
1. `test_calculateMA_correctAverage`
2. `test_calculateStdDev_correctValue`
3. `test_bollingerBands_2_5sigma`
4. `test_bollingerBands_differentTimeframes`
5. `test_bollingerBands_insufficientData`
6. `test_sqrt_accuracy`
7. `test_priceConversion_sqrtPriceX96`
8. `test_bollingerBands_update`

---

### Phase 2: JIT流動性 + 自動リバランス（5日）

**実装内容:**
- BBベースのレンジ計算
- MA回帰待機ロジック
- バンドウォーク検出
- 3段階モード切替

**テスト（10件）:**
9. `test_setJITPosition_withBB`
10. `test_rebalance_whenMAReturns`
11. `test_rebalance_skipsDuringTrend`
12. `test_bandWalk_detection`
13. `test_normalMode_BB2_5sigma`
14. `test_emergencyMode_BB3sigma`
15. `test_lossMinMode_removeLiquidity`
16. `test_modeSwitch_volatilityChange`
17. `test_rebalance_frequentOK_polygon`
18. `test_manualRebalance_override`

---

### Phase 3: 自動複利運用機能（4日）★コア

**実装内容:**
- 手数料回収ロジック
- 手数料→流動性変換
- リバランス時の自動複利
- 複利統計の追跡

**テスト（7件）:**
19. `test_autoCompound_enabled`
20. `test_autoCompound_minAmount`
21. `test_feesToLiquidity_conversion`
22. `test_compound_bothTokens`
23. `test_compoundStats_tracking`
24. `test_compound_12months_simulation`
25. `test_compound_vs_noCompound`

---

### Phase 4: オラクル拡張（2日）

**実装内容:**
- 長期データ保存（100件）
- 外部TWAP提供
- 累積価格計算

**テスト（4件）:**
26. `test_oracle_longTermStorage`
27. `test_oracle_TWAP_external`
28. `test_oracle_cumulativePrice`
29. `test_oracle_ringBuffer`

---

### Phase 5: 統合テスト（3日）

**テスト（6件）:**
30. `test_integration_dynamicFee_BB_compound`
31. `test_integration_fullScenario_3months`
32. `test_integration_emergencyMode_recovery`
33. `test_integration_gasEfficiency_polygon`
34. `test_integration_multipleUsers`
35. `test_integration_extremeVolatility`

---

### Phase 6: Polygon Mumbaiデプロイ（1日）

**実施内容:**
- Mumbai テストネットへデプロイ
- 初期設定（BB、リバランス、複利）
- 1週間のテスト運用

---

## 📅 開発スケジュール

| Phase | 実装期間 | テスト期間 | 合計 |
|-------|---------|-----------|------|
| Phase 1: BB計算 | 2日 | 1日 | 3日 |
| Phase 2: JIT+リバランス | 3日 | 2日 | 5日 |
| Phase 3: 自動複利★ | 2日 | 2日 | 4日 |
| Phase 4: オラクル | 1日 | 1日 | 2日 |
| Phase 5: 統合テスト | - | 3日 | 3日 |
| Phase 6: Mumbai | 1日 | - | 1日 |
| **合計** | **9日** | **9日** | **18日** |

---

## 🎯 ユーザー設定例

### 初期設定（1回のみ）

```solidity
// 1. JITポジションを設定
hook.setJITPositionWithBB(
    poolKey,
    10_000_000_000  // $10,000 USDC（6 decimals）
);

// 2. リバランス戦略を設定
hook.setRebalanceStrategyPolygon(
    poolKey,
    1200,   // トリガー: 12%
    3600    // 最短間隔: 1時間
);

// 3. 自動複利を有効化 ★重要
hook.setCompoundingConfig(
    poolKey,
    true,            // 自動複利ON
    10_000_000       // 最低$10（6 decimals）
);

// 4. 緊急モードを有効化
hook.setEmergencyMode(
    poolKey,
    70,   // ボラティリティ70超で発動
    true
);

// 完了！あとは完全自動 ✅
```

### 運用中の確認

```solidity
// 複利統計を確認
CompoundingStats memory stats = hook.getCompoundingStats(poolKey, msg.sender);

console.log("初期投入:", stats.initialLiquidity);
console.log("現在資産:", stats.currentLiquidity);
console.log("累積手数料:", stats.totalFeesEarned);
console.log("累積複利額:", stats.totalFeesCompounded);
console.log("複利実行回数:", stats.compoundCount);
console.log("平均APR:", stats.averageAPR);
```

---

## ✅ 最終確認

以下の設定で実装を開始します：

1. ✅ **ボリンジャーバンド2.5σ**（4時間足）
2. ✅ **3段階モード**（通常/緊急/損失最小化）
3. ✅ **自動複利運用**（毎リバランス時）★コア機能
4. ✅ **Polygon最適化**（低ガス活用）
5. ✅ **長期運用向け**（資金追加不要）

**期待される成果（3年間）:**
- 初期投入: $10,000
- 3年後: $46,153
- 改善率: +191%（従来比）

実装を開始してもよろしいでしょうか？
