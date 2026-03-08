# Uniswap v4 Dynamic Fee Hook (JPYC/USDC on Polygon)

Polygon Mainnet 上の `JPYC/USDC` 向けに、Uniswap v4 Hook で動的手数料を実装・運用するリポジトリです。

## はじめての人向け最短手順

「とりあえず動かしたい」場合は、この3ステップだけ見れば進められます。

1. `.env.example` を `.env` にコピーして、`DEPLOYER_PRIVATE_KEY` と `POLYGON_RPC_URL` を設定する
2. `forge script ...CreateHookPoolAndMint --rpc-url polygon -vv` で dry-run する
3. 問題なければ `--broadcast` を付けて本番送信する

成功すると:

- Wallet に LP ポジション NFT が増える
- Uniswap UI の Positions で `v4` の USDC/JPYC ポジションが表示される

## 何ができるか

このリポジトリでできることを、できるだけ簡単に言うと次の3つです。

1. 「手数料ルール付きのプール」を作れます。  
通常のプールではなく、Hook（追加ルール）付きのプールを作成できます。

2. そのプールに「流動性」を入れられます。  
USDC と JPYC を預けて、LP ポジション（NFT）を作成できます。

3. 本番送信前に「リハーサル」ができます。  
`dry-run` で結果を先に確認してから、`--broadcast` で本番実行できます。

補足（用語ミニ説明）:

- Hook: Uniswap v4 で手数料や挙動を追加できる仕組み
- Pool: トークンを交換するための市場
- LP: Pool に資金を預ける人（Liquidity Provider）

## 現在の運用対象（本番）

- Chain: Polygon Mainnet (`137`)
- PoolManager: `0x67366782805870060151383F4BbFF9daB53e5cD6`
- PositionManager: `0x1eC2EbF4f37e7363FDfE3551602425af0B3CeEF9`
- StateView: `0x5Ea1bD7974C8A611cBAb0BDCAFCb1D9cc9B3BA5A`
- Active Hook: `0x1D4D185b1D0f86561f1D24DE10E7473e2772d0C0`
- Active Pair: USDC `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` / JPYC `0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29`

## リポジトリ構成

- `src/DynamicFeeHook.sol`: メイン hook コントラクト
- `script/DeployHook.s.sol`: hook デプロイスクリプト
- `script/CreateHookPoolAndMint.s.sol`: hook pool 初期化 + LP mint スクリプト
- `test/DynamicFeeHook.t.sol`: ユニットテスト

## 前提

- Foundry インストール済み
- Polygon RPC が利用可能
- 実行ウォレットに `POL`（ガス）と `USDC/JPYC`（LP原資）がある

`forge` が PATH にない環境では以下を使ってください。

```powershell
C:/Users/skyeu/.foundry/bin/forge.exe
```

## セットアップ

```powershell
copy .env.example .env
```

`.env` の最低必須項目:

- `DEPLOYER_PRIVATE_KEY`
- `POLYGON_RPC_URL`
- `POSITION_MANAGER`
- `STATE_VIEW`

LP mint 量は以下で制御します（上限値）。

- `USDC_MAX`（6 decimals）
- `JPYC_MAX`（18 decimals）

## 1) Build / Test

```powershell
forge build
forge test -vv
```

## 2) Hook をデプロイ

```powershell
forge script script/DeployHook.s.sol:DeployDynamicFeeHook --rpc-url polygon --broadcast -vvvv
```

ポイント:

- `DeployHook.s.sol` は `POOL_MANAGER`, `CREATE2_DEPLOYER`, `ACTIVE_USDC_ADDRESS`, `ACTIVE_JPYC_ADDRESS` を `.env` で上書き可能
- 出力される hook アドレスと `HookMiner` で見つけたアドレスが一致しない場合は失敗します

## 3) Hook Pool を作成して LP mint

まず dry-run:

```powershell
forge script script/CreateHookPoolAndMint.s.sol:CreateHookPoolAndMint --rpc-url polygon -vv
```

問題なければ本番実行:

```powershell
forge script script/CreateHookPoolAndMint.s.sol:CreateHookPoolAndMint --rpc-url polygon --broadcast -vvvv
```

スクリプトの挙動:

- 参照用の通常プール（fee `500`）から `sqrtPriceX96` を取得
- hook pool 未初期化なら `initializePool`
- Permit2 approve 後に `modifyLiquidities`（`MINT_POSITION + SETTLE_PAIR`）

## 4) 実行後の確認

推奨確認項目:

- `cast receipt <txHash> --rpc-url polygon` で `status = 1`
- `PositionManager.ownerOf(tokenId)` が実行ウォレット
- Uniswap UI で対象ポジションが `v4` / 対象 hook で表示される

## よくあるエラー

- `Failed to decode private key`
  - `.env` の `DEPLOYER_PRIVATE_KEY` が不正（`0x` + 64 hex 以外）
- `insufficient USDC for mint` / `insufficient JPYC for mint`
  - `USDC_MAX` / `JPYC_MAX` が残高を超えている
- ガス不足で失敗
  - `POL` を追加して再実行

## セキュリティ運用メモ

- 秘密鍵とリカバリーフレーズは、チャット・Issue・PR・リポジトリに貼らない
- `.env` はローカル専用（`.env.example` はサンプルのみ）
- 本番送信は専用ウォレットを使い、必要最小限の資金だけ入れる
- `--broadcast` 前に chain / token / hook アドレスを毎回再確認する
- 本番前に必ず dry-run を実行する

## 参考ドキュメント

- `reports/2026-03-07-prod-deploy-readiness.md`（デプロイ記録）
- `reports/` 配下のメモは運用ログです。将来の実装と一致しない場合があるため、実行時は本READMEとスクリプトを優先してください。
