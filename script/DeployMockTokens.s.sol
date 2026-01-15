// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title DeployMockTokens
/// @notice Deploy mock USDC and JPYC tokens for testing on Sepolia
contract DeployMockTokens is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying Mock Tokens on Sepolia ===\n");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MockUSDC (6 decimals like real USDC)
        MockERC20 mockUSDC = new MockERC20("Mock USDC", "mUSDC", 6);
        console.log("MockUSDC deployed at:", address(mockUSDC));

        // Deploy MockJPYC (18 decimals)
        MockERC20 mockJPYC = new MockERC20("Mock JPYC", "mJPYC", 18);
        console.log("MockJPYC deployed at:", address(mockJPYC));

        // Mint initial supply to deployer
        uint256 usdcAmount = 1_000_000 * 10**6; // 1M USDC
        uint256 jpycAmount = 150_000_000 * 10**18; // 150M JPYC (~1M USD at 150 JPY/USD)

        mockUSDC.mint(deployer, usdcAmount);
        mockJPYC.mint(deployer, jpycAmount);

        console.log("");
        console.log("=== Minted Initial Supply ===");
        console.log("MockUSDC minted:", usdcAmount / 10**6, "USDC");
        console.log("MockJPYC minted:", jpycAmount / 10**18, "JPYC");

        console.log("");
        console.log("=== Token Addresses for .env ===");
        console.log("TOKEN0_ADDRESS=", address(mockUSDC));
        console.log("TOKEN1_ADDRESS=", address(mockJPYC));

        vm.stopBroadcast();
    }
}
