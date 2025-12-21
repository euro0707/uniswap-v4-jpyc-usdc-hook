# Uniswap v4 Dynamic Fee Hook

ボラティリティに基づいて動的に手数料を調整するUniswap v4 Hookの実装です。

## 📋 概要

このHookは、過去のスワップ価格変動を記録し、ボラティリティを計算して手数料を自動調整します。

### 手数料戦略

- **低ボラティリティ（安定時）**: 0.05% - 0.30%
- **中ボラティリティ（通常時）**: 0.30% - 0.65%
- **高ボラティリティ（変動時）**: 0.65% - 1.00%

## 🚀 セットアップ

### 前提条件

- Foundry（forge, cast, anvil）
- Git BASH（Windows）またはターミナル（Mac/Linux）

### インストール手順

#### 1. Git BASHを開く

プロジェクトディレクトリで右クリック → 「Git Bash Here」

#### 2. セットアップスクリプトを実行

```bash
chmod +x setup.sh
./setup.sh
```

これにより以下が実行されます：
- Foundryプロジェクトの初期化
- Uniswap v4依存関係のインストール
- OpenZeppelin契約のインストール

#### 3. ビルド

```bash
forge build
```

#### 4. テスト

```bash
forge test -vvv
```

## 📁 プロジェクト構造

```
uniswap-v4-dynamic-fee-hook/
├── src/
│   └── VolatilityDynamicFeeHook.sol    # メインのHook契約
├── test/
│   └── VolatilityDynamicFeeHook.t.sol  # テストファイル
├── script/
│   └── Deploy.s.sol                     # デプロイスクリプト
├── foundry.toml                         # Foundry設定
├── setup.sh                             # セットアップスクリプト
└── README.md                            # このファイル
```

## 🔧 主要機能

### 1. ボラティリティ計算

過去10回のスワップ価格を記録し、平均変動率を計算します。

### 2. 動的手数料調整

ボラティリティに応じて0.05%～1.0%の範囲で手数料を自動調整します。

### 3. リアルタイム更新

各スワップごとに価格履歴を更新し、次のスワップで新しい手数料を適用します。

## 📊 使用方法

### Hook契約のデプロイ

```bash
forge script script/Deploy.s.sol --rpc-url sepolia --broadcast
```

### 現在の手数料を確認

```solidity
uint24 currentFee = hook.getCurrentFee(poolKey);
```

### 価格履歴を取得

```solidity
uint160[] memory history = hook.getPriceHistory(poolKey);
```

## ⚠️ 注意事項

- このHookはDynamic Feeが有効なプールでのみ使用できます
- プール作成時に`LPFeeLibrary.DYNAMIC_FEE_FLAG`を設定する必要があります
- テストネットで十分にテストしてからメインネットにデプロイしてください

## 🧪 テスト

包括的なテストスイートが含まれています：

```bash
# すべてのテストを実行
forge test

# 詳細な出力で実行
forge test -vvv

# ガスレポートを表示
forge test --gas-report

# カバレッジを確認
forge coverage
```

## 📝 ライセンス

MIT License

## 🔗 参考リソース

- [Uniswap v4 公式ドキュメント](https://docs.uniswap.org/contracts/v4/overview)
- [Dynamic Fees ガイド](https://docs.uniswap.org/contracts/v4/concepts/dynamic-fees)
- [Foundry Book](https://book.getfoundry.sh/)
