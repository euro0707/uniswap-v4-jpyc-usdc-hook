# Codex セキュリティレビュー依頼 (v1.0 - 修正後最終版)

## プロジェクト概要

**コントラクト名:** `VolatilityDynamicFeeHook`  
**リポジトリ:** `euro0707/uniswap-v4-jpyc-usdc-hook`  
**対象ブランチ:** `master`（最新コミット）  
**Solidity:** `^0.8.24`  
**フレームワーク:** Uniswap v4 Hook（BaseHook継承）  
**用途:** JPYC/USDC ペアのボラティリティ連動動的手数料

## レビュー対象ファイル（優先順）

| ファイル | 行数 | 役割 |
|---|---|---|
| `src/VolatilityDynamicFeeHook.sol` | ~540行 | メインコントラクト |
| `src/libraries/ObservationLibrary.sol` | 223行 | リングバッファ・価格観測 |
| `test/SecurityTest.t.sol` | 1268行 | セキュリティテスト |
| `test/VolatilityDynamicFeeHookTest.t.sol` | - | ユニットテスト |

## 現在の品質状態

| 項目 | 状態 |
|---|---|
| テスト | **57件全パス（exit code 0）** |
| Slither Medium | **0件** |
| Slither Low | **0件** |
| Slither Informational | 1件（`pragma` のみ） |
| CI (GitHub Actions) | ✅ 通過 |
| ガスベースライン | `.gas-snapshot` 管理済み |

## 実施済みセキュリティ修正（本レビュー前に対応済み）

| ID | 内容 | 対応 |
|---|---|---|
| H-1 | `extsload` → `StateLibrary.getSlot0()` に置換 | ✅ 修正済み |
| M-2 | `warmupUntil` 二重設定防止（条件追加） | ✅ 修正済み |
| L-2 | `seenBlocks` 上限を `minBlocks * 2 + 1` に変更 | ✅ 修正済み |
| L-3 | `WarmupPeriodStarted.reason` を `string` → `bytes32` | ✅ 修正済み |

## 実装済みセキュリティ機能

1. **フラッシュローン攻撃防止**
   - `MIN_BLOCK_SPAN = 3`: 最低3ブロック間隔の価格検証
   - `MIN_UPDATE_INTERVAL = 10 minutes`: 観測記録の最小間隔
   - `ObservationLibrary.validateMultiBlock()`: 複数ブロック検証

2. **価格操作検知**
   - `MAX_PRICE_CHANGE_BPS = 5000` (50%): 超過で即座に `PriceManipulationDetected` revert
   - sqrtPrice² ベースの実際の価格変動率で計算（`FullMath.mulDiv` 使用）

3. **サーキットブレーカー**
   - `CIRCUIT_BREAKER_THRESHOLD = 1000` (10%): 発動閾値
   - `CIRCUIT_BREAKER_COOLDOWN = 1 hours`: 自動リセット
   - `resetCircuitBreaker()`: Owner による手動リセット

4. **Staleness Recovery（長期無取引後の回復）**
   - `STALENESS_THRESHOLD = 30 minutes`: 古い観測データの検出
   - `WARMUP_DURATION = 30 minutes`: リセット後のウォームアップ（BASE_FEE固定）
   - `_beforeSwap` / `_afterSwap` 両方で検出・保護

5. **アクセス制御**
   - OpenZeppelin `Ownable`: `resetCircuitBreaker`, `pause`, `unpause`
   - OpenZeppelin `Pausable`: 緊急停止（`whenNotPaused` on `_beforeSwap`）

6. **手数料計算**
   - `BASE_FEE = 300` (0.03%) ～ `MAX_FEE = 5000` (0.5%)
   - 二次関数カーブ（低ボラ時緩やか、高ボラ時急上昇）
   - 時間重み付きボラティリティ計算（最近の観測に高い重み）

## Codexへのレビュー依頼事項

### 🔴 最優先確認

1. **Uniswap v4 Hook 特有のリスク**
   - `beforeSwap` / `afterSwap` の呼び出しコンテキストで見落としているリスクはあるか？
   - `OVERRIDE_FEE_FLAG` の設定方法は正しいか？

2. **`_calculateVolatility` のオーバーフロー耐性**
   - `_accumulateWeightedVariation` の `recencyWeight = 2^exponent`（最大 `2^10 = 1024`）
   - `variation * weight` でのオーバーフローリスクの評価
   - オーバーフロー検出後の `type(uint256).max / 2` キャップは適切か？

3. **未発見の脆弱性**
   - **ADVISORY以上の未発見脆弱性はあるか？**
   - MEV・サンドイッチ攻撃への耐性評価

### 🟡 中優先確認

4. **Staleness回復ロジックの競合**
   - `_beforeSwap` と `_afterSwap` 両方で Staleness を検出する設計の安全性
   - M-2修正（`warmupUntil[poolId] == 0` 条件）で競合は完全に解消されているか？

5. **`_countValidObservations` の必要性**
   - `_calculateVolatility` から呼ばれる線形スキャン（最大100件）
   - `_accumulateWeightedVariation` 内の `sqrtPriceX96 == 0` チェックと重複しているか？

### 🟢 低優先確認

6. **`getPriceHistory` のガス消費**
   - 最大100要素のループ（`view` 関数なので問題ないか？）

7. **`isStale()` が空バッファで `true` を返す**
   - `count == 0` の場合に `reset()` が呼ばれる（空のリセット）は実害なし？

## 参考情報

- **設計判断の記録:** `DECISIONS.md`
- **Slither トリアージDB:** `config/slither.db.json`
- **ガスベースライン:** `.gas-snapshot`
- **セキュリティチェックリスト:** `SECURITY_CHECKLIST.md`
- **内部レビューレポート:** `SECURITY_REVIEW_V1.md`

## 最終質問

> **現在の実装で Sepoliaテストネットデプロイ → Polygon本番デプロイに進んでよいか？**
> **本番デプロイ前に必須の追加対応はあるか？**
