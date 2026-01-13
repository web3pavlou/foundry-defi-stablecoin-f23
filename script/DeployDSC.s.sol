// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script } from "forge-std/Script.sol";
import { HelperConfig } from "./HelperConfig.s.sol";
import { DWebThreePavlouStableCoin } from "../src/DWebThreePavlouStableCoin.sol";
import { DSCEngine } from "../src/DSCEngine.sol";
import { FlashMintDWebThreePavlou } from "../src/FlashMintDWebThreePavlou.sol";

contract DeployDSC is Script {
    // address[] public tokenAddresses;
    // address[] public priceFeedAddresses;

    function run()
        external
        returns (
            DWebThreePavlouStableCoin dsc,
            DSCEngine dsce,
            HelperConfig helperConfig,
            FlashMintDWebThreePavlou flashMinter
        )
    {
        helperConfig = new HelperConfig(); // This comes with our mocks!

        (
            address wethUsdPriceFeed,
            address wbtcUsdPriceFeed,
            address weth,
            address wbtc,
            uint256 deployerKey,
            uint256 wethMaxPriceAge,
            uint256 wbtcMaxPriceAge
        ) = helperConfig.activeNetworkConfig();

        address[] memory tokenAddresses = new address[](2);
        tokenAddresses[0] = weth;
        tokenAddresses[1] = wbtc;
        address[] memory priceFeedAddresses = new address[](2);
        priceFeedAddresses[0] = wethUsdPriceFeed;
        priceFeedAddresses[1] = wbtcUsdPriceFeed;

        vm.startBroadcast(deployerKey);
        address deployer = vm.addr(deployerKey);

        dsc = new DWebThreePavlouStableCoin(deployer); // deployer is owner for now

        dsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc), deployer);
        flashMinter = new FlashMintDWebThreePavlou(address(dsce), address(dsc));

        dsc.transferOwnership(address(dsce)); // Transfer ownership of DSC to DSCEngine (so engine is final owner)

        dsce.setFlashMinter(address(flashMinter)); // wire the real flashMinter into the engine

        dsce.setMaxPriceAge(weth, wethMaxPriceAge);
        dsce.setMaxPriceAge(wbtc, wbtcMaxPriceAge);

        vm.stopBroadcast();
        return (dsc, dsce, helperConfig, flashMinter);
    }
}
