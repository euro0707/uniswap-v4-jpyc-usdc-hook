// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {VolatilityDynamicFeeHook} from "../src/VolatilityDynamicFeeHook.sol";

/// @title DeployHook
/// @notice Deploy VolatilityDynamicFeeHook to Polygon Mainnet
contract DeployHook is Script {
    // Polygon Mainnet addresses
    address constant POOL_MANAGER = 0x67366782805870060151383F4BbFF9daB53e5cD6;
    address constant JPYC = 0x6AE7Dfc73E0dDE2aa99ac063DcF7e8A63265108c;
    address constant USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("=== Deploying VolatilityDynamicFeeHook on Polygon Mainnet ===\n");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("PoolManager:", POOL_MANAGER);
        console.log("");
        
        // Deploy Hook
        VolatilityDynamicFeeHook hook = new VolatilityDynamicFeeHook(
            IPoolManager(POOL_MANAGER)
        );
        
        console.log("Hook deployed at:", address(hook));
        console.log("");
        
        // Deployment summary
        console.log("=== Deployment Summary ===");
        console.log("Hook Address:", address(hook));
        console.log("JPYC:", JPYC);
        console.log("USDC:", USDC);
        console.log("");
        
        // Next steps
        console.log("=== Next Steps ===");
        console.log("1. Initialize pool:");
        console.log("   poolManager.initialize(poolKey, sqrtPriceX96, hookData)");
        console.log("");
        console.log("2. PoolKey configuration:");
        console.log("   - currency0: JPYC");
        console.log("   - currency1: USDC");
        console.log("   - fee: DYNAMIC_FEE_FLAG");
        console.log("   - tickSpacing: 60");
        console.log("   - hooks: address(hook)");
        console.log("");
        console.log("3. Verify on Polygonscan:");
        console.log("   https://polygonscan.com/address/%s", address(hook));
        
        vm.stopBroadcast();
    }
}
