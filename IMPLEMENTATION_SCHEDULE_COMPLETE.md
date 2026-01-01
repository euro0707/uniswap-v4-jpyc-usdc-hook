# 📅 完全版実装スケジュール

**プロジェクト:** Uniswap V4 自動複利JITフック
**最終更新:** 2025-12-24
**総期間:** 26日間

---

## 📊 フェーズ一覧

| Phase | 機能 | 実装 | テスト | 合計 | 優先度 |
|-------|------|------|--------|------|--------|
| Phase 0 | 既存コード統合準備 | 0.5日 | 0.5日 | **1日** | ⭐⭐⭐ |
| Phase 1 | ボリンジャーバンド計算 | 2日 | 1日 | **3日** | ⭐⭐⭐ |
| Phase 1.5 | Hook基本機能 | 0.5日 | 0.5日 | **1日** | ⭐⭐⭐ |
| Phase 2 | JIT流動性+リバランス | 3日 | 2日 | **5日** | ⭐⭐⭐ |
| Phase 2.5 | セキュリティ機能 | 1日 | 1日 | **2日** | ⭐⭐⭐ |
| Phase 3 | 自動複利運用 | 2日 | 2日 | **4日** | ⭐⭐⭐ |
| Phase 4 | オラクル拡張 | 1日 | 1日 | **2日** | ⭐⭐ |
| Phase 5 | 統合テスト | - | 3日 | **3日** | ⭐⭐⭐ |
| Phase 5.5 | ガス最適化 | 1日 | 1日 | **2日** | ⭐⭐ |
| Phase 5.8 | フォークテスト | - | 2日 | **2日** | ⭐⭐⭐ |
| Phase 6 | Mumbai デプロイ | 0.5日 | - | **0.5日** | ⭐⭐⭐ |
| Phase 6.5 | デプロイスクリプト | 0.5日 | - | **0.5日** | ⭐⭐ |
| **合計** | - | **12日** | **14日** | **26日** | - |

---

## 📝 Phase 0: 既存コード統合準備（1日）

### 実装内容

1. **既存コードのリファクタリング**
   ```
   src/VolatilityDynamicFeeHook.sol
   ↓
   src/libraries/VolatilityLib.sol
   ```

2. **ディレクトリ構造の整理**
   ```
   src/
   ├── UnifiedDynamicHook.sol          (新規)
   ├── libraries/
   │   ├── VolatilityLib.sol           (既存コードを移行)
   │   ├── BollingerBandLib.sol        (新規)
   │   ├── JITLib.sol                  (新規)
   │   └── CompoundingLib.sol          (新規)
   └── interfaces/
       └── IUnifiedHook.sol            (新規)
   ```

3. **既存テストの動作確認**
   - 16件の既存テストが全てパスすることを確認

### タスク

- [ ] VolatilityLib.sol の作成
- [ ] 既存の動的手数料ロジックの移行
- [ ] 既存テストの実行と確認
- [ ] ディレクトリ構造の作成

---

## 📝 Phase 1: ボリンジャーバンド計算機能（3日）

### 実装内容

1. **BollingerBandLib.sol の作成**
   - 移動平均（MA）の計算
   - 標準偏差（σ）の計算
   - 2.5σバンドの算出
   - タイムフレーム可変対応

2. **データ構造**
   ```solidity
   struct BollingerBandConfig {
       uint256 period;
       uint256 standardDeviation;
       uint256 timeframe;
   }

   struct PriceStatistics {
       uint256 movingAverage;
       uint256 standardDev;
       uint256 upperBand;
       uint256 lowerBand;
       uint256 lastUpdate;
   }
   ```

### テスト（8件）

1. `test_calculateMA_correctAverage`
2. `test_calculateStdDev_correctValue`
3. `test_bollingerBands_2_5sigma`
4. `test_bollingerBands_differentTimeframes`
5. `test_bollingerBands_insufficientData`
6. `test_sqrt_accuracy`
7. `test_priceConversion_sqrtPriceX96`
8. `test_bollingerBands_update`

---

## 📝 Phase 1.5: Hook基本機能（1日）

### 実装内容

1. **BaseHook の継承**
   ```solidity
   contract UnifiedDynamicHook is BaseHook, ReentrancyGuard, Ownable {
       // ...
   }
   ```

2. **Hook権限の設定**
   ```solidity
   function getHookPermissions()
       public
       pure
       override
       returns (Hooks.Permissions memory)
   {
       return Hooks.Permissions({
           beforeInitialize: false,
           afterInitialize: true,
           beforeSwap: true,
           afterSwap: true,
           beforeAddLiquidity: true,
           afterAddLiquidity: true,
           beforeRemoveLiquidity: true,
           afterRemoveLiquidity: true,
           // ...
       });
   }
   ```

3. **Hook関数の骨組み**
   - `_afterInitialize`
   - `_beforeSwap`
   - `_afterSwap`
   - `_beforeAddLiquidity` / `_afterAddLiquidity`
   - `_beforeRemoveLiquidity` / `_afterRemoveLiquidity`

### テスト（5件）

9. `test_hook_permissions_correct`
10. `test_hook_address_calculation`
11. `test_beforeSwap_called`
12. `test_afterSwap_called`
13. `test_afterInitialize_called`

---

## 📝 Phase 2: JIT流動性 + 自動リバランス（5日）

### 実装内容

1. **JITLib.sol の作成**
   - BBベースのレンジ計算
   - MA回帰待機ロジック
   - バンドウォーク検出

2. **データ構造**
   ```solidity
   struct JITPosition {
       address owner;
       int24 targetLowerTick;
       int24 targetUpperTick;
       uint128 targetLiquidity;
       bool isActive;
   }

   struct ActivePosition {
       uint128 currentLiquidity;
       int24 currentLowerTick;
       int24 currentUpperTick;
       uint256 lastRebalanceTime;
       uint256 lastVolatility;
   }

   struct RebalanceStrategy {
       uint256 triggerThreshold;
       uint256 minInterval;
       uint256 maxGasPrice;
       bool autoRebalanceEnabled;
       bool waitForMAReturn;
   }
   ```

3. **3段階モード切替**
   - 通常モード（BB 2.5σ）
   - 緊急モード（BB 3σ）
   - 損失最小化モード（流動性撤退）

### テスト（10件）

14. `test_setJITPosition_withBB`
15. `test_rebalance_whenMAReturns`
16. `test_rebalance_skipsDuringTrend`
17. `test_bandWalk_detection`
18. `test_normalMode_BB2_5sigma`
19. `test_emergencyMode_BB3sigma`
20. `test_lossMinMode_removeLiquidity`
21. `test_modeSwitch_volatilityChange`
22. `test_rebalance_frequentOK_polygon`
23. `test_manualRebalance_override`

---

## 📝 Phase 2.5: セキュリティ機能（2日）★重要

### 実装内容

1. **ReentrancyGuard の統合**
   ```solidity
   import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

   function manualRebalance(...) external nonReentrant {
       // ...
   }
   ```

2. **Ownable パターン**
   ```solidity
   import "@openzeppelin/contracts/access/Ownable.sol";

   function pause() external onlyOwner {
       paused = true;
   }
   ```

3. **緊急停止機能**
   ```solidity
   bool public paused;

   modifier whenNotPaused() {
       require(!paused, "Paused");
       _;
   }
   ```

4. **Chainlink価格フィード統合**
   ```solidity
   import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

   AggregatorV3Interface public chainlinkPriceFeed;
   uint256 public constant MAX_PRICE_DEVIATION = 500; // 5%

   function _validatePrice(uint160 uniswapPrice) internal view {
       // Chainlinkとの乖離チェック
   }
   ```

5. **複数ブロック検証**
   ```solidity
   function _hasMultiBlockData(PoolId poolId) internal view returns (bool) {
       // 最低3ブロック以上のデータを要求
   }
   ```

6. **動的ガス価格上限**
   ```solidity
   function _getMaxGasPrice() internal view returns (uint256) {
       return _getPolygonAvgGasPrice() * 3;
   }
   ```

### テスト（10件）

24. `test_reentrancy_prevention`
25. `test_only_owner_can_pause`
26. `test_paused_blocks_operations`
27. `test_chainlink_price_validation`
28. `test_multi_block_requirement`
29. `test_dynamic_gas_limit`
30. `test_CEI_pattern_enforcement`
31. `test_ownership_transfer`
32. `test_emergency_shutdown`
33. `test_security_edge_cases`

---

## 📝 Phase 3: 自動複利運用機能（4日）

### 実装内容

1. **CompoundingLib.sol の作成**
   - 手数料回収ロジック
   - 手数料→流動性変換
   - 複利統計の追跡

2. **データ構造**
   ```solidity
   struct CompoundingConfig {
       bool autoCompound;
       uint256 minCompoundAmount;
       bool compoundOnEveryRebalance;
       bool reinvestBothTokens;
       uint256 totalCompounded;
       uint256 lastCompoundTime;
   }

   struct CompoundingStats {
       uint256 initialLiquidity;
       uint256 currentLiquidity;
       uint256 totalFeesEarned;
       uint256 totalFeesCompounded;
       uint256 compoundCount;
       uint256 averageAPR;
   }
   ```

3. **リバランス時の自動複利統合**
   ```solidity
   function _executeRebalanceWithCompounding(...) internal {
       // 1. 流動性削除
       // 2. 手数料回収
       // 3. 手数料→流動性変換
       // 4. 元本+複利で再投資
   }
   ```

### テスト（7件）

34. `test_autoCompound_enabled`
35. `test_autoCompound_minAmount`
36. `test_feesToLiquidity_conversion`
37. `test_compound_bothTokens`
38. `test_compoundStats_tracking`
39. `test_compound_12months_simulation`
40. `test_compound_vs_noCompound`

---

## 📝 Phase 4: オラクル拡張（2日）

### 実装内容

1. **長期データ保存（100件）**
   ```solidity
   struct PriceOracle {
       PriceObservation[] observations;
       uint256 index;
       uint256 count;
       uint256 maxSize;  // 100件
   }
   ```

2. **外部TWAP提供**
   ```solidity
   function getTWAP(
       PoolKey calldata key,
       uint32 secondsAgo
   ) external view returns (uint256);
   ```

3. **累積価格計算**
   ```solidity
   struct PriceObservation {
       uint32 timestamp;
       uint160 sqrtPriceX96;
       uint256 cumulativePrice;  // Uniswap V2/V3方式
   }
   ```

### テスト（4件）

41. `test_oracle_longTermStorage`
42. `test_oracle_TWAP_external`
43. `test_oracle_cumulativePrice`
44. `test_oracle_ringBuffer`

---

## 📝 Phase 5: 統合テスト（3日）

### テスト（6件）

45. `test_integration_dynamicFee_BB_compound`
46. `test_integration_fullScenario_3months`
47. `test_integration_emergencyMode_recovery`
48. `test_integration_gasEfficiency_polygon`
49. `test_integration_multipleUsers`
50. `test_integration_extremeVolatility`

---

## 📝 Phase 5.5: ガス最適化（2日）

### 実装内容

1. **ガスレポートの作成**
   ```bash
   forge test --gas-report
   ```

2. **最適化対象**
   - ストレージアクセスの削減
   - 計算の効率化
   - パッキングの最適化

3. **目標ガス使用量**
   ```
   プール初期化: < 300,000 gas
   通常スワップ: < 250,000 gas
   リバランス: < 400,000 gas
   複利実行: < 50,000 gas（追加分）
   ```

### テスト（4件）

51. `test_gas_poolInitialize`
52. `test_gas_normalSwap`
53. `test_gas_rebalance`
54. `test_gas_compound`

---

## 📝 Phase 5.8: フォークテスト（2日）

### 実装内容

1. **Polygon Mainnetフォーク**
   ```bash
   forge test --fork-url https://polygon-rpc.com -vvv
   ```

2. **実際のJPYC/USDCペアでのテスト**

3. **長期シミュレーション（1ヶ月）**

### テスト（5件）

55. `test_fork_polygon_mainnet`
56. `test_fork_jpyc_usdc_pool`
57. `test_fork_1month_simulation`
58. `test_fork_extreme_volatility`
59. `test_fork_gas_costs_realistic`

---

## 📝 Phase 6: Polygon Mumbaiデプロイ（0.5日）

### 実施内容

1. **Mumbaiへのデプロイ**
   ```bash
   forge script script/DeployHook.s.sol \
     --rpc-url https://rpc-mumbai.maticvigil.com \
     --broadcast \
     --verify
   ```

2. **初期設定**
   - BB設定
   - リバランス戦略
   - 複利設定

3. **1週間のテスト運用**

---

## 📝 Phase 6.5: デプロイスクリプト（0.5日）

### 実装内容

1. **script/DeployHook.s.sol**
   - CREATE2アドレス計算
   - Hook権限の検証
   - 初期パラメータ設定

2. **script/CreatePool.s.sol**
   - プール作成
   - 初期流動性追加
   - BB設定の初期化

3. **script/Verify.s.sol**
   - Polygonscanでの検証
   - パラメータの確認

---

## 📊 エラー・イベント定義

### カスタムエラー（20個）

```solidity
error Unauthorized();
error Paused();
error InsufficientLiquidity();
error PriceDeviationTooHigh();
error RebalanceTooSoon();
error GasPriceTooHigh();
error InvalidBollingerBandConfig();
error InvalidRebalanceStrategy();
error CompoundAmountTooLow();
error VolatilityThresholdExceeded();
error NotPositionOwner();
error PositionNotActive();
error InvalidTickRange();
error InsufficientMultiBlockData();
error PriceChangeExceedsLimit();
error ChainlinkPriceStale();
error OracleDataInsufficient();
error BandWalkDetected();
error LiquidityOverflow();
error ZeroDivision();
```

### イベント（15個）

```solidity
event JITPositionCreated(PoolId indexed poolId, address indexed owner, ...);
event PositionRebalanced(PoolId indexed poolId, address indexed owner, ...);
event FeesCompounded(PoolId indexed poolId, address indexed owner, ...);
event EmergencyModeActivated(PoolId indexed poolId, uint256 volatility);
event EmergencyModeDeactivated(PoolId indexed poolId);
event LossMinimizationModeActivated(PoolId indexed poolId);
event LiquidityRemoved(PoolId indexed poolId, address indexed owner, ...);
event LiquidityReinstated(PoolId indexed poolId, address indexed owner, ...);
event BollingerBandConfigUpdated(PoolId indexed poolId, ...);
event RebalanceStrategyUpdated(PoolId indexed poolId, ...);
event CompoundingConfigUpdated(PoolId indexed poolId, ...);
event Paused(address indexed owner);
event Unpaused(address indexed owner);
event ChainlinkPriceFeedUpdated(address indexed newFeed);
event BandWalkDetected(PoolId indexed poolId, uint256 consecutiveEdgeCount);
```

---

## ✅ テスト総数: 59件

| カテゴリ | テスト数 |
|---------|---------|
| BB計算 | 8件 |
| Hook基本 | 5件 |
| JIT+リバランス | 10件 |
| セキュリティ | 10件 |
| 自動複利 | 7件 |
| オラクル | 4件 |
| 統合テスト | 6件 |
| ガス最適化 | 4件 |
| フォークテスト | 5件 |
| **合計** | **59件** |

---

## 📅 週次スケジュール

### Week 1（Day 1-5）
- Phase 0: 既存コード統合
- Phase 1: BB計算機能
- Phase 1.5: Hook基本機能

### Week 2（Day 6-10）
- Phase 2: JIT流動性+リバランス（前半）

### Week 3（Day 11-15）
- Phase 2: JIT流動性+リバランス（後半）
- Phase 2.5: セキュリティ機能

### Week 4（Day 16-20）
- Phase 3: 自動複利運用
- Phase 4: オラクル拡張

### Week 5（Day 21-25）
- Phase 5: 統合テスト
- Phase 5.5: ガス最適化
- Phase 5.8: フォークテスト

### Week 6（Day 26）
- Phase 6: Mumbaiデプロイ
- Phase 6.5: デプロイスクリプト

---

## 🎯 完成基準

### コード品質
- [ ] 全テスト（59件）パス
- [ ] Slither 重大な脆弱性0件
- [ ] ガス使用量が目標以内
- [ ] コードカバレッジ 95%以上

### セキュリティ
- [ ] ReentrancyGuard 統合
- [ ] Chainlink価格検証
- [ ] 緊急停止機能
- [ ] 全セキュリティチェック項目クリア

### ドキュメント
- [ ] API仕様書完成
- [ ] ユーザーガイド完成
- [ ] セキュリティガイド完成

### デプロイ
- [ ] Mumbai で1週間稼働
- [ ] 異常動作なし
- [ ] ガス代実測完了

---

**最終更新:** 2025-12-24
**総期間:** 26日間
**総テスト数:** 59件
