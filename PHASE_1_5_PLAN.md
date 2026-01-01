# Phase 1.5: Hook基本機能実装プラン

## 概要

VolatilityDynamicFeeHookにBollingerBandsライブラリを統合し、動的レンジ調整機能を実装します。

---

## 実装内容

### 1. Hook構造の変更

#### 現在の実装
```solidity
struct PriceHistory {
    uint160[] prices;        // 動的配列
    uint256[] timestamps;    // 動的配列  
    uint256 index;
    uint256 count;
    uint256 lastUpdateTime;
}
```

#### 新しい実装
```solidity
import {ObservationLibrary} from "./libraries/ObservationLibrary.sol";
import {BollingerBands} from "./libraries/BollingerBands.sol";

// プールごとの状態管理
mapping(PoolId => ObservationLibrary.RingBuffer) public observations;
mapping(PoolId => BollingerBands.Config) public bbConfig;
mapping(PoolId => uint256) public lastRebalanceTime;
```

---

### 2. 初期化処理の変更

#### 修正箇所: `_afterInitialize()`

```solidity
function _afterInitialize(
    address,
    PoolKey calldata key,
    uint160 sqrtPriceX96,
    int24
) internal override returns (bytes4) {
    if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
    
    PoolId poolId = key.toId();
    
    // Bollinger Bands設定を初期化
    bbConfig[poolId] = BollingerBands.Config({
        period: 24,              // 24時間（24個の観測）
        standardDeviation: 200,  // 2.0σ
        timeframe: 86400,        // 24時間（秒）
        softBandBps: 180         // 1.8σ
    });
    
    // 初期観測を追加
    ObservationLibrary.push(
        observations[poolId],
        block.timestamp,
        sqrtPriceX96
    );
    
    lastRebalanceTime[poolId] = block.timestamp;
    
    return BaseHook.afterInitialize.selector;
}
```

---

### 3. スワップ後処理の変更

#### 修正箇所: `_afterSwap()`

```solidity
function _afterSwap(
    address,
    PoolKey calldata key,
    SwapParams calldata,
    BalanceDelta,
    bytes calldata
) internal override returns (bytes4, int128) {
    PoolId poolId = key.toId();
    
    // 最小更新間隔チェック（1時間）
    ObservationLibrary.RingBuffer storage obs = observations[poolId];
    if (obs.count > 0) {
        uint256 lastTimestamp = obs.data[(obs.index + 99) % 100].timestamp;
        if (block.timestamp < lastTimestamp + MIN_UPDATE_INTERVAL) {
            return (BaseHook.afterSwap.selector, 0);
        }
    }
    
    // 現在価格を取得
    (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
    
    // 観測を追加
    ObservationLibrary.push(obs, block.timestamp, sqrtPriceX96);
    
    // BB計算が可能か確認（24個以上の観測が必要）
    if (obs.count >= bbConfig[poolId].period) {
        // Bollinger Bandsを計算
        BollingerBands.Bands memory bands = BollingerBands.calculate(
            obs,
            bbConfig[poolId]
        );
        
        // 現在価格がバンド外かチェック
        int24 currentTick = _getCurrentTick(poolId);
        (bool isOutside, bool isAbove) = BollingerBands.isOutOfBands(
            currentTick,
            bands
        );
        
        // バンド外の場合、リバランスをトリガー
        if (isOutside) {
            _triggerRebalance(poolId, bands, isAbove);
        }
    }
    
    return (BaseHook.afterSwap.selector, 0);
}
```

---

### 4. 新しいヘルパー関数

```solidity
/// @notice Get current tick for pool
function _getCurrentTick(PoolId poolId) internal view returns (int24) {
    (, int24 tick,,) = poolManager.getSlot0(poolId);
    return tick;
}

/// @notice Trigger rebalance when price is out of bands
/// @dev Emits event for off-chain keeper to execute rebalance
function _triggerRebalance(
    PoolId poolId,
    BollingerBands.Bands memory bands,
    bool isAbove
) internal {
    // Check cooldown period (2 hours)
    if (block.timestamp < lastRebalanceTime[poolId] + REBALANCE_COOLDOWN) {
        return;
    }
    
    lastRebalanceTime[poolId] = block.timestamp;
    
    // Emit event for keeper
    emit RebalanceTriggered(poolId, bands.upper, bands.middle, bands.lower, isAbove);
}

/// @notice Get Bollinger Bands for pool
function getBollingerBands(PoolId poolId) 
    external 
    view 
    returns (BollingerBands.Bands memory) 
{
    require(observations[poolId].count >= bbConfig[poolId].period, "Insufficient data");
    return BollingerBands.calculate(observations[poolId], bbConfig[poolId]);
}
```

---

### 5. イベント定義

```solidity
/// @notice Emitted when price goes out of Bollinger Bands
event RebalanceTriggered(
    PoolId indexed poolId,
    int24 upperBand,
    int24 middleBand,
    int24 lowerBand,
    bool isAbove
);

/// @notice Emitted when new observation is recorded
event ObservationRecorded(
    PoolId indexed poolId,
    uint256 timestamp,
    uint160 sqrtPriceX96,
    uint256 observationCount
);
```

---

## テストケース

### 新規追加テスト

1. **test_bollingerBands_calculation()**
   - 24個の観測後にBB計算が成功
   - 上限・中央・下限が正しく計算される

2. **test_bollingerBands_outOfBands()**
   - 価格が2σ外に出た場合にリバランスイベント発火
   - クールダウン期間中は再発火しない

3. **test_bollingerBands_softZone()**
   - 1.8σ～2σの間でソフトゾーン検出
   - 警告レベルの処理

4. **test_bollingerBands_insufficientData()**
   - 24個未満の観測ではBB計算をスキップ
   - エラーにならず正常動作

---

## マイグレーション手順

### Step 1: 既存テストの確認
```bash
forge test --match-contract VolatilityDynamicFeeHook -vvv
# 現在: 21/21 tests passed
```

### Step 2: 新しい実装に切り替え
- src/VolatilityDynamicFeeHook.sol を更新
- 既存のPriceHistory構造を削除
- ObservationLibrary使用に切り替え

### Step 3: 既存テストの修正
- getPriceHistory() → observations へのアクセス変更
- 必要に応じてテストロジック調整

### Step 4: 新しいテスト追加
- test/BollingerBandsHook.t.sol 作成
- 上記4つのテストケースを実装

### Step 5: 統合テスト
```bash
forge test -vvv
# 目標: 25+/25+ tests passed
```

---

## 期待される成果物

- ✅ src/VolatilityDynamicFeeHook.sol（BB統合版）
- ✅ test/BollingerBandsHook.t.sol（新規テスト）
- ✅ 既存テスト21件すべて通過
- ✅ 新規テスト4件すべて通過

---

## 次のPhase 2への準備

Phase 2では以下を実装：
- JIT流動性管理
- 自動リバランス実行
- PositionManager統合

このPhase 1.5で、リバランスの「トリガー」までを実装し、実際の流動性操作はPhase 2で行います。

---

**作成日:** 2026-01-02
**ステータス:** 設計完了、実装準備完了
