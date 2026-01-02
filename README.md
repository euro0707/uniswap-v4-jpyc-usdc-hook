# Uniswap V4 JPYC/USDC Auto-Compound JIT Hook

**Polygon Mainnet上でJPYC/USDCペアの自動複利運用を実現するUniswap V4 Hook**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://getfoundry.sh/)

---

## 🎯 プロジェクト概要

Uniswap V4のHookシステムを使用して、JPYC/USDCペアの流動性提供を自動化・最適化します。

### 主要機能

- 🎢 **ボリンジャーバンド動的レンジ調整** - 24時間2σバンドで自動リバランス
- ⚡ **JIT流動性** - Just-in-Time流動性で資本効率を最大化
- 🔄 **自動複利** - 手数料収益を自動的に再投資
- 💰 **動的手数料** - ボラティリティに応じた手数料調整
- 🔒 **セキュリティ保護** - 価格操作保護、緊急停止機能

**ガスコスト（Polygon）:** ~$27/月 | **最小流動性:** $500から開始可能

---

## 📊 テスト結果

✅ **30/30 tests passed (100%)**
- 15 コア機能テスト
- 5 フォークテスト
- 10 セキュリティテスト

---

## 🚀 クイックスタート

bash
forge install
cp .env.example .env
forge test


詳細は[ドキュメント](IMPLEMENTATION_PLAN_PRODUCTION.md)を参照してください。

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
