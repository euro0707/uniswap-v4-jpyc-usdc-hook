# Uniswap V4 Volatility Dynamic Fee Hook

**Polygon Mainnet上でJPYC/USDCペアのボラティリティベース動的手数料を実現するUniswap V4 Hook**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://getfoundry.sh/)

---

## 🎯 プロジェクト概要

Uniswap V4のHookシステムを使用して、JPYC/USDCペアのボラティリティに応じた動的手数料を実現します。

### 主要機能

- 💰 **ボラティリティベース動的手数料** - 0.03%～0.5%の範囲で自動調整
- 🔒 **多層セキュリティ保護**
  - フラッシュローン攻撃検知（3ブロック検証）
  - 価格操作検知（50%変動上限、実際の価格変動率で計算）
  - サーキットブレーカー（10%閾値）
- 📊 **価格観測システム** - 100要素のリングバッファで価格履歴を保存
- 🛡️ **アクセス制御** - OpenZeppelin Ownable & Pausable統合

---

## 📊 テスト結果

✅ **27/27 tests passed (100%)**
- 12 コア機能テスト
- 5 フォークテスト
- 10 セキュリティテスト

---

## 🚀 クイックスタート

```bash
# 依存関係のインストール
forge install

# 環境変数の設定
cp .env.example .env

# テストの実行
forge test

# デプロイ（Polygon Mainnet）
forge script script/DeployHook.s.sol:DeployHook --rpc-url $POLYGON_RPC_URL --broadcast
```

### 検証ベースライン一括実行（PowerShell）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\script\validate-baseline.ps1

# slither-report.latest.json も更新したい場合
powershell -NoProfile -ExecutionPolicy Bypass -File .\script\validate-baseline.ps1 -UpdateLatest
```

## 📖 技術詳細

### アーキテクチャ

```
src/
├── VolatilityDynamicFeeHook.sol    # メインフックコントラクト（ボラティリティ計算含む）
└── libraries/
    └── ObservationLibrary.sol      # 価格観測データ管理
```

### 動的手数料ロジック

1. **価格観測**: 100要素のリングバッファで価格履歴を保存
2. **ボラティリティ計算**: 時間重み付き価格変動率を算出
3. **手数料調整**: ボラティリティに比例して0.03%～0.5%で変動
4. **セキュリティチェック**:
   - 3ブロック以上の間隔を必須化（フラッシュローン対策）
   - **実際の価格変動率で50%閾値チェック**（sqrtPrice^2で計算）
   - 10%変動でサーキットブレーカー発動

### セキュリティ機能

- **Multi-block Validation**: 最低3ブロック間隔での価格検証
- **Price Manipulation Detection**: 実際の価格変動率（price = sqrtPrice²）で50%以上を検知・拒否
- **Circuit Breaker**: 実際の価格変動率で10%閾値、自動停止後に手動リセット可能
- **Access Control**: Owner限定の管理機能
- **Pausable**: 緊急時の一時停止機能

### 🔧 Codex Report対応

このプロジェクトはCodex security reviewを受け、以下の改善を実施しました：

- ✅ **High**: sqrtPriceベースの価格変動計算を実際の価格変動率に修正
- ✅ **High**: Tick変換の誤りを解消（ボリンジャーバンド機能削除により不要に）
- ✅ **Medium**: 不要な複雑性の削除（シンプルな動的手数料Hookに集中）

## 🔮 将来の拡張可能性

このHookは基礎的な動的手数料機能を提供しますが、以下の拡張が可能です：

- **ボリンジャーバンド**: 価格監視とリバランス通知機能
- **JIT流動性**: Just-in-Time流動性の自動管理
- **自動複利**: 手数料収益の自動再投資
- **Chainlinkオラクル**: 価格フィードのバックアップソース
- **マルチペア対応**: 複数の通貨ペアへの拡張

詳細な実装計画は[こちら](IMPLEMENTATION_PLAN_PRODUCTION.md)を参照してください。

## 📝 変更履歴

### v1.0 - シンプル版（現在）
- ボラティリティベース動的手数料
- 多層セキュリティ保護
- 価格観測システム
- Codex security review対応完了

**削除した機能**:
- ボリンジャーバンド計算（設計上の問題により削除）
- リバランス通知イベント

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
