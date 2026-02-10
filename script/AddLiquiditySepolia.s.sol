// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @title AddLiquiditySepolia
/// @notice Add liquidity to the USDC/JPYC pool with dynamic fee hook
contract AddLiquiditySepolia is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

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

        // Determine decimals from env (Sepolia mock tokens have variable addresses)
        uint8 decimals0 = uint8(vm.envOr("TOKEN0_DECIMALS", uint256(18)));
        uint8 decimals1 = uint8(vm.envOr("TOKEN1_DECIMALS", uint256(6)));
        // Swap decimals if token order was swapped
        if (token0Addr > token1Addr) {
            (decimals0, decimals1) = (decimals1, decimals0);
        }

        console.log("Sorted currency0:", currency0);
        console.log("Sorted currency1:", currency1);
        console.log("Decimals0:", decimals0);
        console.log("Decimals1:", decimals1);

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

        // Verify pool is initialized before attempting to add liquidity
        (uint160 sqrtPriceX96,,,) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
        require(sqrtPriceX96 != 0, "Pool is not initialized. Run InitializePoolSepolia first.");
        console.log("Pool verified: sqrtPriceX96 =", sqrtPriceX96);

        // Amount of liquidity to add (dynamic based on decimals)
        uint256 amount0Max = 1_000 * 10**decimals0;
        uint256 amount1Max = 1_000 * 10**decimals1;

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

        // Liquidity: configurable via env, default to small test value
        uint128 liquidity;
        try vm.envUint("LIQUIDITY") returns (uint256 envLiquidity) {
            liquidity = uint128(envLiquidity);
            console.log("Using liquidity from env:", liquidity);
        } catch {
            liquidity = 10**9; // Default for testing
            console.log("Using default test liquidity:", liquidity);
        }

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
