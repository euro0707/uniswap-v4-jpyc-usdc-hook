// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract DynamicFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Allowed token pair (reject unauthorized pools)
    address public immutable ALLOWED_TOKEN_A;
    address public immutable ALLOWED_TOKEN_B;

    // v4 spec: 23rd bit flag to enable lpFeeOverride
    uint24 internal constant FEE_OVERRIDE_FLAG = 0x400000;

    // Fee tiers (unit: pips, 1_000_000 = 100%)
    uint24 public constant FEE_CALM   =    500;  // 0.05%
    uint24 public constant FEE_NORMAL =  1_000;  // 0.10%
    uint24 public constant FEE_MEDIUM =  3_000;  // 0.30%
    uint24 public constant FEE_HIGH   = 10_000;  // 1.00%

    // Per-pool storage
    mapping(PoolId => int24)   public lastTick;
    mapping(PoolId => uint256) public lastBlock;
    mapping(PoolId => uint24)  public blockTickDelta;
    mapping(PoolId => bool)    public isInitialized;

    event FeeApplied(PoolId indexed poolId, uint24 fee, int24 currentTick);
    event TickUpdated(PoolId indexed poolId, int24 oldTick, int24 newTick);

    constructor(
        IPoolManager _poolManager,
        address _tokenA,
        address _tokenB
    ) BaseHook(_poolManager) {
        ALLOWED_TOKEN_A = _tokenA;
        ALLOWED_TOKEN_B = _tokenB;
    }

    function _validatePair(PoolKey calldata key) internal view {
        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        bool valid = (t0 == ALLOWED_TOKEN_A && t1 == ALLOWED_TOKEN_B)
                  || (t0 == ALLOWED_TOKEN_B && t1 == ALLOWED_TOKEN_A);
        require(valid, "DynamicFeeHook: invalid token pair");
    }

    function getHookPermissions()
        public pure override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize:              false,
            afterInitialize:               true,
            beforeAddLiquidity:            false,
            afterAddLiquidity:             false,
            beforeRemoveLiquidity:         false,
            afterRemoveLiquidity:          false,
            beforeSwap:                    true,
            afterSwap:                     true,
            beforeDonate:                  false,
            afterDonate:                   false,
            beforeSwapReturnDelta:         false,
            afterSwapReturnDelta:          false,
            afterAddLiquidityReturnDelta:  false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) internal override returns (bytes4) {
        _validatePair(key);
        PoolId id = key.toId();
        lastTick[id]      = tick;
        lastBlock[id]     = block.number;
        isInitialized[id] = true;
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    ) internal override
      returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        (, int24 currentTick, , ) = poolManager.getSlot0(id);
        uint24 fee = _calculateFee(id, currentTick);
        emit FeeApplied(id, fee, currentTick);
        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | FEE_OVERRIDE_FLAG
        );
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId id = key.toId();
        (, int24 newTick, , ) = poolManager.getSlot0(id);
        int24 oldTick = lastTick[id];
        emit TickUpdated(id, oldTick, newTick);
        // CEI: update state first (reentrancy protection)
        lastTick[id] = newTick;
        uint24 delta = _absTickDiff(oldTick, newTick);
        uint24 base = blockTickDelta[id];
        if (lastBlock[id] != block.number) {
            // Decay by 50% instead of resetting to 0.
            // This makes cross-block MEV attacks more expensive by preserving
            // some volatility signal across block boundaries.
            base = base / 2;
            lastBlock[id] = block.number;
        }
        unchecked {
            uint24 newCum = base + delta;
            blockTickDelta[id] = newCum < base ? type(uint24).max : newCum;
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    function _calculateFee(
        PoolId id, int24 currentTick
    ) internal view returns (uint24) {
        if (!isInitialized[id]) return FEE_NORMAL;
        uint24 tickDelta = _absTickDiff(currentTick, lastTick[id]);
        // Overflow-safe addition: if wrapping occurs, volatility is extreme → clamp to max.
        uint24 cumDelta;
        unchecked {
            cumDelta = blockTickDelta[id] + tickDelta;
            if (cumDelta < blockTickDelta[id]) cumDelta = type(uint24).max;
        }
        // Thresholds calibrated for JPYC/USDC:
        // ~0.1% move ≈ 10 ticks, ~0.5% move ≈ 50 ticks
        if (cumDelta == 0)  return FEE_CALM;
        if (cumDelta <= 10) return FEE_NORMAL;
        if (cumDelta <= 50) return FEE_MEDIUM;
        return FEE_HIGH;
    }

    function _absTickDiff(
        int24 a, int24 b
    ) internal pure returns (uint24) {
        int256 diff = int256(a) - int256(b);
        if (diff < 0) diff = -diff;
        if (diff > int256(uint256(type(uint24).max)))
            return type(uint24).max;
        return uint24(uint256(diff));
    }

    function previewFee(
        PoolKey calldata key
    ) external view returns (uint24) {
        PoolId id = key.toId();
        (, int24 currentTick, , ) = poolManager.getSlot0(id);
        return _calculateFee(id, currentTick);
    }

    function volatilityLevel(
        PoolKey calldata key
    ) external view returns (uint8) {
        PoolId id = key.toId();
        (, int24 currentTick, , ) = poolManager.getSlot0(id);
        uint24 cum;
        unchecked {
            uint24 delta = _absTickDiff(currentTick, lastTick[id]);
            cum = blockTickDelta[id] + delta;
            if (cum < blockTickDelta[id]) cum = type(uint24).max;
        }
        if (cum == 0)  return 0;
        if (cum <= 10) return 1;
        if (cum <= 50) return 2;
        return 3;
    }
}
