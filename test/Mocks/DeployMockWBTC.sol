// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { console } from "forge-std/console.sol";
import { MockV3Aggregator } from "./MockV3Aggregator.sol";

contract DeployMockWBTC is Script {
    // BTC/USD price feed mock settings
    int256 public constant INITIAL_BTC_PRICE = 30_000e8; // $30,000 * 1e8
    uint8 public constant BTC_FEED_DECIMALS = 8;

    // ERC20Mock settings
    uint8 public constant WBTC_DECIMALS = 8;
    uint256 public constant INITIAL_SUPPLY = 1000e8; // 1000 WBTC

    function run() external returns (ERC20Mock mockWbtc, MockV3Aggregator btcUsdPriceFeed) {
        vm.startBroadcast();

        // Deploy MockWBTC (ERC20Mock)
        mockWbtc = new ERC20Mock();

        mockWbtc.mint(msg.sender, 1000e8); // mint 1000 WBTC to deployer

        // Deploy BTC/USD price feed mock
        btcUsdPriceFeed = new MockV3Aggregator(BTC_FEED_DECIMALS, INITIAL_BTC_PRICE);

        vm.stopBroadcast();

        console.log("MockWBTC deployed at:", address(mockWbtc));
        console.log("BTC/USD Mock Price Feed deployed at:", address(btcUsdPriceFeed));
    }
}
