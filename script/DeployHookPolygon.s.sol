// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {VolatilityDynamicFeeHook} from "../src/VolatilityDynamicFeeHook.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

/// @title DeployHookPolygon
/// @notice Deploy VolatilityDynamicFeeHook to Polygon Mainnet using CREATE2
/// @dev Uses HookMiner to find a salt that produces a hook address with required permission flags
contract DeployHookPolygon is Script {
    // Polygon Mainnet addresses (Uniswap V4)
    address constant POOL_MANAGER = 0x67366782805870060151383F4BbFF9daB53e5cD6;

    // CREATE2 Deployer Proxy (standard across all chains)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        require(block.chainid == 137, "This script is for Polygon mainnet only (chainId: 137)");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying VolatilityDynamicFeeHook on Polygon Mainnet ===\n");
        console.log("Deployer:", deployer);
        console.log("PoolManager:", POOL_MANAGER);
        console.log("Chain ID: 137 (Polygon)");
        console.log("");

        // Calculate required hook flags from getHookPermissions()
        // This ensures the flags always match the hook's actual permissions
        Hooks.Permissions memory permissions = _getHookPermissions();
        uint160 flags = _permissionsToFlags(permissions);

        console.log("=== Hook Permissions ===");
        if (permissions.afterInitialize) console.log("  - AFTER_INITIALIZE");
        if (permissions.beforeSwap) console.log("  - BEFORE_SWAP");
        if (permissions.afterSwap) console.log("  - AFTER_SWAP");
        console.log("Flags (hex):", vm.toString(bytes32(uint256(flags))));
        console.log("");

        console.log("=== Mining Hook Address with CREATE2 ===");
        console.log("Mining salt (this may take a moment)...");
        console.log("");

        // Prepare constructor arguments
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), deployer);

        // Mine salt using HookMiner
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(VolatilityDynamicFeeHook).creationCode,
            constructorArgs
        );

        console.log("Salt found:", vm.toString(salt));
        console.log("Predicted hook address:", hookAddress);
        console.log("Address flags match:", uint160(hookAddress) & uint160(0x3FFF) == flags);
        console.log("");

        // Deploy with CREATE2 using the mined salt
        vm.startBroadcast(deployerPrivateKey);

        VolatilityDynamicFeeHook hook = new VolatilityDynamicFeeHook{salt: salt}(
            IPoolManager(POOL_MANAGER),
            deployer
        );

        // Verify deployment address matches prediction
        require(address(hook) == hookAddress, "Deployed address does not match prediction");

        // Runtime assertion: Verify the deployed hook's permissions match the mined flags
        Hooks.Permissions memory deployedPermissions = hook.getHookPermissions();
        uint160 deployedFlags = _permissionsToFlags(deployedPermissions);
        require(deployedFlags == flags, "Deployed hook permissions do not match mined flags");

        console.log("=== Deployment Successful ===");
        console.log("Hook deployed at:", address(hook));
        console.log("Owner:", deployer);
        console.log("Deployment matches prediction: YES");
        console.log("Permissions verified: YES");
        console.log("");

        // Uniswap V4 Periphery Contracts (Polygon)
        console.log("=== Uniswap V4 Periphery Contracts (Polygon) ===");
        console.log("PoolManager:", POOL_MANAGER);
        console.log("PositionManager: 0x1ec2ebf4f37e7363fdfe3551602425af0b3ceef9");
        console.log("Permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3");
        console.log("");

        // Token addresses for JPYC/USDC pool
        console.log("=== Token Addresses for Pool ===");
        console.log("JPYC v2: 0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB");
        console.log("USDC (Native): 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359");
        console.log("");

        // Next steps
        console.log("=== Next Steps ===");
        console.log("1. Set environment variables in .env:");
        console.log("   TOKEN0_ADDRESS=<JPYC or USDC - sorted>");
        console.log("   TOKEN1_ADDRESS=<JPYC or USDC - sorted>");
        console.log("   HOOK_ADDRESS=<deployed hook address>");
        console.log("");
        console.log("2. Initialize pool:");
        console.log("   forge script script/InitializePoolPolygon.s.sol --rpc-url polygon --broadcast");
        console.log("");
        console.log("3. Add liquidity:");
        console.log("   forge script script/AddLiquidityPolygon.s.sol --rpc-url polygon --broadcast");
        console.log("");
        console.log("4. Verify on Polygonscan:");
        console.log("   https://polygonscan.com/address/%s", address(hook));

        vm.stopBroadcast();
    }

    /// @notice Get hook permissions (matches VolatilityDynamicFeeHook.getHookPermissions)
    /// @dev This is the single source of truth for hook permissions
    function _getHookPermissions() internal pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Convert Hooks.Permissions to flags (uint160)
    /// @param permissions Hook permissions
    /// @return flags The permission flags as uint160
    function _permissionsToFlags(Hooks.Permissions memory permissions) internal pure returns (uint160) {
        uint160 flags = 0;
        if (permissions.beforeInitialize) flags |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (permissions.afterInitialize) flags |= Hooks.AFTER_INITIALIZE_FLAG;
        if (permissions.beforeAddLiquidity) flags |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (permissions.afterAddLiquidity) flags |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (permissions.beforeRemoveLiquidity) flags |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (permissions.afterRemoveLiquidity) flags |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (permissions.beforeSwap) flags |= Hooks.BEFORE_SWAP_FLAG;
        if (permissions.afterSwap) flags |= Hooks.AFTER_SWAP_FLAG;
        if (permissions.beforeDonate) flags |= Hooks.BEFORE_DONATE_FLAG;
        if (permissions.afterDonate) flags |= Hooks.AFTER_DONATE_FLAG;
        if (permissions.beforeSwapReturnDelta) flags |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (permissions.afterSwapReturnDelta) flags |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (permissions.afterAddLiquidityReturnDelta) flags |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (permissions.afterRemoveLiquidityReturnDelta) flags |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
        return flags;
    }
}
