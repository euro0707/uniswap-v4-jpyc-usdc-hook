# 🎯 Uniswap V4 フック機能拡張 - 実装計画書 v2.0

**作成日:** 2025-12-24
**更新日:** 2025-12-24（LP向けJIT流動性に変更）
**バージョン:** 2.0.0
**統合方式:** 単一フック統合
**実装優先度:** JIT流動性 + 自動リバランス → オラクル拡張

---

## 📊 現在のプロジェクト状況

### 完成済み機能
- ✅ **動的手数料フック（VolatilityDynamicFeeHook）**
  - 基本機能: 100%
  - テストカバレッジ: 100%（16件全てパス）
  - セキュリティ: 95%（TWAP、価格制限、静的解析完了）
  - ドキュメント: 75%

### 既存のセキュリティ機能
- ✅ CEIパターン（Checks-Effects-Interactions）
- ✅ 時間重み付けTWAP
- ✅ 価格変動上限フィルタ（50%上限）
- ✅ ゼロ除算保護
- ✅ MIN_UPDATE_INTERVAL（12秒）

---

## 🎯 実装する機能（ユーザー要望）

1. ✅ **動的な手数料** - **既に実装済み**（ボラティリティベース）
2. 🎯 **JIT流動性 + 自動リバランス** - Phase 1で実装（優先度：最高）
   - LP向けのJust-in-Time流動性提供
   - 価格変動に応じた自動リバランス機能
3. 📊 **独自のオラクル** - Phase 2で実装（優先度：高）

**重要な変更**: 当初「指値注文」として計画していた機能は、ユーザーの要望により**LP向けJIT（Just-in-Time）流動性**に変更しました。これは自動リバランスと密接に関連しているため、Phase 1で統合実装します。

### JIT流動性とは

**Just-in-Time（JIT）流動性**:
- LPが特定の価格帯になったら自動で流動性を追加する仕組み
- 価格が範囲外に移動したら自動で流動性を削除
- 手数料収益を最大化しつつ、インパーマネントロスを最小化
- 自動リバランスと組み合わせることで、常に最適な流動性提供を実現

**従来の指値注文との違い**:
- トレーダー向け指値注文: 一般ユーザーが特定価格でスワップを自動実行
- LP向けJIT流動性: 流動性提供者が特定価格帯で自動でLPポジションを管理

---

## 🏗️ アーキテクチャ設計

### 統合方式: 単一フック統合

全機能を1つのコントラクト `UnifiedDynamicHook.sol` に統合

**メリット:**
- ガス効率が良い（フックの呼び出しが1回のみ）
- デプロイが簡単（1つのコントラクトアドレス）
- 機能間の連携が容易（状態共有が簡単）
- ユーザー体験が向上（単一インターフェース）

**デメリット:**
- コードが複雑化（適切なモジュール分割で対応）
- 監査コストが高い（包括的なテストで対応）

### プロジェクト構造

```
uniswap-v4-dynamic-fee-hook/
├── src/
│   ├── UnifiedDynamicHook.sol            🎯 メインコントラクト
│   ├── libraries/
│   │   ├── JITLib.sol                    🎯 JIT流動性ライブラリ
│   │   ├── RebalanceLib.sol              🎯 リバランスロジック
│   │   ├── TWAPOracle.sol                📊 TWAP計算専用
│   │   └── VolatilityLib.sol             ✅ 既存のボラティリティ計算を移動
│   └── interfaces/
│       ├── IUnifiedHook.sol              🎯 インターフェース
│       └── IJITLiquidity.sol             🎯 JIT流動性インターフェース
├── test/
│   ├── UnifiedDynamicHook.t.sol          🎯 統合テスト
│   ├── JITLiquidity.t.sol                🎯 JIT流動性テスト
│   ├── Rebalancing.t.sol                 🎯 リバランステスト
│   ├── PriceOracle.t.sol                 📊 オラクルテスト
│   └── ForkTest.t.sol                    ✅ 既存
├── script/
│   ├── Deploy.s.sol                      🎯 デプロイスクリプト
│   └── Setup.s.sol                       🎯 初期設定スクリプト
└── docs/
    ├── IMPLEMENTATION_PLAN_V2.md         ✅ このファイル
    ├── API_REFERENCE.md                  🎯 API仕様書
    └── USER_GUIDE.md                     🎯 ユーザーガイド
```

---

## 📝 Phase 1: JIT流動性 + 自動リバランス（統合実装）

### 概要

**JIT（Just-in-Time）流動性**:
- LPが特定の価格帯になったら自動で流動性を追加
- 価格が範囲外に移動したら自動で流動性を削除
- 手数料収益を最大化、インパーマネントロスを最小化

**自動リバランス**との統合:
- 価格変動に合わせて流動性の範囲を動的に調整
- JIT流動性の追加/削除と連携
- ガス効率を考慮した最適なタイミングで実行

### 技術仕様

#### データ構造

```solidity
/// @notice JIT流動性ポジション
struct JITPosition {
    address owner;              // LP所有者
    int24 targetLowerTick;      // 目標下限ティック
    int24 targetUpperTick;      // 目標上限ティック
    uint128 targetLiquidity;    // 目標流動性量
    bool isActive;              // ポジションが有効か
    uint256 lastUpdate;         // 最終更新時刻
}

/// @notice 自動リバランス戦略
struct RebalanceStrategy {
    uint256 triggerThreshold;   // 調整トリガー（bps、例: 500 = 5%）
    int24 tickRange;            // 新しい範囲の幅
    uint256 minInterval;        // 最短調整間隔（秒）
    uint256 maxGasPrice;        // 最大ガス価格（wei）
    bool autoRebalanceEnabled;  // 自動調整の有効/無効
}

/// @notice アクティブなポジション管理
struct ActivePosition {
    uint128 currentLiquidity;   // 現在の流動性
    int24 currentLowerTick;     // 現在の下限ティック
    int24 currentUpperTick;     // 現在の上限ティック
    uint256 lastRebalanceTime;  // 最終リバランス時刻
    uint256 accumulatedFees;    // 累積手数料収益
}

mapping(PoolId => mapping(address => JITPosition)) public jitPositions;
mapping(PoolId => mapping(address => ActivePosition)) public activePositions;
mapping(PoolId => mapping(address => RebalanceStrategy)) public strategies;
```

#### 主要関数

```solidity
/// @notice JIT流動性ポジションを設定
function setJITPosition(
    PoolKey calldata key,
    int24 targetLowerTick,
    int24 targetUpperTick,
    uint128 targetLiquidity
) external;

/// @notice 自動リバランス戦略を設定
function setRebalanceStrategy(
    PoolKey calldata key,
    uint256 triggerThreshold,
    int24 tickRange,
    uint256 minInterval
) external;

/// @notice 自動リバランスの有効/無効を切り替え
function toggleAutoRebalance(
    PoolKey calldata key,
    bool enabled
) external;

/// @notice 現在のポジション情報を取得
function getPosition(
    PoolKey calldata key,
    address owner
) external view returns (
    JITPosition memory jit,
    ActivePosition memory active,
    RebalanceStrategy memory strategy
);

/// @notice 手動でリバランスを実行
function manualRebalance(
    PoolKey calldata key
) external;
```

#### イベント

```solidity
event JITPositionCreated(
    PoolId indexed poolId,
    address indexed owner,
    int24 lowerTick,
    int24 upperTick,
    uint128 liquidity
);

event LiquidityAdded(
    PoolId indexed poolId,
    address indexed owner,
    int24 tick,
    uint128 liquidity,
    uint256 timestamp
);

event LiquidityRemoved(
    PoolId indexed poolId,
    address indexed owner,
    int24 tick,
    uint128 liquidity,
    uint256 timestamp
);

event PositionRebalanced(
    PoolId indexed poolId,
    address indexed owner,
    int24 oldLowerTick,
    int24 oldUpperTick,
    int24 newLowerTick,
    int24 newUpperTick,
    uint256 gasUsed
);
```

### 実装のポイント

#### 1. JIT流動性の追加/削除タイミング

**追加タイミング**:
- スワップ前（beforeSwap）に現在価格をチェック
- 価格が目標範囲内に入った場合、流動性を追加
- ガス効率のため、バッチ処理を検討

**削除タイミング**:
- スワップ後（afterSwap）に現在価格をチェック
- 価格が目標範囲外に出た場合、流動性を削除
- 手数料収益を回収

#### 2. 自動リバランスのトリガー

- 価格が範囲の端に近づいた時（例: 上限の95%に到達）
- 時間ベース（例: 1日ごと）
- ガス価格が閾値以下の時のみ実行
- ボラティリティが低い時に優先的に実行

#### 3. セキュリティ対策

- **CEIパターン**: Checks → Effects → Interactions
- **MEV攻撃対策**: スリッページ保護
- **フラッシュローン保護**: MIN_INTERVAL（12秒）
- **ガス価格チェック**: 高騰時はスキップ
- **権限チェック**: ポジション所有者のみが操作可能

### テスト項目（20件）

#### JIT流動性テスト（8件）
1. `test_setJITPosition_success` - JITポジションの設定
2. `test_addJITLiquidity_whenPriceEntersRange` - 価格が範囲内に入った時の流動性追加
3. `test_removeJITLiquidity_whenPriceExitsRange` - 価格が範囲外に出た時の流動性削除
4. `test_multipleJITPositions_managedIndependently` - 複数JITポジションの独立管理
5. `test_JITLiquidity_earnsFees` - 手数料収益の確認
6. `test_JITPosition_canBeUpdated` - JITポジションの更新
7. `test_JITPosition_canBeDeactivated` - JITポジションの無効化
8. `test_JIT_gasEfficiency` - ガス効率の測定

#### 自動リバランステスト（8件）
9. `test_setRebalanceStrategy_success` - リバランス戦略の設定
10. `test_autoRebalance_triggersAtThreshold` - 閾値でのトリガー
11. `test_autoRebalance_upwardPriceMovement` - 上方向のリバランス
12. `test_autoRebalance_downwardPriceMovement` - 下方向のリバランス
13. `test_autoRebalance_respectsMinInterval` - 最短間隔の遵守
14. `test_autoRebalance_skipsIfGasPriceTooHigh` - 高ガス価格時のスキップ
15. `test_manualRebalance_success` - 手動リバランスの実行
16. `test_rebalance_gasEfficiency` - リバランスのガス効率

#### 統合テスト（4件）
17. `test_JIT_and_rebalance_workTogether` - JITとリバランスの連携
18. `test_dynamicFee_appliesWithJIT` - 動的手数料とJITの統合
19. `test_oracle_recordsPricesWithJIT` - オラクルとJITの統合
20. `test_fullScenario_priceVolatility` - 価格変動シナリオテスト

### 実装スケジュール

| タスク | 期間 |
|-------|------|
| データ構造設計 | 0.5日 |
| JIT流動性コア実装 | 2日 |
| 自動リバランス実装 | 2日 |
| テスト実装（20件） | 2.5日 |
| ガス最適化 | 1日 |
| **合計** | **8日** |

---

## 📝 Phase 2: オラクル拡張機能（PriceOracleHook）

### 概要
Uniswap V4プールの価格データを外部プロトコルに提供する信頼性の高い価格フィード。

### 技術仕様

#### データ構造

```solidity
/// @notice 価格観測データ
struct PriceObservation {
    uint32 timestamp;           // タイムスタンプ
    uint160 sqrtPriceX96;       // 平方根価格
    uint256 cumulativePrice;    // 累積価格（TWAP計算用）
}

/// @notice リングバッファで大量の価格データを保存
struct PriceOracle {
    PriceObservation[] observations;
    uint256 index;              // 現在の書き込みポジション
    uint256 count;              // 記録済みの観測数
    uint256 maxSize;            // バッファサイズ（100件）
}

mapping(PoolId => PriceOracle) public oracles;
```

#### 主要関数

```solidity
/// @notice 最新価格を取得
function getLatestPrice(PoolKey calldata key) external view returns (uint160);

/// @notice 指定期間のTWAPを計算
function getTWAP(
    PoolKey calldata key,
    uint32 secondsAgo
) external view returns (uint256 twap);

/// @notice 過去の特定時点の価格を取得
function getHistoricalPrice(
    PoolKey calldata key,
    uint32 timestamp
) external view returns (uint160);
```

### 既存実装との統合

`VolatilityDynamicFeeHook`の価格履歴機能を拡張：
- データ保存期間を10件 → 100件に拡張
- 累積価格の追加（Uniswap V2/V3方式）
- 外部参照用の公開インターフェース

### テスト項目（7件）

1. `test_recordPrice_storesCorrectData` - 価格記録の正確性
2. `test_getLatestPrice_returnsCurrentPrice` - 最新価格の取得
3. `test_getTWAP_1minute` - 1分間のTWAP計算
4. `test_getTWAP_15minutes` - 15分間のTWAP計算
5. `test_ringBuffer_overwritesOldData` - 古いデータの上書き
6. `test_externalAccess_worksFromOtherContract` - 外部プロトコルからの参照
7. `test_gas_twapCalculation` - TWAP計算のガス効率

### 実装スケジュール

| タスク | 期間 |
|-------|------|
| データ構造拡張 | 0.5日 |
| TWAP計算実装 | 1日 |
| テスト実装 | 1日 |
| 統合テスト | 0.5日 |
| **合計** | **3日** |

---

## 🔄 統合実装: UnifiedDynamicHook

### フック権限の設定

```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        beforeInitialize: false,
        afterInitialize: true,       // 価格履歴の初期化 + オラクル初期化
        beforeAddLiquidity: true,    // JIT流動性チェック（オプション）
        afterAddLiquidity: true,     // ポジション更新
        beforeRemoveLiquidity: true, // ポジション確認
        afterRemoveLiquidity: true,  // ポジション更新
        beforeSwap: true,            // 動的手数料 + JIT流動性追加
        afterSwap: true,             // 価格更新 + オラクル記録 + JIT流動性削除 + 自動リバランス
        beforeDonate: false,
        afterDonate: false,
        beforeSwapReturnDelta: false,
        afterSwapReturnDelta: false,
        afterAddLiquidityReturnDelta: false,
        afterRemoveLiquidityReturnDelta: false
    });
}
```

### フック関数の統合

```solidity
/// @notice afterInitialize: 初期化処理
function _afterInitialize(
    address,
    PoolKey calldata key,
    uint160 sqrtPriceX96,
    int24 tick
) internal override returns (bytes4) {
    PoolId poolId = key.toId();

    // 1. 動的手数料の価格履歴初期化
    _initializePriceHistory(poolId, sqrtPriceX96);

    // 2. オラクルの初期化
    _initializeOracle(poolId, sqrtPriceX96);

    return BaseHook.afterInitialize.selector;
}

/// @notice beforeSwap: スワップ前処理
function _beforeSwap(
    address,
    PoolKey calldata key,
    SwapParams calldata params,
    bytes calldata
) internal override returns (bytes4, BeforeSwapDelta, uint24) {
    PoolId poolId = key.toId();
    (uint160 currentPrice, int24 currentTick,,) = poolManager.getSlot0(poolId);

    // 1. JIT流動性の追加チェック
    _checkAndAddJITLiquidity(key, currentTick);

    // 2. 動的手数料の計算
    uint256 volatility = _calculateVolatility(poolId);
    uint24 fee = _getFeeBasedOnVolatility(volatility);
    uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

    return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
}

/// @notice afterSwap: スワップ後処理
function _afterSwap(
    address,
    PoolKey calldata key,
    SwapParams calldata,
    BalanceDelta,
    bytes calldata
) internal override returns (bytes4, int128) {
    PoolId poolId = key.toId();
    (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);

    // 1. 価格履歴の更新（動的手数料用）
    _updatePriceHistory(poolId, sqrtPriceX96);

    // 2. オラクルへの価格記録
    _recordPrice(poolId, sqrtPriceX96);

    // 3. JIT流動性の削除チェック
    _checkAndRemoveJITLiquidity(key, tick);

    // 4. 自動リバランスのチェック
    _autoRebalanceIfNeeded(key, tick);

    return (BaseHook.afterSwap.selector, 0);
}
```

---

## 🛡️ セキュリティ考慮事項

### 継承する既存のセキュリティ機能
1. ✅ CEIパターン（Checks-Effects-Interactions）
2. ✅ 時間重み付けTWAP
3. ✅ 価格変動上限フィルタ（50%）
4. ✅ ゼロ除算保護
5. ✅ MIN_UPDATE_INTERVAL（12秒）

### 新機能で追加するセキュリティ

#### Phase 1: JIT流動性 + 自動リバランス
- ポジション所有権検証（onlyPositionOwner modifier）
- MEV攻撃対策（スリッページ保護）
- フラッシュローン保護（MIN_INTERVAL継続）
- ガス価格チェック（高騰時はスキップ）
- 再入攻撃対策（CEIパターン）
- 流動性範囲の妥当性チェック（極端な範囲を拒否）

#### Phase 2: オラクル
- 価格操作検出（時間重み付け継続）
- 古いデータの処理（タイムスタンプチェック）
- 外部参照の制限（view関数のみ）
- 累積価格のオーバーフロー保護

### 監査前チェックリスト

- [ ] 全テストが通過（27件以上）
- [ ] Slither静的解析（重大な脆弱性なし）
- [ ] ガス使用量の測定と最適化
- [ ] ドキュメントの完成
- [ ] フォークテストの実施
- [ ] 外部監査の実施

---

## 💰 ガス最適化戦略

### 1. データ構造の最適化
- **パッキング**: 複数の小さな型を1つのストレージスロットにまとめる
- **固定サイズ配列**: 動的配列を避ける
- **マッピングの効率化**: ネストしたマッピングの最適化

### 2. 計算の削減
- **キャッシング**: 頻繁にアクセスするデータをメモリにキャッシュ
- **ショートサーキット**: 不要な計算を早期にスキップ
- **バッチ処理**: 複数の操作をまとめて実行

### 3. ストレージの削減
- **イベントログの活用**: 履歴データはイベントで記録
- **一時データの削除**: 不要になったデータを削除（ガスリファンド）
- **リングバッファ**: 固定サイズ配列で動的配列を回避

### 4. ガス効率目標

| 操作 | 目標ガス使用量 | 備考 |
|-----|--------------|------|
| プール初期化 | < 300,000 | 複数機能の初期化 |
| 通常スワップ | < 250,000 | JIT追加/削除なし |
| JIT流動性追加 | < 350,000 | 流動性追加を含む |
| JIT流動性削除 | < 300,000 | 流動性削除 + 手数料回収 |
| 自動リバランス | < 400,000 | ポジション調整 |

---

## 📊 開発スケジュール

### 全体スケジュール

| Phase | 機能 | 実装期間 | テスト期間 | 合計 | 優先度 |
|-------|------|---------|-----------|------|--------|
| Phase 1 | JIT流動性 + 自動リバランス | 5日 | 3日 | **8日** | ⭐⭐⭐ |
| Phase 2 | オラクル拡張 | 1.5日 | 1.5日 | **3日** | ⭐⭐ |
| 統合 | 統合テスト + ガス最適化 | 2日 | 1日 | **3日** | ⭐⭐⭐ |
| ドキュメント | 仕様書 + ユーザーガイド | 1日 | - | **1日** | ⭐⭐ |
| **合計** | - | - | - | **15日** | - |

### マイルストーン

- **Week 1 (Day 1-5)**: Phase 1 - JIT流動性実装 ✅
- **Week 2 (Day 6-8)**: Phase 1 - 自動リバランス実装 + テスト ✅
- **Week 2 (Day 9-11)**: Phase 2 - オラクル拡張 ✅
- **Week 3 (Day 12-15)**: 統合テスト + 最適化 + ドキュメント ✅

---

## 📚 参考情報

### Harmonia Protocolからの学び
- Discord連携（Sign Protocol + Lit Protocol）
- Web3Auth統合パターン
- マルチチェーンデプロイ戦略（Base、Scroll、Unichainなど）

### 実装に取り入れる可能性のある要素（オプション）
- Sign Protocolでのメタデータ保存
- Pyth Oracleとの統合（価格フィードの補完）
- フロントエンド連携（Next.js + TypeScript）

### 技術参考資料
- [Uniswap V4 公式ドキュメント](https://docs.uniswap.org/contracts/v4/overview)
- [Dynamic Fees ガイド](https://docs.uniswap.org/contracts/v4/concepts/dynamic-fees)
- [Foundry Book](https://book.getfoundry.sh/)
- [Zenn記事: Uniswap v4 Hooks実装ガイド](https://zenn.dev/naizo01/articles/f7a36e99051f22)
- [Harmonia Protocol](https://github.com/naizo01/Harmonia_protocol)

---

## 🎯 次のステップ

### 即座に開始する作業
1. ✅ この実装計画書v2.0の確認
2. 🎯 Phase 1（JIT流動性 + 自動リバランス）の実装開始
   - データ構造の定義
   - コア関数の実装
   - テストケースの作成

### 実装前の確認事項
- [ ] 既存のテストが全て通過していることを確認
- [ ] Foundryのバージョン確認（v1.5.0以上）
- [ ] Git環境の確認（変更履歴の管理）

---

## 📝 変更履歴

| 日付 | バージョン | 変更内容 |
|------|----------|---------|
| 2025-12-24 | 1.0.0 | 初版作成（単一フック統合方式、トレーダー向け指値注文） |
| 2025-12-24 | 2.0.0 | LP向けJIT流動性に変更、自動リバランスとの統合実装に修正 |

---

**注意事項:**
- この計画書は、ユーザーの要望（LP向けJIT流動性）に基づいて策定されています
- 実装中に新たな要件や課題が発見された場合は、柔軟に計画を調整します
- 本番環境へのデプロイ前に、必ず外部監査を実施してください

**承認:**
- 統合方式: 単一フック統合 ✅
- 開始機能: JIT流動性 + 自動リバランス（Phase 1） ✅
- 機能変更: トレーダー向け指値注文 → LP向けJIT流動性 ✅
