//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import { Script } from "forge-std/Script.sol";
import { MockV3Aggregator } from "../test/Mocks/MockV3Aggregator.sol";
import { ERC20DecimalsMock } from "../test/Mocks/ERC20DecimalsMock.sol";

contract HelperConfig is Script {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/
    struct NetworkConfig {
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address weth;
        address wbtc;
        uint256 deployerKey;
        uint256 wethMaxPriceAge;
        uint256 wbtcMaxPriceAge;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    NetworkConfig public activeNetworkConfig;

    // Constants for normalization and consistency
    uint8 public constant FEED_DECIMALS = 8;
    uint8 public constant WETH_DECIMALS = 18;
    uint8 public constant WBTC_DECIMALS = 8;

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 1000e8;

    constructor() {
        if (block.chainid == 11_155_111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory sepoliaNetworkConfig) {
        uint256 key;
        try vm.envUint("PRIVATE_KEY") returns (uint256 k) {
            key = k;
        } catch {
            key = 1; // fallback so tests/CI don't revert if chainid is set to sepolia
        }

        sepoliaNetworkConfig = NetworkConfig({
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wbtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            weth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wbtc: 0x29f2D40B0605204364af54EC677bD022dA425d03,
            deployerKey: key,
            wethMaxPriceAge: 3 hours,
            wbtcMaxPriceAge: 3 hours
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory anvilNetworkConfig) {
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        uint256 key;
        try vm.envUint("DEFAULT_ANVIL_PRIVATE_KEY") returns (uint256 k) {
            key = k;
        } catch {
            // CI / tests: no env var -> fall back to a deterministic key
            key = 1;
        }

        vm.startBroadcast(key);

        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(FEED_DECIMALS, ETH_USD_PRICE);

        ERC20DecimalsMock wethMock = new ERC20DecimalsMock("WETH", "WETH", WETH_DECIMALS);
        wethMock.mint(msg.sender, 1000 * 10 ** WETH_DECIMALS);

        MockV3Aggregator btcUsdPriceFeed = new MockV3Aggregator(FEED_DECIMALS, BTC_USD_PRICE);

        ERC20DecimalsMock wbtcMock = new ERC20DecimalsMock("WBTC", "WBTC", WBTC_DECIMALS);
        wbtcMock.mint(msg.sender, 1000 * 10 ** WBTC_DECIMALS);

        vm.stopBroadcast();

        return anvilNetworkConfig = NetworkConfig({
            wethUsdPriceFeed: address(ethUsdPriceFeed),
            wbtcUsdPriceFeed: address(btcUsdPriceFeed),
            weth: address(wethMock),
            wbtc: address(wbtcMock),
            deployerKey: key,
            wethMaxPriceAge: 4 hours,
            wbtcMaxPriceAge: 4 hours
        });
    }
}
