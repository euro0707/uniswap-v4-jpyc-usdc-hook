// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @title AddLiquiditySepolia
/// @notice Add liquidity to the USDC/JPYC pool with dynamic fee hook
contract AddLiquiditySepolia is Script {
    // Sepolia Uniswap V4
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        require(block.chainid == 11155111, "This script is for Sepolia testnet only (chainId: 11155111)");

        address token0Addr = vm.envAddress("TOKEN0_ADDRESS");
        address token1Addr = vm.envAddress("TOKEN1_ADDRESS");
        address hookAddr = vm.envAddress("HOOK_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Adding Liquidity on Sepolia ===\n");
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

        // Approve tokens for PositionManager via Permit2
        IERC20(currency0).approve(PERMIT2, type(uint256).max);
        IERC20(currency1).approve(PERMIT2, type(uint256).max);
        console.log("Approved tokens for Permit2");

        // Approve Permit2 to spend tokens (Permit2 will transfer to PositionManager)
        IPermit2(PERMIT2).approve(currency0, POSITION_MANAGER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(currency1, POSITION_MANAGER, type(uint160).max, type(uint48).max);
        console.log("Approved PositionManager via Permit2");

        // Create PoolKey
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        // Liquidity parameters
        // Full range: MIN_TICK to MAX_TICK (rounded to tickSpacing)
        int24 tickLower = (TickMath.MIN_TICK / 60) * 60;
        int24 tickUpper = (TickMath.MAX_TICK / 60) * 60;

        // Amount of liquidity to add
        // currency0 = JPYC (0x6A6cdC..., 18 decimals, lower address)
        // currency1 = USDC (0xD58CA7..., 6 decimals, higher address)
        // For testing: 1,000 of each token
        uint256 amount0Max = 1_000 * 10**18;  // 1,000 JPYC (18 decimals)
        uint256 amount1Max = 1_000 * 10**6;   // 1,000 USDC (6 decimals)

        console.log("");
        console.log("=== Liquidity Parameters ===");
        console.log("Tick Lower:", tickLower);
        console.log("Tick Upper:", tickUpper);
        console.log("Amount0Max (JPYC):", amount0Max);
        console.log("Amount1Max (USDC):", amount1Max);

        // Encode actions for PositionManager
        // Use MINT_POSITION + CLOSE_CURRENCY (not SETTLE)
        // CLOSE_CURRENCY automatically settles any remaining debt
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY)
        );

        // Calculate liquidity - use a smaller amount for testing
        // With 1:1 price and full range, liquidity ~ min(amount0, amount1 * 10^12) / 2
        // Using 10^9 as a conservative liquidity target
        uint128 liquidity = 10**9;

        bytes[] memory params = new bytes[](3);
        // MINT_POSITION params: poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            uint128(amount0Max),
            uint128(amount1Max),
            deployer,
            ""
        );
        // CLOSE_CURRENCY params: just the currency
        params[1] = abi.encode(poolKey.currency0);
        params[2] = abi.encode(poolKey.currency1);

        // Execute mint via PositionManager
        IPositionManager(POSITION_MANAGER).modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60
        );

        console.log("");
        console.log("=== Liquidity Added Successfully! ===");
        console.log("Position created for deployer");

        vm.stopBroadcast();
    }
}
