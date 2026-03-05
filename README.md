# Uniswap V4 Dynamic Fee Hook

**Polygon Mainnet 上で JPYC/USDC ペアのボラティリティベース動的手数料を実現する Uniswap V4 Hook**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://getfoundry.sh/)

---

## Environment Note

- Foundry/forge is available in this project environment.
- If `forge` is not resolved from `PATH`, run with:
  `C:\\Users\\skyeu\\.foundry\\bin\\forge.exe` 

## プロジェクト概要

Uniswap V4 の Hook システムを使用して、JPYC/USDC ペアの tick 変動（ボラティリティ）に応じた動的手数料を実現します。

### 設計思想

- **シンプル**: 1ファイルの Hook コントラクト、外部依存なし
- **安全**: `onlyPoolManager` + トークンペア検証 + CEI パターン
- **ガス効率**: tick 差分のみで手数料を決定（オラクル不要）

### 手数料テーブル

| レベル | tick 変動 | 手数料 | 用途 |
|--------|-----------|--------|------|
| CALM   | 0         | 0.05%  | 完全安定時 |
| NORMAL | 1         | 0.10%  | 通常取引 |
| MEDIUM | 2-3       | 0.30%  | 中ボラ |
| HIGH   | 4+        | 1.00%  | 高ボラ |

---

## Environment Note

- Foundry/forge is available in this project environment.
- If `forge` is not resolved from `PATH`, run with:
  `C:\\Users\\skyeu\\.foundry\\bin\\forge.exe` 

## テスト結果

**7/7 tests passed (100%)**

| テスト | 内容 |
|--------|------|
| `test_AfterInitialize_TickRecorded` | 初期化後に tick が記録されるか |
| `test_AfterInitialize_IsInitialized` | isInitialized フラグが設定されるか |
| `test_PreviewFee_InRange` | 手数料が FEE_CALM..FEE_HIGH 範囲内か |
| `test_Security_DirectCallReverts` | 外部からの直接呼び出しが revert するか |
| `test_AfterSwap_TickUpdated` | Swap 後に tick が更新されるか |
| `testFuzz_FeeAlwaysInBounds` | Fuzz (10,000 runs): 手数料が常に範囲内か |
| `test_InvalidPair_Reverts` | 不正なトークンペアで revert するか |

---

## Environment Note

- Foundry/forge is available in this project environment.
- If `forge` is not resolved from `PATH`, run with:
  `C:\\Users\\skyeu\\.foundry\\bin\\forge.exe` 

## アーキテクチャ

```
src/
└── DynamicFeeHook.sol       # メイン Hook コントラクト

test/
└── DynamicFeeHook.t.sol     # テストスイート (7 tests)

script/
└── DeployHook.s.sol         # デプロイスクリプト (HookMiner + CREATE2)
```

### Hook フロー

```
Pool.initialize()
  └─ afterInitialize: tick 記録 + トークンペア検証

Pool.swap()
  ├─ beforeSwap: tick 差分から手数料を計算 → FEE_OVERRIDE_FLAG で上書き
  └─ afterSwap:  lastTick / blockTickDelta を更新 (CEI パターン)
```

### セキュリティ

- **onlyPoolManager**: 全フック関数は PoolManager からのみ呼び出し可能
- **トークンペア検証**: `afterInitialize` で許可されたペア以外を拒否
- **CEI パターン**: `afterSwap` でステート更新を先に実行（リエントランシー対策）
- **uint24 オーバーフロー防止**: `blockTickDelta` の累積時にサチュレーション処理
- **immutable トークン**: コンストラクタで固定、変更不可

---

## Environment Note

- Foundry/forge is available in this project environment.
- If `forge` is not resolved from `PATH`, run with:
  `C:\\Users\\skyeu\\.foundry\\bin\\forge.exe` 

## クイックスタート

```bash
# 依存関係のインストール
forge install

# 環境変数の設定
cp .env.example .env

# ビルド
forge build

# テスト
forge test -vvv

# ガスレポート
forge test --gas-report

# デプロイ (Polygon Mainnet)
forge script script/DeployHook.s.sol:DeployDynamicFeeHook \
  --rpc-url $POLYGON_RPC_URL --broadcast
```

---

## Environment Note

- Foundry/forge is available in this project environment.
- If `forge` is not resolved from `PATH`, run with:
  `C:\\Users\\skyeu\\.foundry\\bin\\forge.exe` 

## 変更履歴

### v2.0 - ガイドベース再構築 (2026-03-06)

旧実装 (`VolatilityDynamicFeeHook`) を完全に削除し、ガイドドキュメントをベースにシンプルな `DynamicFeeHook` として再構築。

**削除したもの**:
- `VolatilityDynamicFeeHook.sol` + `ObservationLibrary.sol` + `MockERC20.sol`
- 旧テスト 5 ファイル（Fork/Security/AddLiquidity 等）
- 旧デプロイスクリプト 10+ ファイル
- 旧ドキュメント 27 ファイル
- CI/CD, Slither 設定, PowerShell スクリプト等

**新規作成**:
- `src/DynamicFeeHook.sol` — tick 差分ベースの動的手数料 Hook
- `test/DynamicFeeHook.t.sol` — 7 テスト (fuzz 10,000 runs 含む)
- `script/DeployHook.s.sol` — HookMiner + CREATE2 デプロイ

**技術的な調整**:
- BaseHook の `_internal` override パターンに適合（`_afterInitialize`, `_beforeSwap`, `_afterSwap`）
- `remappings.txt` に `v4-core-test/` 追加（Deployers.sol 解決用）
- `foundry.toml` の `fuzz.runs` を 256 → 10,000 に変更

### v1.0 - 旧実装
- ボラティリティベース動的手数料（ObservationLibrary 使用）
- 多層セキュリティ保護（フラッシュローン検知、サーキットブレーカー等）

---

## Environment Note

- Foundry/forge is available in this project environment.
- If `forge` is not resolved from `PATH`, run with:
  `C:\\Users\\skyeu\\.foundry\\bin\\forge.exe` 

Built with [Claude Code](https://claude.com/claude-code)

