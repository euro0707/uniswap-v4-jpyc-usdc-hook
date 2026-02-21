// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title SwapHelper
/// @notice Helper contract to execute swaps on Uniswap V4
contract SwapHelper is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    struct SwapCallbackData {
        PoolKey key;
        SwapParams params;
        address sender;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory hookData
    ) external returns (BalanceDelta delta) {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        delta = abi.decode(
            poolManager.unlock(abi.encode(SwapCallbackData(key, params, msg.sender))),
            (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Unauthorized");

        SwapCallbackData memory data = abi.decode(rawData, (SwapCallbackData));

        BalanceDelta delta = poolManager.swap(data.key, data.params, "");

        // Settle negative deltas (pay to pool)
        if (delta.amount0() < 0) {
            _settle(data.key.currency0, data.sender, uint256(-int256(delta.amount0())));
        }
        if (delta.amount1() < 0) {
            _settle(data.key.currency1, data.sender, uint256(-int256(delta.amount1())));
        }

        // Take positive deltas (receive from pool)
        if (delta.amount0() > 0) {
            _take(data.key.currency0, data.sender, uint256(int256(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            _take(data.key.currency1, data.sender, uint256(int256(delta.amount1())));
        }

        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer, uint256 amount) internal {
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).transferFrom(payer, address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, address recipient, uint256 amount) internal {
        poolManager.take(currency, recipient, amount);
    }
}

interface IHookCircuitBreakerView {
    function isCircuitBreakerTriggered(bytes32 poolId) external view returns (bool);
}

/// @title SwapSepolia
/// @notice Execute test swaps on Sepolia to verify dynamic fee hook
contract SwapSepolia is Script {
    using PoolIdLibrary for PoolKey;

    // Sepolia Uniswap V4
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    function run() external {
        require(block.chainid == 11155111, "This script is for Sepolia testnet only (chainId: 11155111)");

        address token0Addr = vm.envAddress("TOKEN0_ADDRESS");
        address token1Addr = vm.envAddress("TOKEN1_ADDRESS");
        address hookAddr = vm.envAddress("HOOK_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Swap Test on Sepolia ===\n");
        console.log("Deployer:", deployer);
        console.log("Token0:", token0Addr);
        console.log("Token1:", token1Addr);
        console.log("Hook:", hookAddr);

        // Ensure correct token ordering
        address currency0 = token0Addr < token1Addr ? token0Addr : token1Addr;
        address currency1 = token0Addr < token1Addr ? token1Addr : token0Addr;

        console.log("Sorted currency0:", currency0);
        console.log("Sorted currency1:", currency1);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy SwapHelper
        SwapHelper swapHelper = new SwapHelper(IPoolManager(POOL_MANAGER));
        console.log("SwapHelper deployed at:", address(swapHelper));

        // Approve tokens for SwapHelper
        IERC20(currency0).approve(address(swapHelper), type(uint256).max);
        IERC20(currency1).approve(address(swapHelper), type(uint256).max);
        console.log("Approved tokens for SwapHelper");

        // Create PoolKey
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        // Build amounts from actual token decimals to avoid precision mismatch after address sorting
        uint8 decimals0 = IERC20Metadata(currency0).decimals();
        uint8 decimals1 = IERC20Metadata(currency1).decimals();

        // Swap parameters
        // Swap 100 units of currency0 for currency1 (exact input)
        int256 amountIn = -int256(100 * 10**decimals0); // Negative = exact input
        bool zeroForOne = true; // Swap currency0 -> currency1

        console.log("");
        console.log("=== Swap Parameters ===");
        console.log("Direction: currency0 -> currency1 (zeroForOne)");
        console.log("currency0 decimals:", decimals0);
        console.log("Amount In (currency0):", uint256(-amountIn));

        // Execute swap
        BalanceDelta delta = swapHelper.swap(poolKey, zeroForOne, amountIn, "");

        console.log("");
        console.log("=== Swap Result ===");
        console.log("Delta amount0:", delta.amount0());
        console.log("Delta amount1:", delta.amount1());

        // Second swap in opposite direction to test volatility tracking
        console.log("");
        console.log("=== Second Swap (Reverse Direction) ===");

        int256 amountIn2 = -int256(10 * 10**decimals1); // 10 units of currency1 exact input
        bool zeroForOne2 = false; // Swap currency1 -> currency0

        console.log("Direction: currency1 -> currency0 (oneForZero)");
        console.log("currency1 decimals:", decimals1);
        console.log("Amount In (currency1):", uint256(-amountIn2));

        bool isCbTriggered =
            IHookCircuitBreakerView(hookAddr).isCircuitBreakerTriggered(PoolId.unwrap(poolKey.toId()));

        if (isCbTriggered) {
            console.log("");
            console.log("=== Second Swap Result ===");
            console.log("Second swap skipped because circuit breaker is active.");
        } else {
            BalanceDelta delta2 = swapHelper.swap(poolKey, zeroForOne2, amountIn2, "");

            console.log("");
            console.log("=== Second Swap Result ===");
            console.log("Delta amount0:", delta2.amount0());
            console.log("Delta amount1:", delta2.amount1());
        }

        console.log("");
        console.log("=== Swaps Completed Successfully! ===");
        console.log("Dynamic fee hook should have recorded price changes");

        vm.stopBroadcast();
    }
}
