// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @title InitializePool
/// @notice Initialize JPYC/USDC pool with dynamic fee hook
contract InitializePool is Script {
    address POOL_MANAGER;
    address JPYC;
    address USDC;
    address HOOK;
    
    function run() external {
        POOL_MANAGER = vm.envAddress("POOL_MANAGER");
        JPYC = vm.envAddress("JPYC_ADDRESS");
        USDC = vm.envAddress("USDC_ADDRESS");
        HOOK = vm.envAddress("HOOK_ADDRESS");
        
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        
        console.log("=== Initializing JPYC/USDC Pool ===\n");
        console.log("PoolManager:", POOL_MANAGER);
        console.log("JPYC:", JPYC);
        console.log("USDC:", USDC);
        console.log("Hook:", HOOK);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Create PoolKey
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(JPYC),
            currency1: Currency.wrap(USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
        
        // Initial price: 1 USDC = 156.785 JPYC
        uint160 sqrtPriceX96 = 991614085264827948395520;
        
        console.log("sqrtPriceX96:", sqrtPriceX96);
        
        // Initialize pool (2 parameters: PoolKey, sqrtPriceX96)
        IPoolManager(POOL_MANAGER).initialize(poolKey, sqrtPriceX96);
        
        console.log("Pool initialized successfully!");
        
        vm.stopBroadcast();
    }
}
