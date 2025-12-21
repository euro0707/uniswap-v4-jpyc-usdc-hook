#!/bin/bash

# Uniswap v4 Dynamic Fee Hook プロジェクトセットアップスクリプト

echo "🚀 Foundryプロジェクトを初期化中..."
forge init --force .

echo "📦 Uniswap v4 依存関係をインストール中..."
forge install Uniswap/v4-core
forge install Uniswap/v4-periphery
forge install OpenZeppelin/openzeppelin-contracts

echo "✅ セットアップ完了！"
echo ""
echo "次のステップ:"
echo "1. src/VolatilityDynamicFeeHook.sol を実装"
echo "2. test/VolatilityDynamicFeeHook.t.sol でテスト"
echo "3. forge build でビルド"
echo "4. forge test でテスト実行"
