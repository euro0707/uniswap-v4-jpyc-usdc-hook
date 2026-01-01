# 🚀 本番環境デプロイ版実装計画（外部監査含む完全版）

**プロジェクト:** Uniswap V4 自動複利JITフック
**対象:** Polygon JPYC/USDC
**目標:** APR 66.2%（3年で$10k → $46k）
**実装期間:** 3.5-4ヶ月（外部監査含む）
**最終更新:** 2025-12-24

---

## 📊 全体スケジュール概要

```
Phase 0:  準備・検証                → 2日
Phase 1:  ボリンジャーバンド          → 2日
Phase 1.5: フック基本機能            → 1.5日
Phase 2:  JIT流動性+リバランス       → 3日
Phase 2.5: セキュリティ機能          → 2日
Phase 3:  自動複利                  → 2日
Phase 4:  オラクル拡張              → 1日
Phase 5:  テスト・最適化            → 6.5日
Phase 6:  デプロイ基盤              → 3.5日
Phase 7:  外部監査 ★必須★           → 5-7週間
Phase 8:  ドキュメント              → 3日
Phase 9:  フロントエンド（任意）      → 2週間
Phase 10: 法務・コンプライアンス      → 1週間
Phase 11: 本番デプロイ              → 1日

合計: 約3.5-4ヶ月（フロントエンド含む場合5ヶ月）
```

**予算:**
- 外部監査: $20,000 - $80,000（中堅 → Trail of Bits）
- インフラ: $100-300/月（Tenderly, The Graph, Alchemy）
- 法務相談: $5,000 - $15,000（任意）
- **合計: $25,000 - $95,000 + 運用コスト**

---

## Phase 0: 準備・検証（2日）

### Phase 0.1: 依存ライブラリのセットアップ

**実装内容:**

1. **foundry.tomlの設定**
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.26"
optimizer = true
optimizer_runs = 1000000
via_ir = true
evm_version = "cancun"

[profile.production]
optimizer_runs = 10000000
via_ir = true

[rpc_endpoints]
polygon = "${POLYGON_RPC_URL}"
mumbai = "${MUMBAI_RPC_URL}"

[etherscan]
polygon = { key = "${POLYGONSCAN_API_KEY}" }
mumbai = { key = "${POLYGONSCAN_API_KEY}" }
```

2. **依存関係のインストール**
```bash
# OpenZeppelin Contracts (ReentrancyGuard, Ownable, Pausable)
forge install OpenZeppelin/openzeppelin-contracts@v5.0.0

# Chainlink Contracts (AggregatorV3Interface)
forge install smartcontractkit/chainlink@v0.8.0

# Uniswap V4 Core & Periphery (既存)
forge install Uniswap/v4-core
forge install Uniswap/v4-periphery

# Forge Standard Library (既存)
forge install foundry-rs/forge-std
```

3. **remappings.txtの作成**
```
@openzeppelin/=lib/openzeppelin-contracts/
@chainlink/=lib/chainlink/
@uniswap/v4-core/=lib/v4-core/
@uniswap/v4-periphery/=lib/v4-periphery/
forge-std/=lib/forge-std/src/
```

**成果物:**
- `foundry.toml` (完全版)
- `remappings.txt`
- `.env.example`（RPC URL、API Key用）
- `package.json`（Node.js依存関係）

**検証:**
```bash
forge build --sizes
forge test --gas-report
```

**所要時間:** 0.5日

---

### Phase 0.2: JPYC/USDCプール存在確認

**実装内容:**

1. **Polygon Mainnet調査**
```bash
# Uniswap V4のデプロイ状況確認
cast call $POOL_MANAGER_ADDRESS "getPool(bytes32)" $POOL_ID --rpc-url $POLYGON_RPC_URL

# JPYCトークンアドレス: 0x6ae7dfc73e0dde2aa99ac063dcf7e8a63265108c
# USDCトークンアドレス: 0x2791bca1f2de4661ed88a30c99a7a9449aa84174
```

2. **プールが存在しない場合の対処**
   - Uniswap V4がPolygonに未デプロイ → Arbitrum/Optimismへの移行検討
   - プールが未作成 → 初期流動性提供計画（最低$50k推奨）
   - V4以外のDEX検討（Quickswap V3など）

3. **フォークテスト用の設定**
```solidity
// test/ForkTestPolygon.t.sol
contract ForkTestPolygon is Test {
    uint256 polygonFork;

    function setUp() public {
        polygonFork = vm.createFork(vm.envString("POLYGON_RPC_URL"));
        vm.selectFork(polygonFork);

        // プールの存在確認
        address poolManager = 0x... ; // Polygon上のアドレス
        PoolId poolId = PoolId.wrap(
            keccak256(abi.encode(JPYC, USDC, fee, tickSpacing, hooks))
        );

        (bool exists, ) = poolManager.getPool(poolId);
        require(exists, "JPYC/USDC pool not found");
    }
}
```

**成果物:**
- `POOL_VERIFICATION_REPORT.md`（調査結果）
- `ForkTestPolygon.t.sol`（フォークテストベース）
- プールが存在しない場合の代替案

**所要時間:** 0.5日

---

### Phase 0.3: 既存コードの統合

**実装内容:**

1. **ディレクトリ構造の整理**
```
src/
├── AutoCompoundJITHook.sol          # メインフック（新規）
├── libraries/
│   ├── VolatilityCalculator.sol     # 既存から移行
│   ├── BollingerBands.sol           # Phase 1で実装
│   ├── JITLiquidity.sol             # Phase 2で実装
│   └── AutoCompounder.sol           # Phase 3で実装
├── interfaces/
│   ├── IAutoCompoundJITHook.sol
│   └── IChainlinkPriceFeed.sol
└── base/
    └── BaseHook.sol                 # 共通機能
```

2. **既存の`VolatilityDynamicFeeHook.sol`からの移行**
```solidity
// VolatilityCalculator.sol（ライブラリ化）
library VolatilityCalculator {
    function calculateVolatility(
        ObservationLibrary.Observation[100] storage observations,
        uint256 currentIndex
    ) internal view returns (uint256) {
        // 既存の_calculateVolatility()ロジックを移植
    }

    function getFeeBasedOnVolatility(uint256 volatility)
        internal pure returns (uint24)
    {
        // 既存の_getFeeBasedOnVolatility()ロジックを移植
    }
}
```

3. **テストの移行**
```bash
# 既存の16テストをすべてパス確認
forge test --match-contract VolatilityDynamicFeeHook -vvv
```

**成果物:**
- リファクタリングされた`libraries/VolatilityCalculator.sol`
- 既存テスト16件すべてパス
- ガスレポート（最適化前ベースライン）

**所要時間:** 1日

---

## Phase 1: ボリンジャーバンド計算（2日）

### 実装内容

**1. ライブラリの実装**
```solidity
// libraries/BollingerBands.sol
library BollingerBands {
    struct Config {
        uint256 period;              // 20（移動平均の期間）
        uint256 standardDeviation;   // 200（2σ = 2.0 * 100）
        uint256 timeframe;           // 86400秒（1日足）
    }

    struct Bands {
        int24 upper;    // 上限tick
        int24 middle;   // 中央tick（MA）
        int24 lower;    // 下限tick
        uint256 width;  // バンド幅（bps）
    }

    /// @notice ボリンジャーバンドを計算
    /// @param observations 価格観測データ（リングバッファ）
    /// @param config BB設定
    /// @return bands 計算されたバンド
    function calculate(
        ObservationLibrary.Observation[100] storage observations,
        Config memory config
    ) internal view returns (Bands memory bands) {
        // 1. 移動平均（MA）の計算
        uint256 sum = 0;
        uint256 count = 0;
        uint256 oldestTimestamp = block.timestamp - config.timeframe;

        for (uint256 i = 0; i < observations.length; i++) {
            if (observations[i].timestamp >= oldestTimestamp) {
                sum += observations[i].price;
                count++;
            }
        }
        require(count >= config.period, "Insufficient data");

        uint256 ma = sum / count;
        bands.middle = _priceToTick(ma);

        // 2. 標準偏差（σ）の計算
        uint256 varianceSum = 0;
        for (uint256 i = 0; i < count; i++) {
            uint256 price = observations[i].price;
            uint256 diff = price > ma ? price - ma : ma - price;
            varianceSum += diff * diff;
        }

        uint256 variance = varianceSum / count;
        uint256 stdDev = Math.sqrt(variance);

        // 3. バンド幅の計算（MA ± 2σ）
        uint256 upperPrice = ma + (stdDev * config.standardDeviation / 100);
        uint256 lowerPrice = ma - (stdDev * config.standardDeviation / 100);

        bands.upper = _priceToTick(upperPrice);
        bands.lower = _priceToTick(lowerPrice);
        bands.width = ((upperPrice - lowerPrice) * 10000) / ma; // bps

        return bands;
    }

    /// @notice バンドウォーク検出
    /// @dev 価格が連続してバンド上限/下限に張り付いているか
    function detectBandWalk(
        ObservationLibrary.Observation[5] storage recent,
        Bands memory bands
    ) internal view returns (bool isWalking) {
        uint256 upperCount = 0;
        uint256 lowerCount = 0;

        for (uint256 i = 0; i < 5; i++) {
            int24 tick = _priceToTick(recent[i].price);
            if (tick >= bands.upper) upperCount++;
            if (tick <= bands.lower) lowerCount++;
        }

        // 5回中4回以上で「バンドウォーク」判定
        return (upperCount >= 4 || lowerCount >= 4);
    }
}
```

**2. テストケース（8件）**

```solidity
// test/BollingerBands.t.sol
contract BollingerBandsTest is Test {
    function test_calculate_normal() public {
        // 通常時のボリンジャーバンド計算
        // 期待値: バンド幅 ±1.5%
    }

    function test_calculate_high_volatility() public {
        // 高ボラ時（急変時）
        // 期待値: バンド幅 ±2σ相当
    }

    function test_insufficient_data_reverts() public {
        // データ不足時のrevert確認
    }

    function test_band_walk_detection() public {
        // バンドウォーク検出
    }

    function test_ma_return_waiting() public {
        // MA復帰待機ロジック
    }

    function test_price_to_tick_conversion() public {
        // 価格→tick変換の精度
    }

    function test_emergency_mode_expansion() public {
        // 緊急モード時のバンド拡張（3σ）
    }

    function test_gas_efficiency() public {
        // ガス消費量測定（目標: <50k gas）
    }
}
```

**成果物:**
- `libraries/BollingerBands.sol`（~200行）
- `test/BollingerBands.t.sol`（8テスト）
- ガスレポート

**所要時間:** 2日

---

## Phase 1.5: フック基本機能（1.5日）

### 実装内容

**1. メインフックのスケルトン**
```solidity
// src/AutoCompoundJITHook.sol
contract AutoCompoundJITHook is
    BaseHook,
    ReentrancyGuard,
    Ownable,
    Pausable
{
    using BollingerBands for *;
    using VolatilityCalculator for *;
    using JITLiquidity for *;
    using AutoCompounder for *;

    // ========== Storage ==========

    struct PositionInfo {
        uint256 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 lastRebalanceTime;
        uint8 outOfBandCount; // 2σ外の連続回数（1時間ごと）
        uint256 totalFeesCompounded;
        bool active;
    }

    mapping(address => PositionInfo) public positions;

    BollingerBands.Config public bbConfig;
    ObservationLibrary.Observation[100] public observations;
    uint256 public lastObservationTime;
    int24 public lastObservedTick;

    // Chainlink価格フィード
    AggregatorV3Interface public chainlinkJPYC;
    AggregatorV3Interface public chainlinkUSDC;

    // ========== Constructor ==========

    constructor(
        IPoolManager _poolManager,
        address _chainlinkJPYC,
        address _chainlinkUSDC
    ) BaseHook(_poolManager) Ownable(msg.sender) {
        bbConfig = BollingerBands.Config({
            period: 24,             // 1時間足 × 24本
            standardDeviation: 200, // 2σ
            timeframe: 86400        // 24時間
        });

        chainlinkJPYC = AggregatorV3Interface(_chainlinkJPYC);
        chainlinkUSDC = AggregatorV3Interface(_chainlinkUSDC);
    }

    // ========== Hook Functions ==========

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        // 動的手数料の計算（ボラ/バンド幅に連動、5-80 bpsにクランプ）
        uint256 volatility = VolatilityCalculator.calculateVolatility(
            observations,
            currentIndex
        );

        uint24 dynamicFee = VolatilityCalculator.getFeeBasedOnVolatility(
            volatility
        );
        // Uniswap v4 fee units = hundredths of a bip (1e-6)
        if (dynamicFee < 500) dynamicFee = 500;   // 5 bps
        if (dynamicFee > 8000) dynamicFee = 8000; // 80 bps

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, dynamicFee);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, int128) {
        // 価格観測の記録
        _recordObservation(key);

        // リバランス条件チェック
        _checkRebalanceCondition(key);

        return (this.afterSwap.selector, 0);
    }

    function beforeAddLiquidity(...) external override returns (bytes4) {
        // JIT流動性追加前の処理
        return this.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(...) external override returns (bytes4, BalanceDelta) {
        // ポジション情報の記録
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // ========== Internal Functions ==========

    function _recordObservation(PoolKey calldata key) internal {
        // 1時間ごとの観測に制限（短期ノイズを排除）
        if (block.timestamp < lastObservationTime + 1 hours) return;
        lastObservationTime = block.timestamp;

        // 価格観測データをリングバッファに記録し、直近tickを保持
        // lastObservedTick は「2σ外が連続か」の判定に使う
        // lastObservedTick = _getCurrentTick(key);
    }

    function _isOutOfBand(int24 tick, BollingerBands.Bands memory bands)
        internal
        pure
        returns (bool)
    {
        return (tick <= bands.lower || tick >= bands.upper);
    }

    function _isNearBand(int24 tick, BollingerBands.Bands memory bands, uint256 softBandBps)
        internal
        pure
        returns (bool)
    {
        // softBandBps=180 は 1.8σ 相当の警戒域
        int24 range = bands.upper - bands.middle; // 2σ相当
        int24 softRange = int24(int256(range) * int256(softBandBps) / 200);
        int24 softLower = bands.middle - softRange;
        int24 softUpper = bands.middle + softRange;
        return (tick <= softLower || tick >= softUpper);
    }

    function _raiseFeeOnly() internal {
        // ソフト境界 or 単発2σ外の時は手数料のみ上げる
        // beforeSwap の動的手数料計算に反映
    }

    function _checkRebalanceCondition(PoolKey calldata key) internal {
        // リバランス条件を確認（Phase 2で実装）
    }
}
```

**2. テストケース（5件）**

```solidity
// test/AutoCompoundJITHook.t.sol
contract AutoCompoundJITHookTest is Test {
    function test_constructor() public {
        // 初期化確認
    }

    function test_beforeSwap_dynamic_fee() public {
        // 動的手数料が正しく計算され、5-80 bpsにクランプされるか
    }

    function test_afterSwap_observation_recorded() public {
        // 価格観測が記録されるか
    }

    function test_pause_unpause() public {
        // 一時停止機能
    }

    function test_only_owner_can_configure() public {
        // オーナー権限確認
    }
}
```

**成果物:**
- `src/AutoCompoundJITHook.sol`（スケルトン）
- `test/AutoCompoundJITHook.t.sol`（5テスト）

**所要時間:** 1.5日

---

## Phase 2: JIT流動性+自動リバランス（3日）

### 実装内容

**1. JITライブラリの実装**
```solidity
// libraries/JITLiquidity.sol
library JITLiquidity {
    struct RebalanceParams {
        int24 currentTick;
        int24 targetTickLower;
        int24 targetTickUpper;
        uint256 currentLiquidity;
        bool shouldRebalance;
    }

    /// @notice リバランスが必要かチェック
    function checkRebalanceNeed(
        int24 currentTick,
        uint256 lastRebalanceTime,
        uint256 minInterval,
        bool outOfBandConfirmed
    ) internal view returns (bool) {
        // 1. 時間チェック
        if (block.timestamp < lastRebalanceTime + minInterval) {
            return false;
        }

        // 2. 2σ外が連続2回の場合のみリバランス
        if (!outOfBandConfirmed) {
            return false;
        }

        return true;
    }

    /// @notice リバランスの実行
    function executeRebalance(
        IPoolManager poolManager,
        PoolKey memory key,
        RebalanceParams memory params
    ) internal returns (uint256 newLiquidity) {
        // 1. 既存流動性の削除
        if (params.currentLiquidity > 0) {
            poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: params.currentTick - 600,
                    tickUpper: params.currentTick + 600,
                    liquidityDelta: -int256(params.currentLiquidity),
                    salt: bytes32(0)
                }),
                ""
            );
        }

        // 2. 手数料の回収
        (uint256 amount0Fees, uint256 amount1Fees) = _collectFees(
            poolManager,
            key
        );

        // 3. 新規流動性の追加（手数料含む）
        newLiquidity = _calculateLiquidity(
            amount0Fees,
            amount1Fees,
            params.targetTickLower,
            params.targetTickUpper
        );

        poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: params.targetTickLower,
                tickUpper: params.targetTickUpper,
                liquidityDelta: int256(newLiquidity),
                salt: bytes32(0)
            }),
            ""
        );

        return newLiquidity;
    }
}
```

**2. フックへの統合**
```solidity
// src/AutoCompoundJITHook.sol に追加

/// @notice ユーザーがリバランスを実行
function rebalance(PoolKey calldata key)
    external
    nonReentrant
    whenNotPaused
{
    PositionInfo storage position = positions[msg.sender];
    require(position.active, "No active position");

    // クールダウン（2時間）
    if (block.timestamp < position.lastRebalanceTime + REBALANCE_COOLDOWN) {
        emit RebalanceSkipped(msg.sender, "Cooldown");
        return;
    }

    // 1. ボリンジャーバンドの計算
    BollingerBands.Bands memory bands = BollingerBands.calculate(
        observations,
        bbConfig
    );

    // 2. ソフト境界（1.8σ）で警戒、2σ外は2時間連続でリバランス
    int24 currentTick = _getCurrentTick(key);
    if (_isNearBand(currentTick, bands, 180)) {
        _raiseFeeOnly();
    }

    bool outOfBandNow = _isOutOfBand(currentTick, bands);
    bool outOfBandPrev = _isOutOfBand(lastObservedTick, bands);
    if (outOfBandNow && outOfBandPrev) {
        position.outOfBandCount = 2;
    } else if (outOfBandNow) {
        position.outOfBandCount = 1;
        _raiseFeeOnly();
        emit RebalanceSkipped(msg.sender, "Single out-of-band");
        return;
    } else {
        position.outOfBandCount = 0;
    }

    // 3. リバランス必要性チェック（2σ外が連続2回）
    bool needRebalance = JITLiquidity.checkRebalanceNeed(
        currentTick,
        position.lastRebalanceTime,
        MIN_REBALANCE_INTERVAL,
        position.outOfBandCount >= 2
    );

    require(needRebalance, "Rebalance not needed");

    // 4. バンドウォーク検出
    bool isWalking = BollingerBands.detectBandWalk(recentObservations, bands);
    if (isWalking) {
        emit RebalanceSkipped(msg.sender, "Band walking");
        return;
    }

    // 5. MA復帰待機
    uint256 distanceFromMA = _calculateDistanceFromMA(currentTick, bands.middle);
    if (distanceFromMA > MAX_DISTANCE_FROM_MA) {
        emit RebalanceSkipped(msg.sender, "Too far from MA");
        return;
    }

    // 6. リバランス実行（実行後はクールダウン）
    uint256 newLiquidity = JITLiquidity.executeRebalance(
        poolManager,
        key,
        JITLiquidity.RebalanceParams({
            currentTick: currentTick,
            targetTickLower: bands.lower,
            targetTickUpper: bands.upper,
            currentLiquidity: position.liquidity,
            shouldRebalance: true
        })
    );

    // 6. ポジション更新
    position.liquidity = newLiquidity;
    position.tickLower = bands.lower;
    position.tickUpper = bands.upper;
    position.lastRebalanceTime = block.timestamp;
    position.outOfBandCount = 0;

    emit Rebalanced(msg.sender, bands.lower, bands.upper, newLiquidity);
}
```

**3. テストケース（10件）**

```solidity
// test/JITLiquidity.t.sol
contract JITLiquidityTest is Test {
    function test_rebalance_when_range_out() public {
        // レンジアウト時のリバランス
    }

    function test_rebalance_near_edge() public {
        // 2σ外が連続2回（2時間）
    }

    function test_skip_rebalance_min_interval() public {
        // 最短間隔未満でスキップ
    }

    function test_skip_rebalance_band_walk() public {
        // バンドウォーク検出でスキップ
    }

    function test_skip_rebalance_far_from_ma() public {
        // MA乖離大でスキップ
    }

    function test_rebalance_liquidity_calculation() public {
        // 流動性計算の正確性
    }

    function test_rebalance_fees_collected() public {
        // 手数料回収の確認
    }

    function test_rebalance_unauthorized_reverts() public {
        // 非所有者のrevert
    }

    function test_rebalance_paused_reverts() public {
        // 一時停止中のrevert
    }

    function test_rebalance_gas_consumption() public {
        // ガス消費量（目標: <200k gas）
    }
}
```

**成果物:**
- `libraries/JITLiquidity.sol`（~300行）
- `test/JITLiquidity.t.sol`（10テスト）
- ガスレポート

**所要時間:** 3日

---

## Phase 2.5: セキュリティ機能（2日）

### 実装内容

**1. リエントランシー保護**
```solidity
// すでにReentrancyGuardを継承済み
// 主要関数にnonReentrant修飾子を適用

function rebalance(PoolKey calldata key)
    external
    nonReentrant  // ★追加
    whenNotPaused
{
    // ...
}

function compound(PoolKey calldata key)
    external
    nonReentrant  // ★追加
    whenNotPaused
{
    // ...
}
```

**2. Chainlink価格検証**
```solidity
// src/AutoCompoundJITHook.sol に追加

/// @notice Chainlink価格との乖離チェック
function _validatePriceDeviation(uint256 poolPrice) internal view {
    // JPYC/USDの取得
    (, int256 jpycPrice, , , ) = chainlinkJPYC.latestRoundData();
    (, int256 usdcPrice, , , ) = chainlinkUSDC.latestRoundData();

    require(jpycPrice > 0 && usdcPrice > 0, "Invalid Chainlink price");

    // JPYC/USDC = JPYC/USD ÷ USDC/USD
    uint256 chainlinkPrice = uint256(jpycPrice) * 1e18 / uint256(usdcPrice);

    // 乖離率の計算
    uint256 deviation = poolPrice > chainlinkPrice
        ? ((poolPrice - chainlinkPrice) * 10000) / chainlinkPrice
        : ((chainlinkPrice - poolPrice) * 10000) / chainlinkPrice;

    require(deviation < MAX_PRICE_DEVIATION, "Price deviation too large");
}

/// @notice 複数ブロックのTWAP検証
function _validateMultiBlockTWAP() internal view {
    // 最新の観測が複数ブロックにまたがっているか確認
    uint256 blockCount = 0;
    uint256 lastBlock = 0;

    for (uint256 i = 0; i < 10; i++) {
        if (observations[i].blockNumber != lastBlock) {
            blockCount++;
            lastBlock = observations[i].blockNumber;
        }
    }

    require(blockCount >= 3, "Need multi-block observations");
}
```

**2.5. 基準価格の設計（JPYC/USDC TWAP + USDC/USD）**
```solidity
/// @notice 基準価格（JPYC/USD）を算出
/// @dev JPYC直のChainlinkが無いため、JPYC/USDC TWAPとUSDC/USDを組み合わせる
function _getReferencePrice() internal view returns (uint256 jpycUsd) {
    uint256 twapJpycUsdc = _getTwapPriceJpycUsdc(); // DEX TWAP
    (, int256 usdcUsd, , , ) = chainlinkUSDC.latestRoundData();
    require(usdcUsd > 0, "Invalid USDC/USD");

    // JPYC/USD = (JPYC/USDC) * (USDC/USD)
    jpycUsd = (twapJpycUsdc * uint256(usdcUsd)) / 1e8; // USDC/USD decimals
}
```

**3. Depeg/レンジ判定/手数料の基準価格**
- 基準価格は `JPYC/USDC TWAP + USDC/USD (Chainlink on Polygon)` を採用
- JPYC直フィードが将来提供された場合は `ReferencePriceOracle` を差し替える

**3.1. ReferencePriceOracle（差し替え可能設計）**
```solidity
interface IReferencePriceOracle {
    function getReferencePrice() external view returns (uint256 jpycUsd);
}

contract ReferencePriceOracle is IReferencePriceOracle {
    function getReferencePrice() external view returns (uint256 jpycUsd) {
        // 現行: JPYC/USDC TWAP + USDC/USD（Chainlink on Polygon）
        // 将来: JPYC/USD Chainlink に差し替え可能
    }
}
```
**設計方針**
- フック本体は `IReferencePriceOracle` にのみ依存
- 参照価格の更新経路は後から差し替え可能
- デプロイ時にOracleアドレスを設定し、将来は更新可能にする

**3. サーキットブレーカー**
```solidity
// src/AutoCompoundJITHook.sol に追加

uint256 public constant CIRCUIT_BREAKER_THRESHOLD = 1000; // 10%
uint256 public constant REBALANCE_COOLDOWN = 7200;        // 2時間
uint256 public constant SOFT_BAND_BPS = 180;              // 1.8σ
bool public circuitBreakerTriggered;

function _checkCircuitBreaker(uint256 priceChange) internal {
    if (priceChange > CIRCUIT_BREAKER_THRESHOLD) {
        circuitBreakerTriggered = true;
        _pause();
        emit CircuitBreakerTriggered(priceChange);
    }
}

/// @notice オーナーがサーキットブレーカーをリセット
function resetCircuitBreaker() external onlyOwner {
    circuitBreakerTriggered = false;
    _unpause();
    emit CircuitBreakerReset();
}
```

**4. テストケース（10件）**

```solidity
// test/Security.t.sol
contract SecurityTest is Test {
    function test_reentrancy_prevention() public {
        // リエントランシー攻撃のシミュレーション
    }

    function test_chainlink_price_validation() public {
        // Chainlink価格検証
    }

    function test_price_deviation_too_large_reverts() public {
        // 乖離大でrevert
    }

    function test_multi_block_twap_validation() public {
        // 複数ブロック検証
    }

    function test_same_block_update_reverts() public {
        // 同一ブロック更新のrevert
    }

    function test_circuit_breaker_triggered() public {
        // サーキットブレーカー発動
    }

    function test_only_owner_can_reset_circuit_breaker() public {
        // リセット権限確認
    }

    function test_pause_stops_all_operations() public {
        // 一時停止で全操作停止
    }

    function test_flashloan_attack_prevention() public {
        // フラッシュローン攻撃シミュレーション
    }

    function test_gas_price_limit() public {
        // ガス価格上限チェック
    }
}
```

**成果物:**
- セキュリティ機能追加済み`AutoCompoundJITHook.sol`
- `test/Security.t.sol`（10テスト）
- セキュリティレポート

**所要時間:** 2日

---

## Phase 3: 自動複利（2日）

### 実装内容

**1. 自動複利ライブラリ**
```solidity
// libraries/AutoCompounder.sol
library AutoCompounder {
    struct CompoundingStats {
        uint256 totalFeesCollected0;
        uint256 totalFeesCollected1;
        uint256 totalLiquidityAdded;
        uint256 compoundCount;
        uint256 lastCompoundTime;
    }

    /// @notice 手数料を流動性に変換
    function feesToLiquidity(
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256 liquidity) {
        // Uniswap V4の流動性計算
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0,
            amount1
        );

        return liquidity;
    }

    /// @notice 複利の実行
    function executeCompound(
        IPoolManager poolManager,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (uint256 addedLiquidity, uint256 amount0, uint256 amount1) {
        // 1. 手数料の回収
        (amount0, amount1) = _collectAllFees(poolManager, key);

        require(
            amount0 >= MIN_COMPOUND_AMOUNT || amount1 >= MIN_COMPOUND_AMOUNT,
            "Insufficient fees"
        );

        // 2. 流動性の計算
        uint160 sqrtPriceX96 = _getSqrtPriceX96(poolManager, key);
        addedLiquidity = feesToLiquidity(
            amount0,
            amount1,
            tickLower,
            tickUpper,
            sqrtPriceX96
        );

        // 3. 流動性の追加
        poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(addedLiquidity),
                salt: bytes32(0)
            }),
            ""
        );

        return (addedLiquidity, amount0, amount1);
    }
}
```

**2. フックへの統合**
```solidity
// src/AutoCompoundJITHook.sol に追加

mapping(address => AutoCompounder.CompoundingStats) public compoundingStats;

/// @notice リバランス時の自動複利
function rebalance(PoolKey calldata key)
    external
    nonReentrant
    whenNotPaused
{
    PositionInfo storage position = positions[msg.sender];
    require(position.active, "No active position");

    // ... リバランスロジック ...

    // ★自動複利の実行
    (uint256 addedLiquidity, uint256 fees0, uint256 fees1) =
        AutoCompounder.executeCompound(
            poolManager,
            key,
            bands.lower,
            bands.upper
        );

    // 統計の更新
    AutoCompounder.CompoundingStats storage stats = compoundingStats[msg.sender];
    stats.totalFeesCollected0 += fees0;
    stats.totalFeesCollected1 += fees1;
    stats.totalLiquidityAdded += addedLiquidity;
    stats.compoundCount++;
    stats.lastCompoundTime = block.timestamp;

    position.totalFeesCompounded += addedLiquidity;

    emit Compounded(msg.sender, fees0, fees1, addedLiquidity);
}

/// @notice 手動で複利実行（ガス代を払いたくないユーザー用）
function compound(PoolKey calldata key)
    external
    nonReentrant
    whenNotPaused
{
    PositionInfo storage position = positions[msg.sender];
    require(position.active, "No active position");

    (uint256 addedLiquidity, uint256 fees0, uint256 fees1) =
        AutoCompounder.executeCompound(
            poolManager,
            key,
            position.tickLower,
            position.tickUpper
        );

    // 統計更新
    // ...

    emit Compounded(msg.sender, fees0, fees1, addedLiquidity);
}
```

**3. テストケース（7件）**

```solidity
// test/AutoCompounder.t.sol
contract AutoCompounderTest is Test {
    function test_compound_on_rebalance() public {
        // リバランス時の自動複利
    }

    function test_manual_compound() public {
        // 手動複利実行
    }

    function test_fees_to_liquidity_accurate() public {
        // 手数料→流動性変換の精度
    }

    function test_compound_stats_tracking() public {
        // 統計追跡の正確性
    }

    function test_min_compound_amount() public {
        // 最低複利額チェック
    }

    function test_compound_unauthorized_reverts() public {
        // 非所有者のrevert
    }

    function test_compound_simulation_3years() public {
        // 3年間シミュレーション（$10k → $46k）
    }
}
```

**成果物:**
- `libraries/AutoCompounder.sol`（~200行）
- `test/AutoCompounder.t.sol`（7テスト）
- 複利シミュレーションレポート

**所要時間:** 2日

---

## Phase 4: オラクル拡張（1日）

### 実装内容

**1. オラクル実装**
```solidity
// src/AutoCompoundJITHook.sol に追加

/// @notice 外部プロトコル向けのTWAP価格提供
function getTWAP(PoolKey calldata key, uint256 secondsAgo)
    external
    view
    returns (uint256 price)
{
    require(secondsAgo <= 4 hours, "Too old");

    uint256 targetTimestamp = block.timestamp - secondsAgo;
    uint256 sum = 0;
    uint256 count = 0;

    for (uint256 i = 0; i < observations.length; i++) {
        if (observations[i].timestamp >= targetTimestamp) {
            sum += observations[i].price;
            count++;
        }
    }

    require(count > 0, "No data");
    return sum / count;
}

/// @notice 最新価格
function getLatestPrice(PoolKey calldata key)
    external
    view
    returns (uint256 price)
{
    return observations[currentIndex].price;
}

/// @notice ボラティリティ提供
function getVolatility(PoolKey calldata key)
    external
    view
    returns (uint256 volatility)
{
    return VolatilityCalculator.calculateVolatility(
        observations,
        currentIndex
    );
}
```

**2. テストケース（4件）**

```solidity
// test/Oracle.t.sol
contract OracleTest is Test {
    function test_getTWAP() public {
        // TWAP価格取得
    }

    function test_getLatestPrice() public {
        // 最新価格取得
    }

    function test_getVolatility() public {
        // ボラティリティ取得
    }

    function test_oracle_manipulation_resistance() public {
        // 操作耐性テスト
    }
}
```

**成果物:**
- オラクル機能追加済み`AutoCompoundJITHook.sol`
- `test/Oracle.t.sol`（4テスト）

**所要時間:** 1日

---

## Phase 5: テスト・最適化（6.5日）

### Phase 5.1: 統合テスト（2日）

**実装内容:**

```solidity
// test/Integration.t.sol
contract IntegrationTest is Test {
    function test_full_lifecycle() public {
        // 1. 初期流動性提供
        // 2. スワップ発生
        // 3. リバランス実行
        // 4. 自動複利
        // 5. 統計確認
    }

    function test_emergency_mode_transition() public {
        // 通常モード → 緊急モード → 損失最小化モード
    }

    function test_multiple_users() public {
        // 複数ユーザーの同時運用
    }

    function test_extreme_volatility() public {
        // 急変時（±5%）の挙動
    }

    function test_long_term_stability() public {
        // 1000回リバランスシミュレーション
    }

    function test_gas_optimization_batch() public {
        // バッチ処理のガス効率
    }
}
```

**所要時間:** 2日

---

### Phase 5.2: カバレッジ測定（0.5日）

**実装内容:**

```bash
# lcovのインストール
brew install lcov  # Mac
apt-get install lcov  # Linux

# カバレッジレポート生成
forge coverage --report lcov
genhtml lcov.info -o coverage/

# 目標: 95%以上のカバレッジ
```

**成果物:**
- `coverage/index.html`（HTMLレポート）
- カバレッジ95%以上達成の確認

**所要時間:** 0.5日

---

### Phase 5.3: ガス最適化（2日）

**実装内容:**

1. **ストレージ最適化**
```solidity
// Before
struct PositionInfo {
    uint256 liquidity;          // 32 bytes
    int24 tickLower;            // 3 bytes
    int24 tickUpper;            // 3 bytes
    uint256 lastRebalanceTime;  // 32 bytes
    uint8 outOfBandCount;       // 1 byte
    uint256 totalFeesCompounded; // 32 bytes
    bool active;                // 1 byte
}  // Total: 104 bytes → 4 slots

// After（パッキング）
struct PositionInfo {
    uint128 liquidity;          // 16 bytes
    int24 tickLower;            // 3 bytes
    int24 tickUpper;            // 3 bytes
    uint32 lastRebalanceTime;   // 4 bytes (timestamp)
    uint8 outOfBandCount;       // 1 byte
    bool active;                // 1 byte
    uint128 totalFeesCompounded; // 16 bytes
}  // Total: 44 bytes → 2 slots（50%削減）
```

2. **ループ最適化**
```solidity
// Before
for (uint256 i = 0; i < observations.length; i++) {
    if (observations[i].timestamp >= targetTimestamp) {
        sum += observations[i].price;
        count++;
    }
}

// After（アンチェックドループ）
uint256 length = observations.length;
for (uint256 i; i < length;) {
    if (observations[i].timestamp >= targetTimestamp) {
        sum += observations[i].price;
        ++count;
    }
    unchecked { ++i; }
}
```

3. **テストケース（4件）**
```solidity
function test_gas_rebalance() public {
    // リバランスのガス消費（目標: <200k gas）
}

function test_gas_compound() public {
    // 複利のガス消費（目標: <100k gas）
}

function test_gas_storage_packing() public {
    // ストレージパッキングの効果測定
}

function test_gas_batch_operations() public {
    // バッチ処理の効率
}
```

**成果物:**
- ガス最適化済みコード
- ガスレポート（最適化前後の比較）

**所要時間:** 2日

---

### Phase 5.4: フォークテスト（2日）

**実装内容:**

```solidity
// test/ForkTestPolygonMainnet.t.sol
contract ForkTestPolygonMainnet is Test {
    uint256 polygonFork;
    AutoCompoundJITHook hook;

    function setUp() public {
        // Polygon Mainnetのフォーク
        polygonFork = vm.createFork(vm.envString("POLYGON_RPC_URL"));
        vm.selectFork(polygonFork);

        // 実際のChainlinkアドレス
        address jpycFeed = 0x...; // Polygon上のJPYC/USD
        address usdcFeed = 0x...; // Polygon上のUSDC/USD

        // フックのデプロイ
        hook = new AutoCompoundJITHook(
            poolManager,
            jpycFeed,
            usdcFeed
        );
    }

    function test_fork_real_jpyc_usdc_pool() public {
        // 実際のプールでのテスト
    }

    function test_fork_chainlink_price_feeds() public {
        // Chainlink価格フィードの動作確認
    }

    function test_fork_gas_prices_polygon() public {
        // Polygonの実際のガス価格での動作
    }

    function test_fork_24hour_simulation() public {
        // 24時間分のブロック進行シミュレーション
    }

    function test_fork_economic_indicator_event() public {
        // 経済指標発表時の挙動（過去データリプレイ）
    }
}
```

**成果物:**
- `test/ForkTestPolygonMainnet.t.sol`（5テスト）
- フォークテストレポート

**所要時間:** 2日

---

## Phase 6: デプロイ基盤（3.5日）

### Phase 6.1: Mumbaiテストネットデプロイ（0.5日）

**実装内容:**

```solidity
// script/DeployMumbai.s.sol
contract DeployMumbai is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Chainlinkアドレス（Mumbai）
        address jpycFeed = 0x...; // Mumbai JPYC/USD
        address usdcFeed = 0x...; // Mumbai USDC/USD

        // Pool Managerアドレス（Mumbai）
        address poolManager = 0x...;

        // デプロイ
        AutoCompoundJITHook hook = new AutoCompoundJITHook(
            IPoolManager(poolManager),
            jpycFeed,
            usdcFeed
        );

        console.log("Deployed AutoCompoundJITHook:", address(hook));

        vm.stopBroadcast();
    }
}
```

```bash
# デプロイコマンド
forge script script/DeployMumbai.s.sol:DeployMumbai \
  --rpc-url $MUMBAI_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  -vvvv
```

**成果物:**
- `script/DeployMumbai.s.sol`
- Mumbaiでのデプロイアドレス
- Polygonscan検証済みコントラクト

**所要時間:** 0.5日

---

### Phase 6.2: CREATE2アドレス計算（0.5日）

**実装内容:**

```solidity
// script/CalculateCREATE2.s.sol
contract CalculateCREATE2 is Script {
    function run() external view {
        // CREATE2でのアドレス事前計算
        bytes32 salt = bytes32(uint256(1));

        bytes memory bytecode = abi.encodePacked(
            type(AutoCompoundJITHook).creationCode,
            abi.encode(poolManager, jpycFeed, usdcFeed)
        );

        address predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            salt,
            keccak256(bytecode)
        )))));

        console.log("Predicted address:", predicted);

        // フックアドレスのフラグ確認
        uint160 flags = uint160(predicted) >> 152;
        console.log("Hook flags:", flags);

        require(
            flags & 0x01 != 0, // beforeSwap
            "beforeSwap flag not set"
        );
    }
}
```

**成果物:**
- CREATE2予測アドレス
- フックフラグの検証

**所要時間:** 0.5日

---

### Phase 6.3: 監視システム（1.5日）

**実装内容:**

**1. Tenderly統合**
```yaml
# tenderly.yaml
account_id: "your-account"
project_slug: "jpyc-usdc-jit-hook"

contracts:
  - name: AutoCompoundJITHook
    address: "0x..."
    network_id: "137"  # Polygon Mainnet

monitoring:
  alerts:
    - name: "Circuit Breaker Triggered"
      description: "Alert when circuit breaker is triggered"
      expression: "event.name == 'CircuitBreakerTriggered'"
      actions:
        - type: "webhook"
          url: "https://discord.com/api/webhooks/..."
        - type: "email"
          email: "admin@example.com"

    - name: "Large Price Deviation"
      description: "Alert when price deviates >5% from Chainlink"
      expression: "event.name == 'PriceDeviationDetected' && event.args.deviation > 500"
      actions:
        - type: "webhook"
          url: "https://discord.com/api/webhooks/..."

    - name: "Rebalance Failed"
      description: "Alert when rebalance fails"
      expression: "transaction.status == false && transaction.function == 'rebalance'"
      actions:
        - type: "webhook"
          url: "https://discord.com/api/webhooks/..."

simulations:
  - name: "Rebalance Simulation"
    from: "0x..."
    to: "${CONTRACT_ADDRESS}"
    function: "rebalance"
    schedule: "0 * * * *"  # Every hour
```

**2. The Graph サブグラフ**
```graphql
# schema.graphql
type Position @entity {
  id: ID!
  owner: Bytes!
  liquidity: BigInt!
  tickLower: Int!
  tickUpper: Int!
  lastRebalanceTime: BigInt!
  totalFeesCompounded: BigInt!
  active: Boolean!
}

type Rebalance @entity {
  id: ID!
  position: Position!
  timestamp: BigInt!
  tickLower: Int!
  tickUpper: Int!
  newLiquidity: BigInt!
  txHash: Bytes!
}

type Compound @entity {
  id: ID!
  position: Position!
  timestamp: BigInt!
  fees0: BigInt!
  fees1: BigInt!
  liquidityAdded: BigInt!
  txHash: Bytes!
}
```

**3. Discordアラート**
```javascript
// monitoring/discord-alerts.js
const { WebhookClient } = require('discord.js');

const webhook = new WebhookClient({ url: process.env.DISCORD_WEBHOOK });

async function sendAlert(title, description, severity) {
  const color = severity === 'critical' ? 0xFF0000 :
                severity === 'warning' ? 0xFFA500 : 0x00FF00;

  await webhook.send({
    embeds: [{
      title: title,
      description: description,
      color: color,
      timestamp: new Date(),
      footer: { text: 'JPYC/USDC JIT Hook Monitor' }
    }]
  });
}

module.exports = { sendAlert };
```

**成果物:**
- `tenderly.yaml`（監視設定）
- The Graphサブグラフ
- Discordアラートスクリプト

**所要時間:** 1.5日

---

### Phase 6.4: CI/CDパイプライン（1日）

**実装内容:**

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [master, develop]
  pull_request:
    branches: [master]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
        with:
          submodules: recursive

      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1

      - name: Run tests
        run: forge test -vvv

      - name: Generate coverage
        run: |
          forge coverage --report lcov
          lcov --list lcov.info

      - name: Check coverage threshold
        run: |
          COVERAGE=$(lcov --summary lcov.info | grep lines | awk '{print $2}' | sed 's/%//')
          if (( $(echo "$COVERAGE < 95" | bc -l) )); then
            echo "Coverage $COVERAGE% is below 95%"
            exit 1
          fi

      - name: Gas report
        run: forge test --gas-report

      - name: Slither analysis
        uses: crytic/slither-action@v0.3.0
        with:
          target: 'src/'
          slither-args: '--filter-paths "lib/"'
          fail-on: high

      - name: Upload coverage to Codecov
        uses: codecov/codecov-action@v3
        with:
          files: ./lcov.info

  deploy-testnet:
    needs: test
    if: github.ref == 'refs/heads/develop'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
        with:
          submodules: recursive

      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1

      - name: Deploy to Mumbai
        env:
          PRIVATE_KEY: ${{ secrets.MUMBAI_PRIVATE_KEY }}
          MUMBAI_RPC_URL: ${{ secrets.MUMBAI_RPC_URL }}
        run: |
          forge script script/DeployMumbai.s.sol:DeployMumbai \
            --rpc-url $MUMBAI_RPC_URL \
            --broadcast \
            -vvvv
```

**成果物:**
- `.github/workflows/ci.yml`
- `.github/workflows/deploy.yml`
- Codecov統合

**所要時間:** 1日

---

## Phase 7: 外部監査 ★必須★（5-7週間）

### 実装内容

**1. 監査会社の選定**

| 監査会社 | 費用 | 期間 | 評価 |
|---------|------|------|------|
| Trail of Bits | $50k-$80k | 6-8週間 | 最高品質 |
| OpenZeppelin | $40k-$60k | 5-7週間 | 高品質 |
| Consensys Diligence | $30k-$50k | 4-6週間 | 高品質 |
| Ackee Blockchain | $20k-$40k | 4-5週間 | 中堅 |
| Sherlock (コンテスト型) | $10k-$20k | 2-3週間 | コミュニティ |

**推奨:** OpenZeppelin（$40k-$60k、5-7週間）
- 実績豊富（Uniswap, Aave, Compoundなど）
- 日本語対応可能
- 継続的なサポート

**2. 監査スコープ**

```markdown
# Audit Scope

## Contracts in Scope
1. src/AutoCompoundJITHook.sol (~500 lines)
2. libraries/BollingerBands.sol (~200 lines)
3. libraries/JITLiquidity.sol (~300 lines)
4. libraries/AutoCompounder.sol (~200 lines)
5. libraries/VolatilityCalculator.sol (~150 lines)

Total: ~1,350 lines of Solidity

## Focus Areas
1. Reentrancy vulnerabilities
2. Oracle manipulation resistance
3. Flash loan attack vectors
4. Price manipulation scenarios
5. Access control issues
6. Integer overflow/underflow
7. Gas optimization opportunities
8. Centralization risks

## Out of Scope
- Uniswap V4 core contracts
- OpenZeppelin dependencies
- Chainlink price feeds
```

**3. 監査準備**

```bash
# コードフリーズ（監査用ブランチ作成）
git checkout -b audit-v1.0
git tag audit-v1.0-freeze

# ドキュメント整備
docs/
├── ARCHITECTURE.md
├── SECURITY_DESIGN.md
├── KNOWN_ISSUES.md
└── DEPLOYMENT_PLAN.md
```

**4. 監査プロセス**

```
Week 1-2: 初期レビュー
  - コードリーディング
  - 自動解析ツール実行
  - 質問リスト作成

Week 3-4: 深掘り調査
  - 手動コードレビュー
  - 攻撃シナリオ検証
  - フォークテスト

Week 5: レポート作成
  - 発見事項のまとめ
  - 深刻度の評価
  - 修正提案

Week 6-7: 修正・再監査
  - 指摘事項の修正
  - 修正内容の再レビュー
  - 最終レポート発行
```

**5. 想定される指摘事項**

| カテゴリ | 深刻度 | 例 |
|---------|--------|-----|
| Critical | 高 | リエントランシー、価格操作 |
| High | 中高 | アクセス制御、整数演算 |
| Medium | 中 | DoS、ガス最適化 |
| Low | 低 | コーディング規約、NatSpec |
| Informational | 情報 | ベストプラクティス |

**成果物:**
- 監査レポート（PDF）
- 修正済みコード
- 修正レポート
- 監査証明書

**所要時間:** 5-7週間

**コスト:** $40,000 - $60,000（OpenZeppelin想定）

---

## Phase 8: ドキュメント（3日）

### 実装内容

**1. README.md（完全版）**
```markdown
# Uniswap V4 Auto-Compound JIT Hook

**Polygon JPYC/USDC専用の自動複利型JIT流動性フック**

## Features
- 🎯 Bollinger Bands 2σベースの自動リバランス
- 💰 手数料の自動複利（APR 66.2%）
- 🛡️ 10層のセキュリティ防御
- ⚡ Polygon最適化（1時間ごとに判定）
- 📊 外部プロトコル向けオラクル機能

## Audit
✅ Audited by OpenZeppelin (2025-XX-XX)
📄 [Audit Report](./audits/OpenZeppelin-AutoCompoundJIT-2025.pdf)

## Installation
[インストール手順...]

## Usage
[使用方法...]

## Security
[セキュリティ...]

## License
MIT
```

**2. USER_GUIDE.md**
```markdown
# ユーザーガイド

## 初めてのLP提供

### Step 1: ウォレット接続
[スクリーンショット付き手順]

### Step 2: 流動性提供
[詳細手順]

### Step 3: 自動複利設定
[設定方法]

## リバランスの仕組み

### いつリバランスされる？
- 2σ外が連続2回（2時間）
- 1時間ごとに判定
- リバランス後は2時間クールダウン

### リバランスがスキップされる条件
- 2σ外が1回のみ（手数料のみ上げる）
- 1.8σ到達時は手数料のみ上げる
- 2σ外が1回で内側に戻った場合はカウントリセット
- バンドウォーク検出時
- MA乖離10%以上
- ガス価格が高すぎる時

## よくある質問（FAQ）
[FAQ...]
```

**3. API_REFERENCE.md**
```markdown
# API仕様書

## 主要関数

### `rebalance(PoolKey calldata key)`
**説明:** 流動性のリバランスと自動複利を実行

**引数:**
- `key`: プールキー

**条件:**
- ポジション所有者のみ
- 最短間隔経過後
- コントラクト稼働中

**イベント:**
- `Rebalanced(address indexed user, int24 tickLower, int24 tickUpper, uint256 liquidity)`
- `Compounded(address indexed user, uint256 fees0, uint256 fees1, uint256 liquidityAdded)`

**ガス消費:** 約180,000 gas

[その他の関数...]
```

**4. SECURITY.md**
```markdown
# セキュリティ

## 脆弱性報告

セキュリティ脆弱性を発見した場合：
- Email: security@example.com
- PGP Key: [公開鍵]
- 報奨金: 最大$10,000

## 監査履歴
- 2025-XX-XX: OpenZeppelin監査完了

## 既知の制限事項
[制限事項...]
```

**5. ARCHITECTURE.md**
```markdown
# システムアーキテクチャ

## コンポーネント図
[Mermaid図]

## データフロー
[フロー図]

## 状態遷移図
[状態図]
```

**成果物:**
- `README.md`
- `USER_GUIDE.md`（日本語）
- `API_REFERENCE.md`
- `SECURITY.md`
- `ARCHITECTURE.md`

**所要時間:** 3日

---

## Phase 9: フロントエンド（任意、2週間）

### 実装内容

**1. 技術スタック**
- Next.js 14 (App Router)
- TypeScript
- RainbowKit (ウォレット接続)
- Wagmi v2 (Ethereum hooks)
- Viem (Ethereum client)
- TailwindCSS (スタイリング)
- Recharts (チャート)

**2. ページ構成**
```
pages/
├── index.tsx           # ダッシュボード
├── provide.tsx         # 流動性提供
├── positions.tsx       # ポジション管理
└── analytics.tsx       # 統計・分析
```

**3. 主要機能**
```typescript
// components/RebalanceButton.tsx
'use client';

import { useContractWrite, useWaitForTransaction } from 'wagmi';
import { parseAbi } from 'viem';

export function RebalanceButton({ poolKey }: { poolKey: PoolKey }) {
  const { write, data } = useContractWrite({
    address: HOOK_ADDRESS,
    abi: parseAbi(['function rebalance((address,address,uint24,int24,address)) external']),
    functionName: 'rebalance',
    args: [poolKey],
  });

  const { isLoading } = useWaitForTransaction({ hash: data?.hash });

  return (
    <button
      onClick={() => write()}
      disabled={isLoading}
      className="btn-primary"
    >
      {isLoading ? 'リバランス中...' : 'リバランス実行'}
    </button>
  );
}
```

**4. ダッシュボード**
```typescript
// app/page.tsx
export default function Dashboard() {
  const { address } = useAccount();
  const { data: position } = useContractRead({
    address: HOOK_ADDRESS,
    abi: HOOK_ABI,
    functionName: 'positions',
    args: [address],
  });

  return (
    <div className="container">
      <h1>JPYC/USDC 自動複利JIT</h1>

      <div className="grid grid-cols-3 gap-4">
        <Card title="総流動性">
          ${formatLiquidity(position?.liquidity)}
        </Card>

        <Card title="累計複利">
          ${formatFees(position?.totalFeesCompounded)}
        </Card>

        <Card title="APR">
          66.2%
        </Card>
      </div>

      <PositionChart position={position} />

      <RebalanceButton poolKey={POOL_KEY} />
    </div>
  );
}
```

**成果物:**
- Next.jsアプリケーション
- Vercelデプロイ
- ユーザーガイド（UI操作）

**所要時間:** 2週間（任意）

---

## Phase 10: 法務・コンプライアンス（1週間）

### 実装内容

**1. 法的リスク評価**

**日本の法規制:**
- 資金決済法: JPYCが前払式支払手段（第三者型）
- 金融商品取引法: LP提供が「金融商品」に該当するか
- 暗号資産交換業: 該当しない（交換業務なし）

**確認事項:**
- [ ] LPトークンが有価証券に該当するか
- [ ] 自動複利が「運用」に該当するか
- [ ] 手数料収入の税務処理

**2. 利用規約の作成**

```markdown
# 利用規約

## 1. サービス概要
本サービスは、Uniswap V4プロトコル上で動作する自動複利型流動性提供フックです。

## 2. 免責事項
- スマートコントラクトのリスク
- 価格変動リスク
- レンジアウトリスク
- ガス代変動リスク

## 3. 禁止事項
- マネーロンダリング
- テロ資金供与
- 制裁対象国からのアクセス

## 4. 準拠法
本規約は日本法に準拠します。

[詳細...]
```

**3. プライバシーポリシー**

```markdown
# プライバシーポリシー

## 収集する情報
- ウォレットアドレス（公開情報）
- トランザクション履歴（オンチェーン）
- アクセスログ（分析目的）

## 個人情報保護法対応
[GDPR/個人情報保護法対応...]
```

**4. 外部法務相談**

**相談先:**
- Anderson Mori & Tomotsune（暗号資産専門）
- Nishimura & Asahi（フィンテック）
- HashHub Legal（Web3特化）

**相談内容:**
- サービス設計の適法性確認
- 規制当局への事前相談の要否
- 利用規約・プライバシーポリシーのレビュー

**成果物:**
- 法的リスク評価レポート
- 利用規約
- プライバシーポリシー
- 法務相談記録

**所要時間:** 1週間

**コスト:** $5,000 - $15,000（任意）

---

## Phase 11: 本番デプロイ（1日）

### 実装内容

**1. デプロイ前チェックリスト**

```markdown
# デプロイ前チェックリスト

## コード
- [x] すべてのテストパス（59件）
- [x] カバレッジ95%以上
- [x] ガス最適化完了
- [x] Slither解析クリア

## 監査
- [x] 外部監査完了
- [x] 指摘事項すべて修正
- [x] 最終監査レポート取得

## インフラ
- [x] Tenderly監視設定
- [x] The Graphサブグラフデプロイ
- [x] Discordアラート設定
- [x] CI/CDパイプライン稼働

## ドキュメント
- [x] README.md完成
- [x] ユーザーガイド完成
- [x] API仕様書完成

## 法務
- [x] 利用規約作成
- [x] プライバシーポリシー作成
- [x] 法的リスク評価完了

## 緊急対応
- [x] 緊急連絡先リスト
- [x] インシデント対応手順書
- [x] ロールバック計画
```

**2. デプロイスクリプト**

```solidity
// script/DeployProduction.s.sol
contract DeployProduction is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Polygon Mainnet アドレス
        address poolManager = 0x...; // Polygon PoolManager
        address jpycFeed = 0x...; // Chainlink JPYC/USD
        address usdcFeed = 0x...; // Chainlink USDC/USD

        // CREATE2でデプロイ（予測アドレスと一致させる）
        bytes32 salt = bytes32(uint256(1));

        AutoCompoundJITHook hook = new AutoCompoundJITHook{salt: salt}(
            IPoolManager(poolManager),
            jpycFeed,
            usdcFeed
        );

        console.log("Deployed to:", address(hook));

        // フックフラグ確認
        uint160 flags = uint160(address(hook)) >> 152;
        require(flags & 0x01 != 0, "beforeSwap not set");
        require(flags & 0x02 != 0, "afterSwap not set");

        // オーナー権限の確認
        require(hook.owner() == msg.sender, "Owner mismatch");

        vm.stopBroadcast();

        console.log("Deployment successful!");
        console.log("Hook address:", address(hook));
        console.log("Owner:", hook.owner());
    }
}
```

**3. デプロイコマンド**

```bash
# 環境変数の設定
export DEPLOYER_PRIVATE_KEY="0x..."
export POLYGON_RPC_URL="https://polygon-rpc.com"
export POLYGONSCAN_API_KEY="..."

# デプロイ実行
forge script script/DeployProduction.s.sol:DeployProduction \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  --slow \
  -vvvv

# デプロイ確認
cast call $HOOK_ADDRESS "owner()" --rpc-url $POLYGON_RPC_URL
```

**4. デプロイ後検証**

```bash
# 1. コントラクト検証（Polygonscan）
forge verify-contract \
  $HOOK_ADDRESS \
  src/AutoCompoundJITHook.sol:AutoCompoundJITHook \
  --chain-id 137 \
  --etherscan-api-key $POLYGONSCAN_API_KEY

# 2. Tenderly登録
tenderly contract verify \
  --network-id 137 \
  --address $HOOK_ADDRESS \
  --contract-name AutoCompoundJITHook

# 3. 初期設定
cast send $HOOK_ADDRESS \
  "setBollingerBandConfig(uint256,uint256,uint256)" \
  24 200 86400 \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --rpc-url $POLYGON_RPC_URL

# 4. 動作確認
cast call $HOOK_ADDRESS "bbConfig()" --rpc-url $POLYGON_RPC_URL
```

**5. 監視開始**

```bash
# Tenderly監視開始
tenderly monitoring enable

# The Graphサブグラフデプロイ
graph deploy --product hosted-service username/jpyc-usdc-jit

# Discord通知テスト
node monitoring/test-alert.js
```

**成果物:**
- Polygon Mainnetデプロイ済みコントラクト
- Polygonscan検証済み
- Tenderly監視開始
- The Graphサブグラフ稼働
- デプロイレポート

**所要時間:** 1日

---

## 📊 テスト一覧（全59件）

| Phase | カテゴリ | テスト数 | 内容 |
|-------|---------|---------|------|
| 既存 | Volatility | 16 | 動的手数料（既存） |
| 1 | BollingerBands | 8 | BB計算、バンドウォーク |
| 1.5 | Hook Basic | 5 | フック基本機能 |
| 2 | JIT Liquidity | 10 | リバランス |
| 2.5 | Security | 10 | セキュリティ |
| 3 | AutoCompound | 7 | 自動複利 |
| 4 | Oracle | 4 | オラクル |
| 5.1 | Integration | 6 | 統合テスト |
| 5.3 | Gas | 4 | ガス最適化 |
| 5.4 | Fork | 5 | フォークテスト |
| **合計** | | **75** | |

---

## 💰 予算詳細

### 開発コスト（自社開発想定）
- Phase 0-6: 29.5日 × $500/日 = $14,750

### 外部コスト
| 項目 | 最低 | 最高 | 推奨 |
|------|------|------|------|
| 外部監査 | $20,000 | $80,000 | $50,000 (OpenZeppelin) |
| 法務相談 | $0 | $15,000 | $10,000 |
| インフラ（1年） | $1,200 | $3,600 | $2,400 |
| フロントエンド | $0 | $10,000 | $5,000 |
| **合計** | **$21,200** | **$108,600** | **$67,400** |

### インフラ月額
- Alchemy (RPC): $49/月
- Tenderly (監視): $99/月
- The Graph (サブグラフ): $50/月
- **合計: $198/月 ≈ $2,400/年**

---

## 🚨 リスクと対策

### リスク1: JPYC/USDCプールが存在しない
**確率:** 中
**影響:** 高
**対策:** Phase 0.2で早期確認。存在しない場合はQuickswap V3等への移行検討。

### リスク2: 監査で重大な脆弱性発見
**確率:** 中
**影響:** 高
**対策:** Phase 1-6で徹底的なテスト。Slither/Mythril事前実行。

### リスク3: 法規制の変更
**確率:** 低
**影響:** 中
**対策:** 法務相談の実施。規制動向の継続的モニタリング。

### リスク4: Polygon手数料の高騰
**確率:** 低
**影響:** 中
**対策:** 動的ガス価格上限。zkEVMへの移行オプション。

### リスク5: Chainlink価格フィードの停止
**確率:** 極低
**影響:** 高
**対策:** サーキットブレーカー。複数オラクルソースの検討。

---

## 📅 マイルストーン

| 日付 | マイルストーン | 成果物 |
|------|---------------|--------|
| Day 0 | キックオフ | 環境構築完了 |
| Day 2 | Phase 0完了 | 依存関係、プール確認 |
| Day 4 | Phase 1完了 | ボリンジャーバンド |
| Day 5.5 | Phase 1.5完了 | フック基本 |
| Day 8.5 | Phase 2完了 | JIT流動性 |
| Day 10.5 | Phase 2.5完了 | セキュリティ |
| Day 12.5 | Phase 3完了 | 自動複利 |
| Day 13.5 | Phase 4完了 | オラクル |
| Day 20 | Phase 5完了 | テスト完了 |
| Day 23.5 | Phase 6完了 | Mumbai稼働 |
| Week 12 | Phase 7完了 | 監査完了 ★ |
| Week 12.5 | Phase 8完了 | ドキュメント |
| Week 14.5 | Phase 9完了 | フロントエンド（任意） |
| Week 15.5 | Phase 10完了 | 法務完了 |
| **Week 16** | **Phase 11完了** | **本番稼働🚀** |

---

## 🎯 成功指標（KPI）

### 技術指標
- ✅ テストカバレッジ: 95%以上
- ✅ ガス効率: リバランス <200k gas
- ✅ セキュリティ: 外部監査パス
- ✅ 稼働率: 99.9%以上

### ビジネス指標
- 🎯 TVL: $100k（初月）→ $1M（6ヶ月）
- 🎯 APR: 60%以上維持
- 🎯 ユーザー数: 100人（3ヶ月）
- 🎯 手数料収入: $10k/月（6ヶ月）

### コミュニティ指標
- 📣 Twitterフォロワー: 1,000人（3ヶ月）
- 📣 Discordメンバー: 500人（3ヶ月）
- 📣 メディア掲載: 3件（6ヶ月）

---

## 🔄 継続的改善計画

### フェーズ1（1-3ヶ月）: 安定化
- [ ] 毎日の監視とアラート対応
- [ ] ユーザーフィードバック収集
- [ ] バグ修正（緊急度: 高）
- [ ] ガス最適化v2

### フェーズ2（3-6ヶ月）: 機能拡張
- [ ] マルチプール対応（JPYC/ETH, JPYC/MATICなど）
- [ ] ガバナンストークン検討
- [ ] モバイルアプリ開発
- [ ] API公開（外部統合）

### フェーズ3（6-12ヶ月）: エコシステム拡大
- [ ] 他DEXへの展開（Quickswap, Balancer）
- [ ] L2展開（Arbitrum, Optimism, zkSync）
- [ ] DAOガバナンス移行
- [ ] プロトコル手数料収益化

---

## 📞 緊急連絡先

### 技術チーム
- **Lead Developer:** [Name] <email@example.com>
- **Security Engineer:** [Name] <security@example.com>

### 外部パートナー
- **監査会社:** OpenZeppelin <contact@openzeppelin.com>
- **法務:** [Law Firm] <legal@example.com>

### インシデント対応
- **Discord:** #emergency-alerts
- **PagerDuty:** [URL]
- **Tenderly:** [Monitoring URL]

---

## 📄 関連ドキュメント

- [IMPLEMENTATION_PLAN_FINAL.md](./IMPLEMENTATION_PLAN_FINAL.md) - 前バージョン
- [SECURITY_CHECKLIST.md](./SECURITY_CHECKLIST.md) - セキュリティチェックリスト
- [IMPLEMENTATION_SCHEDULE_COMPLETE.md](./IMPLEMENTATION_SCHEDULE_COMPLETE.md) - 初期スケジュール（26日版）

---

## ✅ 次のステップ

1. **予算承認**（$50k-$70k）
   - 外部監査: $50k
   - 法務相談: $10k
   - インフラ: $5k（初年度）
   - フロントエンド: $5k（任意）

2. **タイムライン確認**（3.5-4ヶ月）
   - 実装: 1ヶ月
   - 監査: 1.5ヶ月
   - 法務・ドキュメント: 0.5ヶ月
   - バッファ: 0.5-1ヶ月

3. **リソース確保**
   - 開発者: 1-2名（フルタイム）
   - セキュリティレビュワー: 1名（パートタイム）
   - フロントエンドエンジニア: 1名（任意、2週間）

4. **Phase 0開始**
   - 依存ライブラリセットアップ
   - JPYC/USDCプール確認
   - 開発環境構築

---

**承認:**

- [ ] 技術責任者: _________________
- [ ] 財務責任者: _________________
- [ ] 法務責任者: _________________

**日付:** _________________

---

**本計画書は、外部監査・法務相談・監視インフラを含む本番環境デプロイに向けた完全版です。すべての工程を完了することで、安全かつ確実にJPYC/USDC自動複利JITフックを運用できます。**
