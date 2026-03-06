// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";

contract DeployDynamicFeeHook is Script {
    // Polygon Mainnet v4 PoolManager (official address)
    address constant POOL_MANAGER =
        0x67366782805870060151383F4BbFF9daB53e5cD6;
    // CREATE2 deployer (chain-agnostic)
    address constant CREATE2_DEPLOYER =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() public {
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG      |
            Hooks.AFTER_SWAP_FLAG
        );

        address usdc = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
        address jpyc = 0x6AE7Dfc73E0dDE2aa99ac063DcF7e8A63265108c;
        bytes memory args = abi.encode(
            IPoolManager(POOL_MANAGER), usdc, jpyc
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, flags,
            type(DynamicFeeHook).creationCode, args
        );
        console2.log("Hook address:", hookAddr);
        console2.log("Salt:", vm.toString(salt));

        vm.broadcast();
        DynamicFeeHook hook = new DynamicFeeHook{salt: salt}(
            IPoolManager(POOL_MANAGER), usdc, jpyc
        );
        require(address(hook) == hookAddr, "Address mismatch!");
        console2.log("Deployed:", address(hook));
    }
}
