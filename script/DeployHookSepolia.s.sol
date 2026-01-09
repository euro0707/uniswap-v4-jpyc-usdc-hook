// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {VolatilityDynamicFeeHook} from "../src/VolatilityDynamicFeeHook.sol";

/// @title DeployHookSepolia
/// @notice Deploy VolatilityDynamicFeeHook to Sepolia Testnet
contract DeployHookSepolia is Script {
    // Sepolia Testnet addresses (Uniswap V4)
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    // Test tokens on Sepolia (ERC-20 tokens for testing)
    // Note: You'll need to deploy or use existing test tokens
    address constant TOKEN0 = address(0); // TODO: Set test token0 address
    address constant TOKEN1 = address(0); // TODO: Set test token1 address

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Deploying VolatilityDynamicFeeHook on Sepolia Testnet ===\n");
        console.log("Deployer:", deployer);
        console.log("PoolManager:", POOL_MANAGER);
        console.log("Chain ID: 11155111 (Sepolia)");
        console.log("");

        // Deploy Hook (deployer will be the owner)
        VolatilityDynamicFeeHook hook = new VolatilityDynamicFeeHook(
            IPoolManager(POOL_MANAGER),
            deployer
        );

        console.log("Hook deployed at:", address(hook));
        console.log("");

        // Deployment summary
        console.log("=== Deployment Summary ===");
        console.log("Hook Address:", address(hook));
        console.log("Owner:", deployer);
        console.log("");

        // Uniswap V4 Periphery Contracts (Sepolia)
        console.log("=== Uniswap V4 Periphery Contracts (Sepolia) ===");
        console.log("PoolManager:", POOL_MANAGER);
        console.log("PositionManager: 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4");
        console.log("StateView: 0xe1dd9c3fa50edb962e442f60dfbc432e24537e4c");
        console.log("Quoter: 0x61b3f2011a92d183c7dbadbda940a7555ccf9227");
        console.log("Permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3");
        console.log("");

        // Next steps
        console.log("=== Next Steps ===");
        console.log("1. Deploy or use existing test tokens (ERC-20)");
        console.log("");
        console.log("2. Initialize pool:");
        console.log("   Use InitializePoolSepolia.s.sol script");
        console.log("");
        console.log("3. Verify on Sepolia Etherscan:");
        console.log("   https://sepolia.etherscan.io/address/%s", address(hook));
        console.log("");
        console.log("4. Test the hook functionality:");
        console.log("   - Perform test swaps");
        console.log("   - Monitor dynamic fee calculation");
        console.log("   - Verify circuit breaker and staleness recovery");

        vm.stopBroadcast();
    }
}
