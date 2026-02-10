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

/// @title AddLiquidityPolygon
/// @notice Add liquidity to the JPYC/USDC pool with dynamic fee hook on Polygon Mainnet
contract AddLiquidityPolygon is Script {
    // Polygon Mainnet Uniswap V4
    address constant POOL_MANAGER = 0x67366782805870060151383F4BbFF9daB53e5cD6;
    address constant POSITION_MANAGER = 0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Token addresses (for reference)
    // JPYC v2: 0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB (18 decimals)
    // USDC Native: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359 (6 decimals)

    function run() external {
        require(block.chainid == 137, "This script is for Polygon mainnet only (chainId: 137)");

        address token0Addr = vm.envAddress("TOKEN0_ADDRESS");
        address token1Addr = vm.envAddress("TOKEN1_ADDRESS");
        address hookAddr = vm.envAddress("HOOK_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Adding Liquidity on Polygon Mainnet ===\n");
        console.log("Deployer:", deployer);
        console.log("Token0:", token0Addr);
        console.log("Token1:", token1Addr);
        console.log("Hook:", hookAddr);

        // Ensure correct token ordering
        address currency0 = token0Addr < token1Addr ? token0Addr : token1Addr;
        address currency1 = token0Addr < token1Addr ? token1Addr : token0Addr;

        console.log("Sorted currency0:", currency0);
        console.log("Sorted currency1:", currency1);

        // Determine decimals based on token addresses
        // JPYC: 0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB (18 decimals)
        // USDC: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359 (6 decimals)
        address JPYC = 0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB;
        address USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

        uint8 decimals0 = (currency0 == JPYC) ? 18 : 6;
        uint8 decimals1 = (currency1 == JPYC) ? 18 : 6;

        vm.startBroadcast(deployerPrivateKey);

        // NOTE: All operations within startBroadcast/stopBroadcast are atomic.
        // If any operation reverts (e.g., missing LIQUIDITY env var), the entire
        // transaction batch is rolled back - no approvals will be sent to chain.

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
        // For mainnet, use appropriate amounts based on your holdings
        // Allow configuration via environment variables
        uint256 amount0Max;
        uint256 amount1Max;

        try vm.envUint("AMOUNT0_MAX") returns (uint256 envAmount0) {
            amount0Max = envAmount0;
        } catch {
            // Default: 10,000 tokens (adjust for decimals)
            amount0Max = 10_000 * 10**decimals0;
        }

        try vm.envUint("AMOUNT1_MAX") returns (uint256 envAmount1) {
            amount1Max = envAmount1;
        } catch {
            // Default: 10,000 tokens (adjust for decimals)
            amount1Max = 10_000 * 10**decimals1;
        }

        console.log("");
        console.log("=== Liquidity Parameters ===");
        console.log("Tick Lower:", tickLower);
        console.log("Tick Upper:", tickUpper);
        console.log("Amount0Max:", amount0Max);
        console.log("Amount1Max:", amount1Max);

        // Encode actions for PositionManager
        // Use MINT_POSITION + CLOSE_CURRENCY (not SETTLE)
        // CLOSE_CURRENCY automatically settles any remaining debt
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY)
        );

        // LIQUIDITY must be explicitly set via environment variable
        //
        // For full-range positions, liquidity relates to amounts via:
        //   amount0 = liquidity * (1/sqrt(price_low) - 1/sqrt(price_high))
        //   amount1 = liquidity * (sqrt(price_high) - sqrt(price_low))
        //
        // Calculate liquidity off-chain using LiquidityAmounts.getLiquidityForAmounts
        // or use a tool like:
        //   https://uniswap.org/blog/uniswap-v3-math-primer
        //
        // Example for small test position: LIQUIDITY=1000000000 (10^9)
        uint128 liquidity;
        try vm.envUint("LIQUIDITY") returns (uint256 envLiquidity) {
            liquidity = uint128(envLiquidity);
            console.log("Using liquidity from env:", liquidity);
        } catch {
            // FAIL SAFE: Require explicit liquidity for mainnet
            // Using incorrect liquidity can exceed amount caps and revert
            revert("LIQUIDITY env var is required. Calculate based on desired position size and current price.");
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
        console.log("");
        console.log("Your JPYC/USDC pool with dynamic fee hook is now live on Polygon!");

        vm.stopBroadcast();
    }
}
