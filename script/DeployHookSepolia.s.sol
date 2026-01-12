// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {VolatilityDynamicFeeHook} from "../src/VolatilityDynamicFeeHook.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

/// @title DeployHookSepolia
/// @notice Deploy VolatilityDynamicFeeHook to Sepolia Testnet using CREATE2
/// @dev Uses HookMiner to find a salt that produces a hook address with required permission flags
contract DeployHookSepolia is Script {
    // Sepolia Testnet addresses (Uniswap V4)
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    // CREATE2 Deployer Proxy (standard across all chains)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying VolatilityDynamicFeeHook on Sepolia Testnet ===\n");
        console.log("Deployer:", deployer);
        console.log("PoolManager:", POOL_MANAGER);
        console.log("Chain ID: 11155111 (Sepolia)");
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
