// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "v4-periphery/src/interfaces/IStateView.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract CreateHookPoolAndMint is Script {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant REFERENCE_POOL_FEE = 500;
    uint256 internal constant DEFAULT_TICK_SPACING = 10;
    uint256 internal constant DEFAULT_RANGE_STEPS = 120;
    uint256 internal constant DEFAULT_USDC_MAX = 5_000_000; // 5 USDC (6 decimals)
    uint256 internal constant DEFAULT_JPYC_MAX = 800 ether; // 800 JPYC (18 decimals)

    address internal constant DEFAULT_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant DEFAULT_ACTIVE_HOOK = 0x1D4D185b1D0f86561f1D24DE10E7473e2772d0C0;
    address internal constant DEFAULT_USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address internal constant DEFAULT_JPYC = 0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.addr(deployerPk);

        address positionManagerAddr = vm.envAddress("POSITION_MANAGER");
        address stateViewAddr = vm.envAddress("STATE_VIEW");
        address permit2Addr = vm.envOr("PERMIT2_ADDRESS", DEFAULT_PERMIT2);
        address activeHookAddr = vm.envOr("ACTIVE_HOOK_ADDRESS", DEFAULT_ACTIVE_HOOK);

        address usdc = vm.envOr("ACTIVE_USDC_ADDRESS", DEFAULT_USDC);
        address jpyc = vm.envOr("ACTIVE_JPYC_ADDRESS", DEFAULT_JPYC);

        uint256 tickSpacingRaw = vm.envOr("TICK_SPACING", DEFAULT_TICK_SPACING);
        uint256 rangeStepsRaw = vm.envOr("RANGE_STEPS", DEFAULT_RANGE_STEPS);
        uint256 usdcMaxRaw = vm.envOr("USDC_MAX", DEFAULT_USDC_MAX);
        uint256 jpycMaxRaw = vm.envOr("JPYC_MAX", DEFAULT_JPYC_MAX);
        uint256 permit2ExpiryRaw = vm.envOr("PERMIT2_EXPIRY", uint256(block.timestamp + 30 days));
        uint256 deadlineRaw = vm.envOr("DEADLINE", uint256(block.timestamp + 15 minutes));

        int24 tickSpacing = _toInt24(tickSpacingRaw, "invalid tickSpacing");
        int24 rangeSteps = _toInt24(rangeStepsRaw, "invalid rangeSteps");
        uint128 usdcMax = _toUint128(usdcMaxRaw, "USDC_MAX too large");
        uint128 jpycMax = _toUint128(jpycMaxRaw, "JPYC_MAX too large");
        uint48 permit2Expiry = _toUint48(permit2ExpiryRaw, "PERMIT2_EXPIRY too large");

        // PoolKey must be token address sorted.
        (address token0, address token1, bool usdcIsToken0) =
            usdc < jpyc ? (usdc, jpyc, true) : (jpyc, usdc, false);

        uint128 amount0Max = usdcIsToken0 ? usdcMax : jpycMax;
        uint128 amount1Max = usdcIsToken0 ? jpycMax : usdcMax;

        PoolKey memory referenceKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: REFERENCE_POOL_FEE, // existing vanilla pool used only as a price reference
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        PoolKey memory hookKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(activeHookAddr)
        });

        IPositionManager positionManager = IPositionManager(positionManagerAddr);
        IStateView stateView = IStateView(stateViewAddr);
        IAllowanceTransfer permit2 = IAllowanceTransfer(permit2Addr);

        PoolId hookPoolId = hookKey.toId();

        uint160 initSqrtPriceX96 = _resolveInitSqrtPriceX96(stateView, referenceKey);
        uint160 existingHookSqrtPriceX96 = _readSqrtPriceX96(stateView, hookPoolId);
        bool alreadyInitialized = existingHookSqrtPriceX96 > 0;
        if (alreadyInitialized) initSqrtPriceX96 = existingHookSqrtPriceX96;

        console2.log("owner", owner);
        console2.log("positionManager", positionManagerAddr);
        console2.log("stateView", stateViewAddr);
        console2.log("permit2", permit2Addr);
        console2.log("hook", activeHookAddr);
        console2.log("token0", token0);
        console2.log("token1", token1);
        console2.log("hookPoolId");
        console2.logBytes32(PoolId.unwrap(hookPoolId));
        console2.log("initSqrtPriceX96", initSqrtPriceX96);
        console2.log("alreadyInitialized", alreadyInitialized);
        console2.log("amount0Max", amount0Max);
        console2.log("amount1Max", amount1Max);

        uint256 usdcBalance = IERC20(usdc).balanceOf(owner);
        uint256 jpycBalance = IERC20(jpyc).balanceOf(owner);
        require(usdcBalance >= usdcMax, "insufficient USDC for mint");
        require(jpycBalance >= jpycMax, "insufficient JPYC for mint");

        console2.log("usdcBalance", usdcBalance);
        console2.log("jpycBalance", jpycBalance);

        vm.startBroadcast(deployerPk);

        // PositionManager pulls ERC20 from payer through Permit2.
        IERC20(usdc).approve(permit2Addr, type(uint256).max);
        IERC20(jpyc).approve(permit2Addr, type(uint256).max);
        permit2.approve(usdc, positionManagerAddr, type(uint160).max, permit2Expiry);
        permit2.approve(jpyc, positionManagerAddr, type(uint160).max, permit2Expiry);

        if (!alreadyInitialized) {
            positionManager.initializePool(hookKey, initSqrtPriceX96);
            console2.log("initializePool executed");
        } else {
            console2.log("initializePool skipped (already initialized)");
        }

        (uint160 currentSqrtPriceX96, int24 currentTick,,) = stateView.getSlot0(hookPoolId);
        require(currentSqrtPriceX96 > 0, "hook pool still uninitialized");
        int24 centerTick = _floorToSpacing(currentTick, tickSpacing);
        int24 tickLower = centerTick - (tickSpacing * rangeSteps);
        int24 tickUpper = centerTick + (tickSpacing * rangeSteps);
        require(tickLower < tickUpper, "invalid tick range");
        require(tickLower >= TickMath.MIN_TICK && tickUpper <= TickMath.MAX_TICK, "tick out of bounds");

        uint128 liquidity = uint128(
            LiquidityAmounts.getLiquidityForAmounts(
                currentSqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                amount0Max,
                amount1Max
            )
        );
        require(liquidity > 0, "zero liquidity");

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] =
            abi.encode(hookKey, tickLower, tickUpper, uint256(liquidity), amount0Max, amount1Max, owner, bytes(""));
        params[1] = abi.encode(hookKey.currency0, hookKey.currency1);

        uint256 tokenIdBefore = positionManager.nextTokenId();
        positionManager.modifyLiquidities(abi.encode(actions, params), deadlineRaw);

        vm.stopBroadcast();

        console2.log("minted tokenId", tokenIdBefore);
        console2.log("tickLower", tickLower);
        console2.log("tickUpper", tickUpper);
        console2.log("liquidity", liquidity);
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && (tick % spacing) != 0) compressed--;
        return compressed * spacing;
    }

    function _resolveInitSqrtPriceX96(
        IStateView stateView,
        PoolKey memory referenceKey
    ) internal view returns (uint160 initSqrtPriceX96) {
        uint160 referenceSqrtPriceX96 = _readSqrtPriceX96(stateView, referenceKey.toId());
        if (referenceSqrtPriceX96 > 0) return referenceSqrtPriceX96;

        uint256 fallbackSqrtPriceRaw = vm.envOr("INIT_SQRT_PRICE_X96", uint256(0));
        require(fallbackSqrtPriceRaw > 0, "missing INIT_SQRT_PRICE_X96");
        return _toUint160(fallbackSqrtPriceRaw, "INIT_SQRT_PRICE_X96 too large");
    }

    function _readSqrtPriceX96(
        IStateView stateView,
        PoolId poolId
    ) internal view returns (uint160 sqrtPriceX96) {
        try stateView.getSlot0(poolId) returns (uint160 value, int24, uint24, uint24) {
            return value;
        } catch {
            return 0;
        }
    }

    function _toInt24(uint256 value, string memory errorMessage) internal pure returns (int24 result) {
        require(value > 0 && value <= uint256(uint24(type(int24).max)), errorMessage);
        // forge-lint: disable-next-line(unsafe-typecast)
        result = int24(int256(value));
    }

    function _toUint48(uint256 value, string memory errorMessage) internal pure returns (uint48 result) {
        require(value <= type(uint48).max, errorMessage);
        // forge-lint: disable-next-line(unsafe-typecast)
        result = uint48(value);
    }

    function _toUint128(uint256 value, string memory errorMessage) internal pure returns (uint128 result) {
        require(value <= type(uint128).max, errorMessage);
        // forge-lint: disable-next-line(unsafe-typecast)
        result = uint128(value);
    }

    function _toUint160(uint256 value, string memory errorMessage) internal pure returns (uint160 result) {
        require(value <= type(uint160).max, errorMessage);
        // forge-lint: disable-next-line(unsafe-typecast)
        result = uint160(value);
    }
}
