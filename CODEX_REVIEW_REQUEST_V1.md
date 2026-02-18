# Codex セキュリティレビュー依頼 (v1.0)

## プロジェクト概要

**コントラクト名:** `VolatilityDynamicFeeHook`
**ファイル:** `src/VolatilityDynamicFeeHook.sol`（536行）
**Solidity:** `^0.8.24`
**フレームワーク:** Uniswap v4 Hook（BaseHook継承）
**用途:** JPYC/USDC ペアのボラティリティ連動動的手数料

## 現在の品質状態

| 項目 | 状態 |
|---|---|
| テスト | 57件全パス（0失敗） |
| Slither Medium | 0件 |
| Slither Low | 0件 |
| Slither Informational | 1件（`pragma` のみ） |
| CI (GitHub Actions) | ✅ 通過（コミット `e242817`） |
| ガスベースライン | `.gas-snapshot` 管理済み |

既知の許容済み Slither 検出（`config/slither.db.json` でトリアージ済み）:
- `divide-before-multiply` × 2件: `_getFeeBasedOnVolatility` の意図的なレガシー丸め
- `unimplemented-functions` × 1件: `BaseHook.getHookPermissions` の誤検知

## 実装済みセキュリティ機能

1. **フラッシュローン攻撃防止**
   - `MIN_BLOCK_SPAN = 3`: 最低3ブロック間隔の価格検証
   - `MIN_UPDATE_INTERVAL = 10 minutes`: 観測記録の最小間隔
   - `ObservationLibrary.validateMultiBlock()`: 複数ブロック検証

2. **価格操作検知**
   - `MAX_PRICE_CHANGE_BPS = 5000` (50%): 超過で即座に `PriceManipulationDetected` revert
   - sqrtPrice² ベースの実際の価格変動率で計算（FullMath.mulDiv 使用）

3. **サーキットブレーカー**
   - `CIRCUIT_BREAKER_THRESHOLD = 1000` (10%): 発動閾値
   - `CIRCUIT_BREAKER_COOLDOWN = 1 hours`: 自動リセット
   - `resetCircuitBreaker()`: Owner による手動リセット

4. **Staleness Recovery**
   - `STALENESS_THRESHOLD = 30 minutes`: 古い観測データの検出
   - `WARMUP_DURATION = 30 minutes`: リセット後のウォームアップ（BASE_FEE固定）

5. **アクセス制御**
   - OpenZeppelin `Ownable`: `resetCircuitBreaker`, `pause`, `unpause`
   - OpenZeppelin `Pausable`: 緊急停止（`whenNotPaused` on `_beforeSwap`）

6. **手数料計算**
   - `BASE_FEE = 300` (0.03%) ～ `MAX_FEE = 5000` (0.5%)
   - 二次関数カーブ（低ボラ時緩やか、高ボラ時急上昇）
   - 時間重み付きボラティリティ計算（最近の観測に高い重み）

## レビュー依頼事項

### 優先度：高

1. **`_getCurrentSqrtPriceX96` の `extsload` 使用**
   - `StateLibrary.POOLS_SLOT` を使った低レベルストレージ読み取り
   - Uniswap v4 のアップグレードで壊れるリスクはあるか？
   - 代替手段（`StateLibrary.getSlot0`）との比較

2. **`_calculateVolatility` のオーバーフロー耐性**
   - `_accumulateWeightedVariation` の `recencyWeight = 2^exponent`（最大 `2^10 = 1024`）
   - `variation * weight` でのオーバーフローリスク
   - オーバーフロー検出後の `type(uint256).max / 2` キャップは適切か？

3. **サーキットブレーカーの自動リセットロジック**
   - `_beforeSwap` でのリセット（`circuitBreakerTriggered[poolId] = false`）
   - リセット直後に同一トランザクション内でスワップが続行される点は問題ないか？

4. **`_afterSwap` での価格変動チェックの順序**
   - Staleness リセット → multiBlock チェック → 価格変動チェックの順序は適切か？
   - Staleness リセット後にセキュリティチェックをスキップしている点（意図的）

### 優先度：中

5. **`getPriceHistory` のガス消費**
   - 最大100要素のループ（オンチェーン呼び出しでのガス上限リスク）
   - `view` 関数なので問題ないか？

6. **`_recencyWeight` の指数関数**
   - `1 << exponent`（最大 `1 << 10 = 1024`）
   - `count` が大きい場合の挙動確認

7. **`warmupUntil` の状態管理**
   - `_beforeSwap` でのウォームアップ終了検出（`warmupUntil[poolId] = 0` にリセット）
   - `_afterSwap` でも `warmupUntil` を設定する箇所があり、競合の可能性は？

### 優先度：低

8. **イベント `WarmupPeriodStarted` の `reason` パラメータ**
   - `string` 型のイベントパラメータ（ガスコスト）
   - `bytes32` への変更を検討すべきか？

9. **`_countValidObservations` の線形スキャン**
   - `obs.count` 件数分のループ（最大100）
   - `_calculateVolatility` から呼ばれるため、`_beforeSwap` のガスに影響

## 参考ファイル

- `src/VolatilityDynamicFeeHook.sol`: メインコントラクト（536行）
- `src/libraries/ObservationLibrary.sol`: リングバッファ実装
- `test/VolatilityDynamicFeeHookTest.t.sol`: ユニットテスト
- `test/SecurityTest.t.sol`: セキュリティテスト
- `config/slither.db.json`: Slither トリアージDB
- `DECISIONS.md`: 設計判断の記録
- `.gas-snapshot`: ガスベースライン

## 特に確認してほしい点

- **ADVISORY以上の未発見脆弱性はあるか？**
- **Uniswap v4 Hook 特有のリスク**（`beforeSwap`/`afterSwap` の呼び出しコンテキスト）
- **現在の実装で本番デプロイ（Sepolia → Polygon）に進んでよいか？**
