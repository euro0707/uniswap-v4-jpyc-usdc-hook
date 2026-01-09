# Sepolia Testnet Deployment Guide

このガイドでは、VolatilityDynamicFeeHookをEthereum Sepolia TestnetにデプロイしてUniswap V4で動作検証する手順を説明します。

## 前提条件

### 1. 必要なツールとアカウント

- **Foundry** (forge, cast, anvil)のインストール
- **Sepolia ETH** (テストネット用ETH)
  - Faucet: https://sepoliafaucet.com/
  - または https://www.alchemy.com/faucets/ethereum-sepolia
- **Alchemy/Infura アカウント** (RPC endpoint用)
- **Etherscan API Key** (コントラクト検証用)
  - https://etherscan.io/myapikey

### 2. テストトークンの準備

Sepolia testnet上で使用する2つのERC-20トークンが必要です：

**オプション A: 既存のテストトークンを使用**
- Sepolia上の既存のテストUSDC/DAI等を使用

**オプション B: 独自のテストトークンをデプロイ**
```solidity
// SimpleERC20.sol
contract TestToken is ERC20 {
    constructor() ERC20("Test Token", "TST") {
        _mint(msg.sender, 1000000 * 10**18);
    }
}
```

## デプロイ手順

### Step 1: 環境変数の設定

`.env`ファイルを作成（`.env.example`をコピー）：

```bash
cp .env.example .env
```

`.env`ファイルを編集：

```bash
# RPC Endpoints
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_ALCHEMY_API_KEY

# Etherscan API Key (for contract verification)
ETHERSCAN_API_KEY=YOUR_ETHERSCAN_API_KEY

# Deployment
DEPLOYER_PRIVATE_KEY=YOUR_PRIVATE_KEY_HERE

# Test Tokens (Sepolia)
TOKEN0_ADDRESS=0x...  # 後で設定
TOKEN1_ADDRESS=0x...  # 後で設定
HOOK_ADDRESS=0x...    # 後で設定
```

⚠️ **セキュリティ警告**:
- `.env`ファイルは絶対にGitにコミットしないでください
- メインネットの秘密鍵は使用しないでください
- テスト用の新しいウォレットを作成することを推奨します

### Step 2: デプロイアカウントの準備

デプロイアドレスを確認：

```bash
cast wallet address --private-key $DEPLOYER_PRIVATE_KEY
```

Sepolia ETHを取得（最低0.1 ETH推奨）：
- https://sepoliafaucet.com/

残高確認：

```bash
cast balance YOUR_ADDRESS --rpc-url $SEPOLIA_RPC_URL
```

### Step 3: Hookコントラクトのデプロイ

コンパイル確認：

```bash
forge build
```

ドライラン（シミュレーション）：

```bash
forge script script/DeployHookSepolia.s.sol:DeployHookSepolia \
    --rpc-url sepolia \
    --private-key $DEPLOYER_PRIVATE_KEY \
    -vvvv
```

実際にデプロイ：

```bash
forge script script/DeployHookSepolia.s.sol:DeployHookSepolia \
    --rpc-url sepolia \
    --private-key $DEPLOYER_PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv
```

デプロイされたHookアドレスをメモし、`.env`の`HOOK_ADDRESS`に設定してください。

### Step 4: プールの初期化

`.env`にトークンアドレスとHookアドレスを設定後：

```bash
forge script script/InitializePoolSepolia.s.sol:InitializePoolSepolia \
    --rpc-url sepolia \
    --private-key $DEPLOYER_PRIVATE_KEY \
    --broadcast \
    -vvvv
```

## Uniswap V4 Sepolia Testnet Addresses

プロジェクトで使用するUniswap V4コントラクト：

| Contract | Address |
|----------|---------|
| PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| PositionManager | `0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4` |
| StateView | `0xe1dd9c3fa50edb962e442f60dfbc432e24537e4c` |
| Quoter | `0x61b3f2011a92d183c7dbadbda940a7555ccf9227` |
| PoolSwapTest | `0x9b6b46e2c869aa39918db7f52f5557fe577b6eee` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

出典: [Uniswap V4 Deployments Documentation](https://docs.uniswap.org/contracts/v4/deployments)

## 動作検証

### 1. コントラクトの確認

Sepolia Etherscanでデプロイを確認：

```
https://sepolia.etherscan.io/address/YOUR_HOOK_ADDRESS
```

### 2. テストスワップの実行

PoolSwapTestコントラクトを使用してテストスワップを実行：

```bash
cast send $POOL_SWAP_TEST "swap(...)" \
    --rpc-url sepolia \
    --private-key $DEPLOYER_PRIVATE_KEY
```

### 3. 動的手数料の確認

StateViewコントラクトを使用してプールの状態を確認：

```bash
cast call $STATE_VIEW "getPoolState(bytes32)" $POOL_ID \
    --rpc-url sepolia
```

### 4. イベントログの監視

Hook契約から発行されるイベントを監視：

```bash
cast logs --address $HOOK_ADDRESS \
    --from-block latest \
    --rpc-url sepolia
```

主要イベント:
- `ObservationRecorded`: 価格観測の記録
- `DynamicFeeCalculated`: 動的手数料の計算
- `CircuitBreakerTriggered`: サーキットブレーカーの発動
- `CircuitBreakerAutoReset`: サーキットブレーカーの自動リセット
- `ObservationRingReset`: リングバッファのリセット（staleness recovery）

## テストシナリオ

### 基本機能テスト

1. **正常なスワップ**
   - 小額のスワップを実行
   - ObservationRecordedイベントを確認
   - 動的手数料が計算されることを確認

2. **価格変動時の動的手数料**
   - 複数のスワップを実行して価格を変動させる
   - ボラティリティの増加に応じて手数料が上昇することを確認

3. **サーキットブレーカー**
   - 10%以上の急激な価格変動を発生させる
   - CircuitBreakerTriggeredイベントを確認
   - 1時間後に自動リセットされることを確認

4. **Staleness Recovery**
   - 30分以上取引がない状態にする
   - 次のスワップでObservationRingResetイベントが発行されることを確認

### セキュリティテスト

1. **Flash Loan攻撃耐性**
   - 同一ブロック内での複数スワップを試行
   - validateMultiBlockによって適切に検証されることを確認

2. **価格操作耐性**
   - 大量の取引で価格を操作しようとする
   - サーキットブレーカーが発動することを確認

## トラブルシューティング

### デプロイエラー

**Error: Insufficient funds**
- Faucetから追加のSepolia ETHを取得してください

**Error: Contract creation failed**
- gas limitを増やす: `--gas-limit 5000000`を追加

**Error: Verification failed**
- 手動で検証: `forge verify-contract`コマンドを使用

### プール初期化エラー

**Error: Hook address validation failed**
- Hookアドレスが正しいフラグビットを持っているか確認
- Uniswap V4のHookアドレス要件を満たしているか確認

**Error: Currency ordering**
- TOKEN0 < TOKEN1の順序になっているか確認（アドレスの数値的順序）

## 次のステップ

テストネットで動作確認が完了したら：

1. ✅ 全テストシナリオをパス
2. ✅ セキュリティ監査レポートの確認
3. ⏭️ メインネットデプロイの準備
   - 外部セキュリティ監査（推奨）
   - バグバウンティプログラムの検討
   - 段階的ロールアウト計画

## 参考リンク

- [Uniswap V4 Documentation](https://docs.uniswap.org/contracts/v4/overview)
- [Uniswap V4 Deployments](https://docs.uniswap.org/contracts/v4/deployments)
- [Foundry Book](https://book.getfoundry.sh/)
- [Sepolia Faucet](https://sepoliafaucet.com/)
- [Alchemy Sepolia Faucet](https://www.alchemy.com/faucets/ethereum-sepolia)

## サポート

問題が発生した場合：
1. Foundryのバージョンを確認: `forge --version`
2. キャッシュをクリア: `forge clean`
3. 再ビルド: `forge build`
4. GitHubのIssuesで報告
