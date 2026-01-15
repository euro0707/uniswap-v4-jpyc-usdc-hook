// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @title InitializePoolPolygon
/// @notice Initialize JPYC/USDC pool with dynamic fee hook on Polygon Mainnet
contract InitializePoolPolygon is Script {
    // Polygon Mainnet Uniswap V4
    address constant POOL_MANAGER = 0x67366782805870060151383F4BbFF9daB53e5cD6;

    // Token addresses (Polygon Mainnet)
    // JPYC v2: 0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB (18 decimals)
    // USDC Native: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359 (6 decimals)

    // Environment variables (set these in .env)
    address TOKEN0;
    address TOKEN1;
    address HOOK;

    function run() external {
        TOKEN0 = vm.envAddress("TOKEN0_ADDRESS");
        TOKEN1 = vm.envAddress("TOKEN1_ADDRESS");
        HOOK = vm.envAddress("HOOK_ADDRESS");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("=== Initializing JPYC/USDC Pool on Polygon Mainnet ===\n");
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

        // Initial price for JPYC/USDC - REQUIRES explicit configuration
        //
        // IMPORTANT: sqrtPriceX96 calculation depends on token ordering and decimals.
        // You MUST set INITIAL_SQRT_PRICE_X96 in your .env file before running.
        //
        // Price calculation guide:
        // - sqrtPriceX96 = sqrt(price) * 2^96, where price = token1/token0 in raw units
        // - Raw units account for decimal differences
        //
        // For JPYC/USDC on Polygon:
        // - USDC: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359 (6 decimals)
        // - JPYC: 0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB (18 decimals)
        // - Since 0x3c49... < 0x431D..., USDC is currency0
        // - price (in raw units) = JPYC_raw / USDC_raw = 150 * 10^(18-6) = 1.5e14
        // - sqrtPriceX96 = sqrt(1.5e14) * 2^96 ≈ 9.7034e35
        //
        // To calculate for current market rate (e.g., 1 USD = 155 JPY):
        //   price_raw = 155 * 10^12 = 1.55e14
        //   sqrtPriceX96 = sqrt(1.55e14) * 2^96 ≈ 9.86e35
        //
        // Set in .env: INITIAL_SQRT_PRICE_X96=970342857091245893920548246077308928
        uint160 sqrtPriceX96;
        try vm.envUint("INITIAL_SQRT_PRICE_X96") returns (uint256 envPrice) {
            sqrtPriceX96 = uint160(envPrice);
            console.log("Using sqrtPriceX96 from env:", sqrtPriceX96);
        } catch {
            // FAIL SAFE: Require explicit price configuration for mainnet
            // Using an incorrect price can lead to immediate arbitrage losses
            revert("INITIAL_SQRT_PRICE_X96 env var is required. See comments for calculation guide.");
        }

        console.log("");
        console.log("IMPORTANT: Verify sqrtPriceX96 matches current JPYC/USD rate before broadcast!");
        console.log("");

        // Initialize pool
        IPoolManager(POOL_MANAGER).initialize(poolKey, sqrtPriceX96);

        console.log("=== Pool Initialized Successfully! ===");
        console.log("");
        console.log("Pool Details:");
        console.log("  Fee: DYNAMIC_FEE_FLAG (volatility-based)");
        console.log("  Tick Spacing: 60");
        console.log("  sqrtPriceX96:", sqrtPriceX96);
        console.log("");
        console.log("Next step:");
        console.log("  Run AddLiquidityPolygon.s.sol to add liquidity");

        vm.stopBroadcast();
    }
}
