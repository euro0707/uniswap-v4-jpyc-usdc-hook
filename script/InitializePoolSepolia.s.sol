// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @title InitializePoolSepolia
/// @notice Initialize test pool with dynamic fee hook on Sepolia
contract InitializePoolSepolia is Script {
    // Sepolia Uniswap V4
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    // Environment variables (set these in .env)
    address TOKEN0;
    address TOKEN1;
    address HOOK;

    function run() external {
        TOKEN0 = vm.envAddress("TOKEN0_ADDRESS");
        TOKEN1 = vm.envAddress("TOKEN1_ADDRESS");
        HOOK = vm.envAddress("HOOK_ADDRESS");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("=== Initializing Pool on Sepolia ===\n");
        console.log("PoolManager:", POOL_MANAGER);
        console.log("Token0:", TOKEN0);
        console.log("Token1:", TOKEN1);
        console.log("Hook:", HOOK);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Ensure correct token ordering (currency0 < currency1)
        address currency0 = TOKEN0 < TOKEN1 ? TOKEN0 : TOKEN1;
        address currency1 = TOKEN0 < TOKEN1 ? TOKEN1 : TOKEN0;

        console.log("Sorted currency0:", currency0);
        console.log("Sorted currency1:", currency1);

        // Create PoolKey
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        // Initial price: 1:1 ratio (sqrtPriceX96 = sqrt(1) * 2^96)
        // sqrtPriceX96 = 79228162514264337593543950336
        uint160 sqrtPriceX96 = 79228162514264337593543950336;

        console.log("sqrtPriceX96 (1:1 price):", sqrtPriceX96);
        console.log("");

        // Initialize pool
        IPoolManager(POOL_MANAGER).initialize(poolKey, sqrtPriceX96);

        console.log("Pool initialized successfully!");
        console.log("");
        console.log("=== Pool Details ===");
        console.log("Fee: DYNAMIC_FEE_FLAG");
        console.log("Tick Spacing: 60");
        console.log("Initial Price Ratio: 1:1");

        vm.stopBroadcast();
    }
}
