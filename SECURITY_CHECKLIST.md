# 🛡️ セキュリティチェックリスト

**プロジェクト:** Uniswap V4 自動複利JITフック
**対象:** Polygon JPYC/USDC
**最終更新:** 2025-12-24

---

## ✅ 実装前チェックリスト

### 1. リエントランシー攻撃対策

- [ ] CEIパターンの徹底（Checks → Effects → Interactions）
- [ ] ReentrancyGuard の使用
- [ ] 状態変更を外部呼び出しの前に実行
- [ ] nonReentrant modifier の適用

**テスト項目:**
- [ ] `test_reentrancy_prevention`
- [ ] `test_CEI_pattern_enforcement`

---

### 2. フロントラン/MEV攻撃対策

- [ ] スリッページ保護（minAmount0, minAmount1）
- [ ] 期限設定（deadline）
- [ ] TWAP価格の使用（スポット価格を避ける）
- [ ] プライベートメモリプール対応（オプション）

**テスト項目:**
- [ ] `test_slippage_protection`
- [ ] `test_deadline_expired`
- [ ] `test_TWAP_vs_spot_price`

---

### 3. オラクル操作攻撃対策

- [ ] 時間重み付けTWAPの使用
- [ ] 価格変動上限フィルタ（MAX_PRICE_CHANGE_BPS = 5000）
- [ ] Chainlinkオラクルとの価格乖離チェック
- [ ] 複数ソースの価格検証

**テスト項目:**
- [ ] `test_price_manipulation_resistance`
- [ ] `test_chainlink_price_validation`
- [ ] `test_max_price_change_filter`

---

### 4. フラッシュローン攻撃対策

- [ ] 最短更新間隔（MIN_UPDATE_INTERVAL = 12秒）
- [ ] 複数ブロックのTWAP必須化
- [ ] 同一ブロック内の連続更新を拒否
- [ ] 時間重み付けで短時間変動の影響を軽減

**テスト項目:**
- [ ] `test_flashloan_attack_prevention`
- [ ] `test_multi_block_requirement`
- [ ] `test_same_block_update_rejection`

---

### 5. 整数演算の安全性

- [ ] オーバーフロー/アンダーフローチェック
- [ ] ゼロ除算の防止
- [ ] 演算順序の最適化
- [ ] checked演算の使用（Solidity 0.8+）

**テスト項目:**
- [ ] `test_no_overflow_liquidity`
- [ ] `test_no_division_by_zero`
- [ ] `test_safe_math_operations`

---

### 6. 権限管理

- [ ] Ownable パターンの使用
- [ ] onlyOwner modifier の適用
- [ ] onlyPositionOwner modifier の実装
- [ ] 緊急停止機能（pause/unpause）
- [ ] タイムロック（重要な変更）

**テスト項目:**
- [ ] `test_only_owner_can_pause`
- [ ] `test_only_position_owner_can_rebalance`
- [ ] `test_unauthorized_access_reverts`

---

### 7. DoS攻撃対策

- [ ] バッチサイズ制限（MAX_BATCH_SIZE = 10）
- [ ] ガス消費の上限設定
- [ ] 無限ループの排除
- [ ] 配列長のチェック

**テスト項目:**
- [ ] `test_batch_size_limit`
- [ ] `test_gas_consumption_reasonable`

---

### 8. 自動複利の安全性

- [ ] 所有権チェック
- [ ] 手数料計算の正確性
- [ ] 流動性変換の精度
- [ ] 複利統計の整合性

**テスト項目:**
- [ ] `test_compound_only_for_owner`
- [ ] `test_fees_to_liquidity_accurate`
- [ ] `test_compound_stats_consistent`

---

### 9. 動的手数料・レンジ制御

- [ ] 手数料レンジを 5-80 bps に制限
- [ ] 日足MA±2σレンジを使用
- [ ] 1時間ごとの観測更新
- [ ] 1.8σ到達時は手数料のみ上げる
- [ ] 2σ外が連続2回でリバランス
- [ ] 2σ外が1回のみの場合は手数料のみ上げる
- [ ] 2σ外が1回で内側に戻ったらカウントリセット
- [ ] リバランス後のクールダウン（2時間）

**テスト項目:**
- [ ] `test_dynamic_fee_clamp_range`
- [ ] `test_soft_band_fee_only`
- [ ] `test_two_hour_out_of_band_rebalance`
- [ ] `test_fee_only_on_single_out_of_band`
- [ ] `test_cooldown_after_rebalance`

---

### 10. ガス価格操作対策

- [ ] 動的ガス価格上限（平均の3倍まで）
- [ ] ガス価格の定期更新
- [ ] 緊急時のガス価格上限引き上げ

**テスト項目:**
- [ ] `test_dynamic_gas_price_limit`
- [ ] `test_high_gas_price_skip`

---

### 11. 価格検証

- [ ] Chainlink価格フィードとの乖離チェック
- [ ] 異常値フィルタ
- [ ] サーキットブレーカー
- [ ] JPYC/USDC TWAP + USDC/USD（Chainlink）で基準価格を算出
- [ ] JPYC直フィードが提供された場合に差し替え可能な設計
- [ ] ReferencePriceOracle のインターフェース化

**テスト項目:**
- [ ] `test_price_deviation_check`
- [ ] `test_circuit_breaker_triggered`
- [ ] `test_reference_price_from_twap_and_chainlink`
- [ ] `test_reference_oracle_swappable`

---

## 🔧 コード品質チェックリスト

### コーディング規約

- [ ] NatSpec コメントの完備
- [ ] イベント発行の徹底
- [ ] エラーメッセージの明確化
- [ ] マジックナンバーの排除（定数化）

### テストカバレッジ

- [ ] 単体テスト: 100%カバレッジ
- [ ] 統合テスト: 主要シナリオ網羅
- [ ] ファズテスト: 辺境ケース検証
- [ ] フォークテスト: 実環境シミュレーション

### 静的解析

- [ ] Slither 実行（重大な脆弱性0件）
- [ ] Mythril 実行
- [ ] Aderyn 実行

### ガス最適化

- [ ] ガスレポート作成
- [ ] 主要関数のガス使用量測定
- [ ] 最適化の実施

---

## 🚨 デプロイ前チェックリスト

### コントラクト検証

- [ ] 全テストパス（35件）
- [ ] 静的解析クリア
- [ ] ガス効率測定完了
- [ ] コードレビュー完了

### テストネット検証

- [ ] Polygon Mumbai デプロイ
- [ ] 1週間の稼働テスト
- [ ] 異常動作の監視
- [ ] ガス代の実測

### 監査

- [ ] 外部監査の実施（推奨）
- [ ] 監査レポートの取得
- [ ] 指摘事項の修正

### ドキュメント

- [ ] API仕様書の完成
- [ ] ユーザーガイドの作成
- [ ] セキュリティガイドの作成

---

## 📊 主要な攻撃ベクトルと対策マトリックス

| 攻撃ベクトル | 影響度 | 対策 | 実装済み | テスト済み |
|------------|--------|------|---------|----------|
| リエントランシー | 高 | ReentrancyGuard + CEIパターン | ⬜ | ⬜ |
| フロントラン/MEV | 中 | スリッページ保護 + TWAP | ⬜ | ⬜ |
| オラクル操作 | 高 | TWAP + Chainlink検証 | ⬜ | ⬜ |
| フラッシュローン | 高 | MIN_INTERVAL + 複数ブロック | ⬜ | ⬜ |
| 整数オーバーフロー | 中 | checked演算 + 明示的チェック | ⬜ | ⬜ |
| 権限昇格 | 高 | Ownable + modifier | ⬜ | ⬜ |
| DoS | 中 | バッチサイズ制限 | ⬜ | ⬜ |
| ガス価格操作 | 低 | 動的上限 | ⬜ | ⬜ |
| 価格操作 | 高 | 複数ソース検証 | ⬜ | ⬜ |
| 手数料横取り | 中 | 所有権チェック | ⬜ | ⬜ |

---

## 🔒 セキュリティ設定の推奨値

```solidity
// 価格検証
uint256 public constant MAX_PRICE_CHANGE_BPS = 5000;      // 50%
uint256 public constant MAX_PRICE_DEVIATION = 500;        // 5%（Chainlink乖離）

// 時間制限
uint256 public constant MIN_UPDATE_INTERVAL = 12;         // 12秒
uint256 public constant MIN_REBALANCE_INTERVAL = 3600;    // 1時間
uint8 public constant OUT_OF_BAND_CONFIRMATIONS = 2;      // 2回連続でリバランス
uint256 public constant REBALANCE_COOLDOWN = 7200;        // 2時間
uint256 public constant SOFT_BAND_BPS = 180;              // 1.8σ

// 動的手数料レンジ（v4 fee units = 1e-6）
uint24 public constant FEE_MIN_BPS = 5;   // 5 bps
uint24 public constant FEE_MAX_BPS = 80;  // 80 bps
uint24 public constant FEE_MIN = 500;     // 5 bps in v4 units
uint24 public constant FEE_MAX = 8000;    // 80 bps in v4 units

// バッチ制限
uint256 public constant MAX_BATCH_SIZE = 10;              // 10ユーザー

// ガス制限
uint256 public maxGasPrice = 200 gwei;                    // Polygon基準

// 緊急停止
bool public paused = false;                               // 初期は有効
```

---

## 📝 セキュリティインシデント対応プラン

### Level 1: 軽微な問題

**対応:**
- ログを確認
- 影響範囲を特定
- 次回アップデートで修正

### Level 2: 中程度の問題

**対応:**
- 該当機能を一時停止
- ユーザーに通知
- 緊急パッチを作成
- テスト後に再開

### Level 3: 重大な問題

**対応:**
- 全機能を即座に停止（pause()）
- 全ユーザーに緊急通知
- 資金の安全確保
- 外部監査を実施
- 修正版を監査後にデプロイ

---

## ✅ 最終承認

実装開始前に、このチェックリストの全項目を確認してください。

**承認者:** _________________
**日付:** _________________
**署名:** _________________

---

**注意事項:**
- 本番環境へのデプロイ前に、必ず外部監査を実施してください
- テストネットで最低1週間の稼働テストを実施してください
- すべてのチェック項目をクリアするまで本番デプロイを行わないでください
