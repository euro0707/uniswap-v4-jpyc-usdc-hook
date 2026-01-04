# Uniswap V4 Dynamic Fee Hook V2 - Bollinger Bands Implementation Plan

## 📋 プロジェクト概要

### 目的
V1のボラティリティベース動的手数料から、ボリンジャーバンド指標を活用した高度な動的手数料システムへ進化させる。

### 背景
- V1では単純な価格変動率（ボラティリティ）をベースに手数料を調整
- ボリンジャーバンドは統計的な価格レンジを提供し、より精緻な市場状態判断が可能
- JPYC/USDCペア（実質USD/JPYレート）のような為替ペアに最適化

### V2の設計方針
- **シンプル性**: Uniswap V4の既存機能のみを使用し、外部依存を最小化
- **実装可能性**: オンチェーンで完結する機能のみを実装
- **段階的進化**: 複雑な機能（外部オラクル、TVL/ボリューム判定）はV3以降に延期
- **セキュリティ**: V1の強固なセキュリティ機能を継承・強化

---

## 🎯 V2の主要機能

### 1. ボリンジャーバンド計算
- **移動平均（MA）**: 過去N期間の価格の単純移動平均
- **標準偏差（σ）**: 価格のばらつきを統計的に測定
- **上部バンド**: MA + (k × σ)
- **下部バンド**: MA - (k × σ)
- **パラメータ**:
  - 期間（N）: 20観測（デフォルト）
  - 乗数（k）: 2.0（デフォルト、2標準偏差）

### 2. 動的手数料ロジック
バンド位置に基づいた手数料調整：

| 価格位置 | 判定条件 | 市場状態 | 手数料レベル | 理由 |
|---------|---------|---------|------------|------|
| 上部バンド外 | `price > upperBand` | 過熱（買われすぎ） | 高（0.5%固定） | 平均回帰リスク高（MAX_FEE上限） |
| 上部バンド付近 | `upperBand - bandWidth*0.1 <= price <= upperBand` | やや過熱 | 中高（0.2-0.3%） | ボラティリティ上昇 |
| バンド中央 | `lowerBand + bandWidth*0.1 < price < upperBand - bandWidth*0.1` | 正常範囲 | 低（0.03-0.045%） | 安定した取引環境 |
| 下部バンド付近 | `lowerBand <= price <= lowerBand + bandWidth*0.1` | やや過冷 | 中高（0.2-0.3%） | ボラティリティ上昇 |
| 下部バンド外 | `price < lowerBand` | 過冷（売られすぎ） | 高（0.5%固定） | 平均回帰リスク高（MAX_FEE上限） |

**Near閾値の定義**: バンド幅（`bandWidth = upperBand - lowerBand`）の10%を「付近」の境界とする。
例: バンド幅が100の場合、上部/下部バンドから10の距離以内（境界値含む）を「Near」と判定。
境界値は「Near」側に含まれるため、境界での基本手数料はMID_FEE（0.2%）が適用され、さらにbandWidthBps調整係数（1.0-1.5倍）とMAX_FEE上限（0.5%）が適用される。

### 3. バンド幅指標（Band Width）
- **計算式（bps単位）**: `bandWidthBps = (上部バンド - 下部バンド) × 10,000 / 移動平均`
  - 例: バンド幅が移動平均の2%の場合 → `bandWidthBps = 200`
- **用途**: 市場のボラティリティ状態を定量化
- **判断基準（bps単位で統一）**:
  - 幅が広い（`bandWidthBps > 400` = 4%）: 高ボラティリティ → 高手数料
  - 幅が中程度（`200 < bandWidthBps <= 400` = 2-4%）: 中ボラティリティ → 中手数料
  - 幅が狭い（`bandWidthBps <= 200` = 2%以下）: 低ボラティリティ → 低手数料
  - 急激な拡大: スクイーズ後のブレイクアウト → 手数料上昇

### 4. V1機能の継承
- ✅ 多層セキュリティ保護（フラッシュローン検知、価格操作検知、サーキットブレーカー）
- ✅ リングバッファによる効率的な価格履歴管理
- ✅ アクセス制御（Ownable & Pausable）
- ✅ 時間重み付き計算

---

## 🏗️ アーキテクチャ設計

### ファイル構成
```
src/
├── BollingerBandsDynamicFeeHook.sol    # メインHookコントラクト（新規）
└── libraries/
    ├── ObservationLibrary.sol          # 価格観測管理（既存・拡張）
    └── BollingerBandsLibrary.sol       # BB計算ロジック（新規）
```

### コントラクト設計

#### BollingerBandsDynamicFeeHook.sol
```solidity
contract BollingerBandsDynamicFeeHook is BaseHook, Ownable, Pausable {
    // State variables
    mapping(PoolId => ObservationLibrary.RingBuffer) public observations;
    mapping(PoolId => BollingerBandsLibrary.BandsState) public bandsState;
    mapping(PoolId => bool) public circuitBreakerTriggered;

    // Parameters
    uint256 public constant BB_PERIOD = 20;              // ボリンジャーバンド期間
    uint256 public constant BB_MULTIPLIER = 2;           // 標準偏差の倍数
    uint256 public constant MIN_UPDATE_INTERVAL = 1 hours; // 更新間隔

    // Fee parameters
    uint24 public constant BASE_FEE = 300;               // 0.03%
    uint24 public constant MID_FEE = 2000;               // 0.2%
    uint24 public constant HIGH_FEE = 5000;              // 0.5%

    // Functions
    function _calculateBollingerBands(PoolId poolId) internal view returns (BollingerBands memory);
    function _getFeeBasedOnBands(uint160 currentSqrtPrice, BollingerBands memory bands) internal pure returns (uint24);
    function _calculateBandWidth(BollingerBands memory bands) internal pure returns (uint256);
}
```

#### BollingerBandsLibrary.sol（新規）
```solidity
library BollingerBandsLibrary {
    struct BollingerBands {
        uint256 upperBand;      // 上部バンド（priceX96形式）
        uint256 middleBand;     // 移動平均（中央、priceX96形式）
        uint256 lowerBand;      // 下部バンド（priceX96形式）
        uint256 bandWidthBps;   // バンド幅（bps単位、例: 200 = 2%）
        uint256 timestamp;      // 計算時刻
    }

    // 価格変換: sqrtPriceX96 → priceX96（線形価格スケール）
    // priceX96 = (sqrtPriceX96 * sqrtPriceX96) / (1 << 96)
    // または FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96)
    // BB計算はすべてpriceX96形式で実行（sqrtPriceX96をpriceX96に変換して統計処理）

    struct BandsState {
        BollingerBands lastBands;
        uint256 lastUpdateTime;
    }

    // 移動平均計算（priceX96形式で返す）
    function calculateMovingAverage(
        ObservationLibrary.RingBuffer storage obs,
        uint256 period
    ) internal view returns (uint256);

    // 標準偏差計算（priceX96形式のmeanを受け取る）
    function calculateStandardDeviation(
        ObservationLibrary.RingBuffer storage obs,
        uint256 mean,
        uint256 period
    ) internal view returns (uint256);

    // ボリンジャーバンド計算
    function calculate(
        ObservationLibrary.RingBuffer storage obs,
        uint256 period,
        uint256 multiplier
    ) internal view returns (BollingerBands memory);

    // 価格がバンドのどの位置にあるか判定（priceX96形式で入力）
    function getPricePosition(
        uint256 price,
        BollingerBands memory bands
    ) internal pure returns (Position);

    enum Position {
        BelowLower,      // 下部バンド外（price < lowerBand）
        NearLower,       // 下部バンド付近（lowerBand <= price <= lowerBand + bandWidth * 0.1）
        InRange,         // 正常範囲（lowerBand + bandWidth * 0.1 < price < upperBand - bandWidth * 0.1）
        NearUpper,       // 上部バンド付近（upperBand - bandWidth * 0.1 <= price <= upperBand）
        AboveUpper       // 上部バンド外（price > upperBand）
    }

    // Near閾値の定義: バンド幅の10%（bandWidth = upperBand - lowerBand）
    // 例: bandWidth = 100の場合、upper/lowerから10以内（境界含む）を「Near」と判定
    // 境界値は「Near」側に含まれる（境界での手数料はMID_FEE）
}
```

---

## 📊 手数料決定アルゴリズム

### フロー図
```
1. スワップ前処理（beforeSwap）
   ↓
2. 価格履歴から過去20観測を取得
   ↓
3. ボリンジャーバンド計算
   ├─ 移動平均（MA）
   ├─ 標準偏差（σ）
   └─ 上下バンド（MA ± 2σ）
   ↓
4. 現在価格とバンドの位置関係を判定
   ↓
5. バンド幅を計算（ボラティリティ指標）
   ↓
6. 手数料を決定
   ├─ 基本手数料: バンド位置による
   ├─ 調整係数: バンド幅による
   └─ 最終手数料 = 基本手数料 × 調整係数
   ↓
7. 手数料を返却（OVERRIDE_FEE_FLAG付き）
```

### 手数料計算式（疑似コード）
```solidity
function _getFeeBasedOnBands(
    uint160 currentSqrtPrice,
    BollingerBands memory bands
) internal pure returns (uint24) {
    // 0. 価格変換: sqrtPriceX96 → priceX96
    uint256 currentPrice = FullMath.mulDiv(
        uint256(currentSqrtPrice),
        uint256(currentSqrtPrice),
        1 << 96
    );

    // 1. 価格位置を判定（priceX96形式で比較）
    Position pos = BollingerBandsLibrary.getPricePosition(currentPrice, bands);

    // 2. 位置による基本手数料
    uint24 baseFee;
    if (pos == Position.AboveUpper || pos == Position.BelowLower) {
        baseFee = HIGH_FEE;  // 0.5%
    } else if (pos == Position.NearUpper || pos == Position.NearLower) {
        baseFee = MID_FEE;   // 0.2%
    } else {
        baseFee = BASE_FEE;  // 0.03%
    }

    // 3. バンド幅による調整係数（1.0～1.5倍）
    // bandWidthBps = (upper - lower) * 10000 / middle
    uint256 bandWidthBps = bands.bandWidthBps;  // basis points (例: 200 = 2%)
    uint256 adjustmentFactor = 100; // 1.0倍（100 = 1.0）

    if (bandWidthBps > 400) {        // >4%（高ボラティリティ）
        adjustmentFactor = 150;       // 1.5倍
    } else if (bandWidthBps > 200) { // >2%（中ボラティリティ）
        adjustmentFactor = 125;       // 1.25倍
    }
    // bandWidthBps <= 200（低ボラティリティ）の場合は1.0倍のまま

    // 4. 最終手数料 = baseFee × adjustmentFactor / 100
    uint256 finalFee = (uint256(baseFee) * adjustmentFactor) / 100;

    // 5. 上限チェック（MAX_FEE = 5000 = 0.5%）
    uint24 constant MAX_FEE = 5000;
    return finalFee > MAX_FEE ? MAX_FEE : uint24(finalFee);
}
```

---

## 🔒 セキュリティ要件

### V1から継承
1. **フラッシュローン攻撃対策**
   - 最低3ブロックの間隔検証
   - 単一トランザクション内の観測を拒否

2. **価格操作検知**
   - 50%以上の急激な価格変動を拒否
   - 実際の価格変動率（price = sqrtPrice²）で計算

3. **サーキットブレーカー（改善版）**
   - **発動条件**: 実際の価格変動率が10%以上
   - **復帰条件**:
     - 自動復帰: 発動から6時間経過後、価格が安定（1時間以内に±2%以内の変動）
     - 手動復帰（実装要件）:
       - **アクセス制御**: Owner権限必須（`onlyOwner` modifier）
       - **タイムロック**: 発動から最低1時間経過後のみ手動リセット可能
       - **マルチシグ推奨**: 本番環境ではOwnerをマルチシグウォレット（3/5等）に設定
       - **監査ログ**: `CircuitBreakerReset(address indexed resetter, uint256 timestamp, string reason)` イベント必須
       - **恒久的無効化オプション**: `disableManualReset()` 関数（一度実行すると不可逆）
   - **発動回数制限**: 24時間以内に3回発動した場合、プールを一時停止（Pausable発動）
   - **復帰回数制限**: 24時間以内に手動復帰は最大2回まで（DoS防止）

4. **アクセス制御**
   - Ownable: 管理機能へのアクセス制限
   - Pausable: 緊急停止機能

### V2での強化（シンプル版）

V2では実装可能性と保守性を重視し、Uniswap V4の既存機能のみを使用します。

1. **TWAP（時間重み付き平均価格）による価格操作耐性**
   - 単一ブロックでの観測更新を禁止
   - 最小観測ウィンドウ: 3ブロック以上の間隔
   - 移動平均計算に中央値を併用（外れ値の影響を軽減）
   - 同一トランザクションからの複数観測を拒否

2. **統計的異常検出**
   - 標準偏差の3σを超える観測を異常値として除外
   - 移動平均計算から異常値を排除
   - Z-scoreベースの外れ値検出

3. **バンド計算の健全性チェック**
   - バンド幅がゼロまたは極端に狭い場合（`bandWidthBps < 10` = 0.1%未満）はデフォルト手数料
   - 上部バンド < 下部バンドのような不正な状態の検証
   - 計算オーバーフロー/アンダーフローの防止（FullMath使用）

4. **観測数の最小要件（厳格化）**
   - **BB計算に最低20観測が必須**
   - **観測数 < 20の場合は固定のBASE_FEE（0.03%）を返す**
   - V1のボラティリティベースへのフォールバックは廃止（ロジック混在による複雑化を回避）
   - **Staleness上限**: 最新観測が24時間以上古い場合は観測を無効化し、デフォルト手数料を適用

### V3以降への拡張予定（V2では未実装）

以下の機能は実装の複雑性とデータソースの課題により、V3以降に延期します：

- **流動性とボリューム条件**: TVL・24時間ボリュームの判定
  - 理由: オンチェーンでの累積ボリューム計算はガスコストが非現実的
  - V3での実装方針: 外部インデクサー（Subgraph等）との統合を検討

- **外部オラクルとの乖離チェック**: Chainlink等との価格乖離監視
  - 理由: オラクル統合の複雑性とフォールバック設計の困難性
  - V3での実装方針: Chainlink Price Feeds統合とstaleness処理の実装

**V2のセキュリティ方針**:
V1の強固なセキュリティ機能（3ブロック検証、50%変動制限、サーキットブレーカー）を継承し、統計的異常検出を追加することで、外部依存なしで十分な保護を提供します。

---

## 🧪 テスト戦略

### 1. 単体テスト（Unit Tests）
- **BollingerBandsLibrary.sol**
  - ✅ 移動平均計算の正確性
  - ✅ 標準偏差計算の正確性
  - ✅ ボリンジャーバンド計算（期間20、倍数2）
  - ✅ 価格位置判定（5つのポジション）
  - ✅ エッジケース（観測数不足、異常値）
  - ✅ **価格変換の正確性**:
    - sqrtPriceX96→priceX96変換の検証（既知の入力値で結果を確認）
    - 丸め方向の検証（FullMath.mulDiv使用時の切り捨て動作）
    - オーバーフロー回避の検証（極端なsqrtPrice値でも安全に変換）

### 2. 統合テスト（Integration Tests）
- **BollingerBandsDynamicFeeHook.sol**
  - ✅ プール初期化とBB状態の初期化
  - ✅ スワップ時のBB計算と手数料決定
  - ✅ 価格履歴の更新とリングバッファの動作
  - ✅ バンド外取引時の高手数料適用
  - ✅ バンド内取引時の低手数料適用

### 3. セキュリティテスト
- ✅ フラッシュローン攻撃シミュレーション
- ✅ 価格操作検知のトリガー条件
- ✅ サーキットブレーカーの発動と自動/手動復帰
- ✅ サーキットブレーカーDoS攻撃（連続発動による妨害）
- ✅ サーキットブレーカー手動復帰の回数制限テスト
- ✅ 異常な観測値の処理（3σ外れ値）
- ✅ オーバーフロー/アンダーフロー対策
- ✅ **固定小数点精度テスト（bandWidthBps計算の丸め誤差）**
- ✅ **bandWidthBps閾値の境界値テスト（200, 400 bpsの境界）**
- ✅ **観測数不足時の挙動（< 20観測でBASE_FEE返却）**
- ✅ **Staleness検証（24時間以上古い観測の処理）**
- ✅ **MAX_FEE上限テスト（極端なボラティリティでも0.5%を超えない）**
- ✅ **極小バンド幅フォールバックテスト（bandWidthBps < 10でBASE_FEE返却）**
- ✅ **TWAP最小間隔テスト（3ブロック未満の観測を拒否）**
- ✅ **同一トランザクション内の複数観測の拒否**
- ✅ **アクセス制御テスト**:
  - Owner権限のない者による手動復帰の拒否
  - Pausable発動の権限検証
  - 恒久的無効化後の手動復帰拒否
- ✅ **監査ログテスト**:
  - CircuitBreakerResetイベントの発火確認
  - イベントパラメータ（resetter, timestamp, reason）の正確性検証
- ✅ **不変条件テスト（Invariant/Property Tests）**:
  - 手数料は常に0.03%～0.5%の範囲内
  - リングバッファのインデックスは常に有効範囲内
  - バンド幅は常に非負（upperBand >= lowerBand）
  - 観測数は常にリングバッファサイズ以下
- ✅ **Near境界値テスト**:
  - `price = upperBand - bandWidth * 0.1` でNearUpperに分類
  - `price = lowerBand + bandWidth * 0.1` でNearLowerに分類
  - 境界値前後での手数料の段階的変化を検証

### 4. フォークテスト（Polygon Mainnet）
- ✅ JPYC/USDCペアでの動作検証
- ✅ 実際の為替変動シナリオ
- ✅ ガスコスト測定と最適化

### 5. シナリオテスト
| シナリオ | 期待される動作 |
|---------|--------------|
| 正常な取引（バンド内） | 低手数料（0.03-0.045%） |
| 価格がバンド上限突破 | 高手数料（0.5%固定、MAX_FEE上限）適用 |
| 価格がバンド下限突破 | 高手数料（0.5%固定、MAX_FEE上限）適用 |
| バンド幅の急拡大 | 手数料の段階的上昇（調整係数1.0→1.5倍） |
| バンド幅の急縮小（スクイーズ） | 手数料据え置き（調整係数1.0倍）、ブレイクアウト待機 |
| 50%以上の急変動 | 価格操作検知で拒否 |
| 10%以上の変動 | サーキットブレーカー発動 |

---

## 📈 パラメータ設定根拠

### ボリンジャーバンドパラメータ
- **期間（N = 20）**:
  - 統計的に十分なサンプルサイズ
  - 1時間更新間隔で約20時間～1日分の履歴
  - 為替市場の標準的な設定

- **倍数（k = 2）**:
  - 正規分布の95%をカバー（2σ）
  - 統計的に信頼性の高い範囲
  - 過度に敏感にならない適度な感度

### 手数料パラメータ
- **BASE_FEE = 300（0.03%）**:
  - USD/JPY為替ペアの標準的なスプレッド
  - 流動性提供者への適正なインセンティブ

- **MID_FEE = 2000（0.2%）**:
  - ボラティリティ上昇時の中間手数料
  - トレーダーとLPのバランス

- **HIGH_FEE = 5000（0.5%）**:
  - 極端な市場環境での保護手数料
  - 平均回帰リスクのプレミアム

### 更新間隔
- **MIN_UPDATE_INTERVAL = 1 hour**:
  - ガスコストとデータ精度のバランス
  - 為替市場の変動サイクルに適合
  - 過度な更新によるノイズ回避

---

## 🚀 実装フェーズ

### Phase 1: ライブラリ実装（2-3日）
- [ ] `BollingerBandsLibrary.sol` 作成
  - [ ] 移動平均計算関数
  - [ ] 標準偏差計算関数
  - [ ] ボリンジャーバンド計算関数
  - [ ] 価格位置判定関数
- [ ] 単体テスト作成と検証

### Phase 2: Hook実装（3-4日）
- [ ] `BollingerBandsDynamicFeeHook.sol` 作成
  - [ ] V1からの構造継承
  - [ ] BB計算の統合
  - [ ] 手数料決定ロジック
  - [ ] セキュリティチェック統合
- [ ] 統合テスト作成

### Phase 3: セキュリティ強化（2-3日）
- [ ] V2固有のセキュリティテスト
- [ ] 異常値処理の実装
- [ ] フォールバックメカニズム
- [ ] エッジケースのカバレッジ

### Phase 4: 最適化とドキュメント（2日）
- [ ] ガスコスト最適化
- [ ] コードレビューとリファクタリング
- [ ] ドキュメント作成
  - [ ] NatSpec コメント
  - [ ] README更新
  - [ ] 技術仕様書

### Phase 5: デプロイ準備（1-2日）
- [ ] デプロイスクリプト作成
- [ ] Polygon Mainnetフォークテスト
- [ ] Codex reviewによる最終検証
- [ ] 本番デプロイ

**総工数見積もり**: 10-14日

---

## 🔄 V1からの移行戦略

### オプション1: 並行運用
- V1とV2を別コントラクトとして並行デプロイ
- 両方の手数料を比較検証
- データ収集後に優れた方式を選択

### オプション2: 段階的移行
1. V2をtestnetで検証
2. 小規模プールでV2を試験運用
3. データ分析と調整
4. メインプールへ段階的に適用

### オプション3: ハイブリッド方式
- V1のボラティリティ計算とV2のBB計算を併用
- 両指標の加重平均で手数料を決定
- より堅牢な手数料メカニズム

**推奨**: オプション1（並行運用）→ データ分析 → オプション2（段階的移行）

---

## 📊 成功指標（KPI）

### 定量指標
1. **手数料収益**
   - V1比で手数料収益が向上
   - 高ボラティリティ時の収益最大化

2. **スリッページ**
   - トレーダーの平均スリッページを測定
   - V1と比較して悪化しないこと

3. **流動性効率**
   - TVL（Total Value Locked）の維持・向上
   - 流動性提供者のAPR改善

4. **ガスコスト**
   - スワップあたりのガスコスト
   - V1から大幅な増加がないこと（目標: +10%以内）

### 定性指標
1. **セキュリティ**
   - 攻撃の試行回数と防御成功率
   - サーキットブレーカーの適切な発動

2. **コードの保守性**
   - ライブラリの再利用性
   - テストカバレッジ（目標: >90%）

3. **ドキュメントの完全性**
   - 技術仕様書の明確性
   - 開発者向けガイドの充実度

---

## 🎓 技術的課題と対策

### 課題1: 標準偏差計算の精度とガスコスト
- **問題**: オンチェーンでの平方根計算は高コスト
- **対策**:
  - Uniswap v4の `FullMath` ライブラリを活用
  - 分散の計算のみ行い、平方根は必要な場合のみ
  - バンド幅の比較は分散のまま実施可能

### 課題2: 観測数不足時のフォールバック
- **問題**: 初期状態やプール休眠時に20観測が不足
- **対策**:
  - **観測数 < 20の場合は固定のBASE_FEE（0.03%）を返す**
  - V1方式へのフォールバックは廃止（ロジック混在による複雑化を回避）
  - 期間の動的調整も廃止（標準偏差の定義を満たさないため）
  - プール初期化時は徐々に観測を蓄積し、20観測到達後にBB計算を開始

### 課題3: 異常値の影響
- **問題**: 価格操作や誤った観測がBB計算を歪める
- **対策**:
  - 外れ値検出アルゴリズム（3σルール）
  - 中央値の活用（平均の代替）
  - **セキュリティチェック通過後の観測のみ使用**（V1と同じ厳格な検証）
  - 同一ブロックでの複数観測を拒否

### 課題4: リアルタイム性と更新頻度（権限モデルの明確化）
- **問題**: 1時間更新では急激な変動に遅れる可能性
- **対策**:
  - **手動の観測追加機能は廃止**（中央集権リスク排除）
  - **自動観測追加の条件**:
    - スワップ発生時のみ（外部トリガーなし）
    - 最終観測から1時間経過後
    - セキュリティチェック（3ブロック間隔、50%変動制限）を通過
  - **将来的な拡張（V3以降）**:
    - Chainlink等の信頼できるオラクルからの価格フィード統合
    - タイムロック付きマルチシグによるパラメータ調整機能
    - 署名付きオラクルデータによる観測補完（レート制限・乖離制限付き）

---

## 📚 参考資料

### ボリンジャーバンド理論
- John Bollinger, "Bollinger on Bollinger Bands" (2001)
- 統計的価格分析の基礎理論

### DeFi実装事例
- Uniswap V3 Concentrated Liquidity
- Balancer Dynamic Fee Pools
- Curve Finance StableSwap

### Solidityベストプラクティス
- OpenZeppelin Contracts v5
- Uniswap V4 Hook開発ガイド
- Solidity Security Patterns

---

## ✅ チェックリスト

### 実装前
- [ ] V1コードの完全な理解
- [ ] ボリンジャーバンド理論の復習
- [ ] Uniswap V4 Hookの最新ドキュメント確認
- [ ] 必要なライブラリの調査

### 実装中
- [ ] ライブラリのNatSpecコメント作成
- [ ] 各関数のガスコスト測定
- [ ] テストの段階的な作成
- [ ] コードレビューの実施

### 実装後
- [ ] 全テストの実行と合格
- [ ] Codex reviewによる検証
- [ ] ドキュメントの完成
- [ ] デプロイ準備の完了

---

## 🔗 関連ドキュメント

- [README.md](./README.md) - プロジェクト概要
- [V1実装詳細](./src/VolatilityDynamicFeeHook.sol) - 既存実装
- [ObservationLibrary](./src/libraries/ObservationLibrary.sol) - 価格観測ライブラリ

---

**作成日**: 2026-01-03
**バージョン**: V2.0.0-PLAN
**ステータス**: 計画中（Planning）

🤖 Generated with [Claude Code](https://claude.com/claude-code)
