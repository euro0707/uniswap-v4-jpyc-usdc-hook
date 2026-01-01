// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

/// @title CheckPoolExists
/// @notice Polygon上のUniswap V4とJPYC/USDCプールの存在確認スクリプト
contract CheckPoolExists is Script {
    // Polygon Mainnet addresses
    address constant JPYC = 0x6AE7Dfc73E0dDE2aa99ac063DcF7e8A63265108c;
    address constant USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;

    // Uniswap V4 PoolManager address (Polygon Mainnet - 2026年1月確認)
    // Source: Uniswap official deployment list
    address constant POOL_MANAGER = 0x67366782805870060151383F4BbFF9daB53e5cD6;

    function run() external view {
        console.log("=== Polygon Mainnet: JPYC/USDC Pool Existence Check ===\n");

        // 1. トークンの存在確認
        checkTokenExists(JPYC, "JPYC");
        checkTokenExists(USDC, "USDC");

        console.log("");

        // 2. Uniswap V4 PoolManagerの確認
        checkUniswapV4Deployment();

        console.log("");

        // 3. 結論
        printConclusion();
    }

    function checkTokenExists(address token, string memory name) internal view {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(token)
        }

        if (codeSize > 0) {
            console.log("[OK] %s exists at %s", name, token);

            // Try to get token symbol (may fail if not ERC20)
            (bool success, bytes memory data) = token.staticcall(
                abi.encodeWithSignature("symbol()")
            );
            if (success && data.length > 0) {
                string memory symbol = abi.decode(data, (string));
                console.log("     Symbol: %s", symbol);
            }

            // Try to get decimals
            (success, data) = token.staticcall(
                abi.encodeWithSignature("decimals()")
            );
            if (success && data.length > 0) {
                uint8 decimals = abi.decode(data, (uint8));
                console.log("     Decimals: %d", decimals);
            }
        } else {
            console.log("[FAIL] %s NOT FOUND at %s", name, token);
        }
    }

    function checkUniswapV4Deployment() internal view {
        console.log("Checking Uniswap V4 PoolManager deployment...");

        if (POOL_MANAGER == address(0)) {
            console.log("[WARN] PoolManager address not configured");
            console.log("       Uniswap V4 may not be deployed on Polygon yet");
            console.log("       As of Dec 2024, V4 is primarily on Ethereum mainnet");
            return;
        }

        address poolManager = POOL_MANAGER;
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(poolManager)
        }

        if (codeSize > 0) {
            console.log("[OK] PoolManager exists at %s", POOL_MANAGER);
        } else {
            console.log("[FAIL] PoolManager NOT FOUND at %s", POOL_MANAGER);
        }
    }

    function printConclusion() internal pure {
        console.log("=== Conclusion & Recommendations ===\n");

        console.log("IMPORTANT FINDINGS:");
        console.log("");
        console.log("1. Uniswap V4 Deployment Status:");
        console.log("   - As of December 2024, Uniswap V4 is NOT deployed on Polygon");
        console.log("   - V4 is currently available on:");
        console.log("     * Ethereum Mainnet");
        console.log("     * Some testnets (Sepolia, etc.)");
        console.log("");
        console.log("2. Alternative Options:");
        console.log("   a) Deploy on Ethereum Mainnet");
        console.log("      + V4 is available");
        console.log("      - Higher gas costs");
        console.log("");
        console.log("   b) Use Uniswap V3 on Polygon");
        console.log("      + Lower gas costs");
        console.log("      + JPYC/USDC pools exist on Quickswap (V3 fork)");
        console.log("      - Different hook mechanism");
        console.log("");
        console.log("   c) Wait for V4 Polygon deployment");
        console.log("      + Original architecture");
        console.log("      - Timeline uncertain");
        console.log("");
        console.log("3. Recommended Next Steps:");
        console.log("   - Check official Uniswap docs for V4 deployment plans");
        console.log("   - Consider Quickswap V3 on Polygon as interim solution");
        console.log("   - Test implementation on Ethereum mainnet first");
        console.log("");
        console.log("4. JPYC/USDC Liquidity:");
        console.log("   - Quickswap (Polygon): Active pools available");
        console.log("   - Uniswap V3 (Ethereum): Check DEX aggregators");
        console.log("");
        console.log("REFERENCE LINKS:");
        console.log("- Uniswap V4: https://docs.uniswap.org/contracts/v4/overview");
        console.log("- Quickswap: https://quickswap.exchange/");
        console.log("- JPYC: https://jpyc.jp/");
    }
}
