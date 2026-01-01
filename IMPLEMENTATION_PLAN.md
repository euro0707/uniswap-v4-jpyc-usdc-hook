# 🎯 Uniswap V4 フック機能拡張 - 実装計画書

**作成日:** 2025-12-24
**バージョン:** 1.0.0
**統合方式:** 単一フック統合
**実装優先度:** 指値注文 → オラクル拡張 → 自動リバランス

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
2. 🎯 **指値注文** - Phase 1で実装（優先度：高）
3. 🔄 **自動リバランス** - Phase 3で実装（優先度：中）
4. 📊 **独自のオラクル** - Phase 2で実装（優先度：中）

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
│   │   ├── OrderLib.sol                  🎯 指値注文ライブラリ
│   │   ├── PositionLib.sol               🔄 ポジション管理
│   │   ├── TWAPOracle.sol                📊 TWAP計算専用
│   │   └── VolatilityLib.sol             ✅ 既存のボラティリティ計算を移動
│   └── interfaces/
│       ├── IUnifiedHook.sol              🎯 インターフェース
│       └── ILimitOrder.sol               🎯 指値注文インターフェース
├── test/
│   ├── UnifiedDynamicHook.t.sol          🎯 統合テスト
│   ├── LimitOrder.t.sol                  🎯 指値注文テスト
│   ├── Rebalancing.t.sol                 🔄 リバランステスト
│   ├── PriceOracle.t.sol                 📊 オラクルテスト
│   └── ForkTest.t.sol                    ✅ 既存
├── script/
│   ├── Deploy.s.sol                      🎯 デプロイスクリプト
│   └── Setup.s.sol                       🎯 初期設定スクリプト
└── docs/
    ├── IMPLEMENTATION_PLAN.md            ✅ このファイル
    ├── API_REFERENCE.md                  🎯 API仕様書
    └── USER_GUIDE.md                     🎯 ユーザーガイド
```

---

## 📝 Phase 1: 指値注文機能（LimitOrderHook）

### 概要
ユーザーが特定の価格でトークンを売買する注文を事前に設定し、価格が目標値に達したら自動で執行する機能。

### 技術仕様

#### データ構造

```solidity
/// @notice 指値注文の構造体
struct LimitOrder {
    address owner;              // 注文者のアドレス
    uint160 triggerPrice;       // 執行価格（sqrtPriceX96形式）
    bool isBuyOrder;            // true: 買い注文, false: 売り注文
    uint128 inputAmount;        // 投入する数量
    uint128 minOutputAmount;    // 最低受取数量（スリッページ保護）
    uint48 expiry;              // 有効期限（タイムスタンプ）
    bool isFilled;              // 執行済みフラグ
    uint256 executedAmount;     // 執行済み数量
}

/// @notice プールごとの注文管理
mapping(PoolId => mapping(uint256 => LimitOrder)) public orders;
mapping(PoolId => uint256[]) public activeOrderIds;  // アクティブな注文IDリスト
mapping(address => uint256[]) public userOrders;     // ユーザーごとの注文
uint256 public nextOrderId;                          // 次の注文ID
```

#### 主要関数

```solidity
/// @notice 指値注文を作成
/// @param key プールキー
/// @param triggerPrice 執行価格
/// @param isBuyOrder 買い注文かどうか
/// @param inputAmount 投入数量
/// @param minOutputAmount 最低受取数量
/// @param expiry 有効期限
/// @return orderId 作成された注文のID
function placeOrder(
    PoolKey calldata key,
    uint160 triggerPrice,
    bool isBuyOrder,
    uint128 inputAmount,
    uint128 minOutputAmount,
    uint48 expiry
) external returns (uint256 orderId);

/// @notice 注文をキャンセル
/// @param key プールキー
/// @param orderId 注文ID
function cancelOrder(
    PoolKey calldata key,
    uint256 orderId
) external;

/// @notice beforeSwap内で条件に合致した注文を自動執行
/// @param key プールキー
/// @param currentPrice 現在価格
function _executeMatchingOrders(
    PoolKey calldata key,
    uint160 currentPrice
) internal;

/// @notice ユーザーの注文一覧を取得
/// @param user ユーザーアドレス
/// @return orderIds 注文IDの配列
function getUserOrders(address user) external view returns (uint256[] memory);

/// @notice 注文の詳細を取得
/// @param key プールキー
/// @param orderId 注文ID
/// @return order 注文の詳細
function getOrder(
    PoolKey calldata key,
    uint256 orderId
) external view returns (LimitOrder memory);
```

#### イベント

```solidity
event OrderPlaced(
    PoolId indexed poolId,
    uint256 indexed orderId,
    address indexed owner,
    uint160 triggerPrice,
    bool isBuyOrder,
    uint128 inputAmount
);

event OrderCancelled(
    PoolId indexed poolId,
    uint256 indexed orderId,
    address indexed owner
);

event OrderExecuted(
    PoolId indexed poolId,
    uint256 indexed orderId,
    address indexed owner,
    uint160 executionPrice,
    uint256 outputAmount
);

event OrderExpired(
    PoolId indexed poolId,
    uint256 indexed orderId
);
```

### 実装のポイント

#### 1. ガス効率の最適化
- 注文を価格帯でソート（二分探索で高速検索）
- 実行可能な注文のみをイテレート
- 不要なストレージ読み書きを削減

```solidity
// 価格帯でソートされた注文リストを使用
struct OrderBook {
    mapping(uint160 => uint256[]) ordersByPrice;  // 価格 => 注文IDリスト
    uint160[] sortedPrices;                        // ソート済み価格リスト
}
```

#### 2. セキュリティ対策
- **Reentrancy攻撃対策**: CEIパターンの徹底
- **サンドイッチ攻撃対策**: minOutputAmountによるスリッページ保護
- **権限チェック**: 注文の所有者のみがキャンセル可能
- **有効期限チェック**: 期限切れ注文の自動無効化

```solidity
modifier onlyOrderOwner(PoolId poolId, uint256 orderId) {
    require(orders[poolId][orderId].owner == msg.sender, "Not order owner");
    _;
}
```

#### 3. エッジケースの処理
- ゼロ数量の注文を拒否
- 異常な価格（極端に高い/低い）を拒否
- 既に執行済みの注文の再実行を防止

### テスト項目（10件）

1. **基本機能テスト（4件）**
   - `test_placeOrder_success` - 注文の作成
   - `test_cancelOrder_success` - 注文のキャンセル
   - `test_getOrder_returnsCorrectData` - 注文情報の取得
   - `test_getUserOrders_returnsAllUserOrders` - ユーザー注文の一覧取得

2. **実行テスト（3件）**
   - `test_executeBuyOrder_whenPriceReached` - 買い注文の自動執行
   - `test_executeSellOrder_whenPriceReached` - 売り注文の自動執行
   - `test_executeMultipleOrders_simultaneously` - 複数注文の同時執行

3. **セキュリティテスト（3件）**
   - `test_cancelOrder_revertsIfNotOwner` - 他人の注文をキャンセル不可
   - `test_expiredOrder_notExecuted` - 有効期限切れ注文は執行されない
   - `test_slippageProtection_revertsIfBelowMin` - スリッページ保護の検証

4. **エッジケーステスト（2件）**
   - `test_placeOrder_revertsOnZeroAmount` - ゼロ数量の拒否
   - `test_placeOrder_revertsOnInvalidPrice` - 異常価格の拒否

5. **ガステスト（1件）**
   - `test_gas_orderExecution` - ガス使用量の測定

### 実装スケジュール

| タスク | 期間 | 担当 |
|-------|------|------|
| データ構造設計 | 0.5日 | - |
| コア関数実装 | 2日 | - |
| テスト実装 | 1.5日 | - |
| ガス最適化 | 0.5日 | - |
| ドキュメント作成 | 0.5日 | - |
| **合計** | **5日** | - |

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
/// @param key プールキー
/// @param secondsAgo 何秒前からのTWAPか
/// @return twap 時間加重平均価格
function getTWAP(
    PoolKey calldata key,
    uint32 secondsAgo
) external view returns (uint256 twap);

/// @notice 過去の特定時点の価格を取得
function getHistoricalPrice(
    PoolKey calldata key,
    uint32 timestamp
) external view returns (uint160);

/// @notice 価格データを記録（afterSwap内で呼び出し）
function _recordPrice(
    PoolId poolId,
    uint160 sqrtPriceX96
) internal;
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

## 📝 Phase 3: 自動リバランス機能（RebalancingHook）

### 概要
流動性提供者（LP）のポジションを自動調整し、価格変動に合わせて流動性の範囲を最適化。

### 技術仕様

#### データ構造

```solidity
/// @notice リバランスポジション
struct RebalancePosition {
    address owner;
    int24 lowerTick;            // 下限価格ティック
    int24 upperTick;            // 上限価格ティック
    uint128 liquidity;          // 流動性量
    uint256 lastRebalance;      // 最終調整時刻
    bool autoRebalance;         // 自動調整の有効/無効
}

/// @notice リバランス戦略
struct RebalanceStrategy {
    uint256 triggerThreshold;   // 調整トリガー（bps、例: 500 = 5%）
    int24 tickRange;            // 新しい範囲の幅
    uint256 minInterval;        // 最短調整間隔（秒）
    uint256 maxGasPrice;        // 最大ガス価格（wei）
}

mapping(PoolId => mapping(address => RebalancePosition)) public positions;
mapping(PoolId => RebalanceStrategy) public strategies;
```

#### 主要関数

```solidity
/// @notice リバランス戦略を設定
function setStrategy(
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

/// @notice リバランスが必要かチェック
function checkRebalanceNeeded(
    PoolKey calldata key,
    address owner
) external view returns (bool);

/// @notice リバランスを実行
function executeRebalance(
    PoolKey calldata key
) external;

/// @notice afterSwap内で自動リバランスをチェック
function _autoRebalanceIfNeeded(
    PoolId poolId,
    int24 currentTick
) internal;
```

### 実装のポイント

#### 1. リバランストリガー
- 価格が範囲の端に近づいた時（例: 上限の95%に到達）
- 時間ベース（例: 1週間ごと）
- ガス価格が閾値以下の時のみ実行

#### 2. 最適化戦略
- 手数料収益の最大化
- 価格変動範囲の予測（過去のボラティリティから）
- ガスコストとリバランス利益のバランス

#### 3. セキュリティ
- MEV攻撃対策（スリッページ保護）
- フラッシュローン保護（MIN_INTERVAL）
- ガス価格のチェック（高騰時はスキップ）

### テスト項目（10件）

1. `test_setStrategy_success` - 戦略の設定
2. `test_toggleAutoRebalance_enablesAndDisables` - 自動調整の切り替え
3. `test_checkRebalanceNeeded_returnsTrueWhenThresholdReached` - トリガー検出
4. `test_executeRebalance_upwardPriceMovement` - 上方向のリバランス
5. `test_executeRebalance_downwardPriceMovement` - 下方向のリバランス
6. `test_autoRebalance_skipsIfMinIntervalNotMet` - 最短間隔のチェック
7. `test_autoRebalance_skipsIfGasPriceTooHigh` - ガス価格チェック
8. `test_multiplePositions_managedIndependently` - 複数ポジション管理
9. `test_rebalance_slippageProtection` - スリッページ保護
10. `test_gas_rebalanceExecution` - ガス効率測定

### 実装スケジュール

| タスク | 期間 |
|-------|------|
| データ構造設計 | 0.5日 |
| コア関数実装 | 2.5日 |
| 最適化アルゴリズム | 1日 |
| テスト実装 | 2日 |
| 統合テスト | 1日 |
| **合計** | **7日** |

---

## 🔄 統合実装: UnifiedDynamicHook

### フック権限の設定

```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        beforeInitialize: false,
        afterInitialize: true,       // 価格履歴の初期化 + オラクル初期化
        beforeAddLiquidity: true,    // リバランスチェック
        afterAddLiquidity: true,     // ポジション更新
        beforeRemoveLiquidity: true, // リバランスチェック
        afterRemoveLiquidity: true,  // ポジション更新
        beforeSwap: true,            // 動的手数料 + 指値注文の執行
        afterSwap: true,             // 価格更新 + オラクル記録 + 自動リバランス
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
) internal override view returns (bytes4, BeforeSwapDelta, uint24) {
    PoolId poolId = key.toId();
    (uint160 currentPrice,,,) = poolManager.getSlot0(poolId);

    // 1. 指値注文の執行チェック
    _executeMatchingOrders(key, currentPrice);

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

    // 3. 自動リバランスのチェック
    _autoRebalanceIfNeeded(poolId, tick);

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

#### Phase 1: 指値注文
- 注文の所有権検証（onlyOrderOwner modifier）
- 有効期限チェック（自動無効化）
- スリッページ保護（minOutputAmount）
- サンドイッチ攻撃対策（価格範囲チェック）
- 再入攻撃対策（CEIパターン）

#### Phase 2: オラクル
- 価格操作検出（時間重み付け継続）
- 古いデータの処理（タイムスタンプチェック）
- 外部参照の制限（view関数のみ）
- 累積価格のオーバーフロー保護

#### Phase 3: 自動リバランス
- MEV攻撃対策（スリッページ保護）
- フラッシュローン保護（MIN_INTERVAL継続）
- ガス価格チェック（高騰時はスキップ）
- 権限チェック（ポジション所有者のみ）

### 監査前チェックリスト

- [ ] 全テストが通過（50件以上）
- [ ] Slither静的解析（重大な脆弱性なし）
- [ ] ガス使用量の測定と最適化
- [ ] ドキュメントの完成
- [ ] フォークテストの実施
- [ ] 外部監査の実施

---

## 💰 ガス最適化戦略

### 1. データ構造の最適化
- **パッキング**: 複数の小さな型を1つのストレージスロットにまとめる
  ```solidity
  struct OptimizedOrder {
      address owner;           // 20 bytes
      uint48 expiry;           // 6 bytes
      bool isBuyOrder;         // 1 byte
      bool isFilled;           // 1 byte
      // 合計28 bytes → 1スロット（32 bytes以内）
  }
  ```

### 2. 計算の削減
- **キャッシング**: 頻繁にアクセスするデータをメモリにキャッシュ
- **ショートサーキット**: 不要な計算を早期にスキップ
- **ループ最適化**: ループ回数を最小化

### 3. ストレージの削減
- **イベントログの活用**: 履歴データはイベントで記録
- **一時データの削除**: 不要になったデータを削除（ガスリファンド）
- **リングバッファ**: 固定サイズ配列で動的配列を回避

### 4. ガス効率目標

| 操作 | 目標ガス使用量 | 備考 |
|-----|--------------|------|
| プール初期化 | < 300,000 | 複数機能の初期化 |
| 通常スワップ | < 250,000 | 指値注文なし |
| 指値注文執行 | < 350,000 | 1件の注文執行 |
| 自動リバランス | < 400,000 | ポジション調整 |

---

## 📊 開発スケジュール

### 全体スケジュール

| Phase | 機能 | 実装期間 | テスト期間 | 合計 | 優先度 |
|-------|------|---------|-----------|------|--------|
| Phase 1 | 指値注文 | 3日 | 2日 | **5日** | ⭐⭐⭐ |
| Phase 2 | オラクル拡張 | 1.5日 | 1.5日 | **3日** | ⭐⭐ |
| Phase 3 | 自動リバランス | 4日 | 3日 | **7日** | ⭐ |
| 統合 | 統合テスト | - | 2日 | **2日** | ⭐⭐⭐ |
| 最適化 | ガス最適化 | 1日 | - | **1日** | ⭐⭐ |
| ドキュメント | 仕様書作成 | 1日 | - | **1日** | ⭐⭐ |
| 監査準備 | 静的解析・フォークテスト | 1日 | - | **1日** | ⭐⭐⭐ |
| **合計** | - | - | - | **20日** | - |

### マイルストーン

- **Week 1 (Day 1-5)**: Phase 1 完了 ✅
- **Week 2 (Day 6-10)**: Phase 2 完了 → Phase 3 開始 ✅
- **Week 3 (Day 11-15)**: Phase 3 完了 → 統合テスト ✅
- **Week 4 (Day 16-20)**: 最適化 → ドキュメント → 監査準備 ✅

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

---

## 🎯 次のステップ

### 即座に開始する作業
1. ✅ この実装計画書の確認
2. 🎯 Phase 1（指値注文）の実装開始
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
| 2025-12-24 | 1.0.0 | 初版作成（単一フック統合方式で策定） |

---

**注意事項:**
- この計画書は、ユーザーの要望に基づいて策定されています
- 実装中に新たな要件や課題が発見された場合は、柔軟に計画を調整します
- 本番環境へのデプロイ前に、必ず外部監査を実施してください

**承認:**
- 統合方式: 単一フック統合 ✅
- 開始機能: 指値注文（Phase 1） ✅
