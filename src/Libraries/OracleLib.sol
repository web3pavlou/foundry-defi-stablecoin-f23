//SPDX-License-Identifier:MIT

pragma solidity ^0.8.29;

/**
 * @title OracleLib
 * @author web3pavlou
 * @notice This library is used to check the chainlink Oracle for stale data
 * If a price is stale it will revert and it render the DSCEngine unusable - this is by design
 * @notice check L2 sequencer uptime feeds on supported rollups: Arbitrum,ZkSync
 *
 * So if the chainlink network explodes and you have a lot of money in the protocol...
 */

import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

library OracleLib {
    error OracleLib__PriceNotUpdatedProperly();

    error OracleLib__StalePrice();
    error OracleLib__SequencerDown();
    error OracleLib__GracePeriodNotOver();
    error OracleLib__PriceOutOfBounds(int256 price, int256 min, int256 max);

    /// @notice DEFAULT - protocols are expected to override per asset
    uint256 private constant TIMEOUT = 3 hours;

    /// @notice Time to wait before the sequencer comes back before resuming.
    uint256 private constant GRACE_PERIOD_TIME = 1 hours;

    ////////////////////////////
    // Supported L2 Chain Ids //
    ////////////////////////////
    uint256 private constant ETHEREUM_MAINNET = 1;
    uint256 private constant SEPOLIA_TESTNET = 11_155_111;
    uint256 private constant ARBITRUM_ONE_CHAIN_ID = 42_161;
    uint256 private constant ZKSYNC_MAINNET_CHAIN_ID = 324;

    ///////////////////////////////////
    // Sequencer uptime feed proxies //
    ///////////////////////////////////
    address private constant ARBITRUM_ONE_UPTIME_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    address private constant ZKSYNC_MAINNET_UPTIME_FEED = 0x0E6AC8B967393dcD3D36677c126976157F993940;

    function staleCheckLatestRoundData(
        AggregatorV3Interface priceFeed,
        uint256 maxPriceAge
    )
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        _checkSequencerIfApplicable();

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();
        if (updatedAt == 0) {
            revert OracleLib__PriceNotUpdatedProperly();
        }

        if (updatedAt > block.timestamp) {
            revert OracleLib__PriceNotUpdatedProperly();
        }

        if (answeredInRound < roundId) revert OracleLib__PriceNotUpdatedProperly();

        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > maxPriceAge) {
            revert OracleLib__StalePrice();
        }

        (int256 min, int256 max) = _getPriceBounds(priceFeed);

        if (answer < min || answer > max || answer == 0) {
            revert OracleLib__PriceOutOfBounds(answer, min, max);
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    /**
     * @dev If we re on a supported L2, check the sequencer uptime feed:
     * - revert if sequencer is down
     * - revert if grace period after coming back has not yet passed
     * On all other chains (l1s,local dev) this is a no-op
     */

    function _checkSequencerIfApplicable() private view {
        AggregatorV3Interface sequencerUptimeFeed;
        if (block.chainid == ARBITRUM_ONE_CHAIN_ID) {
            sequencerUptimeFeed = AggregatorV3Interface(ARBITRUM_ONE_UPTIME_FEED);
        } else if (block.chainid == ZKSYNC_MAINNET_CHAIN_ID) {
            sequencerUptimeFeed = AggregatorV3Interface(ZKSYNC_MAINNET_UPTIME_FEED);
        } else {
            // L1 / unsupported chain: nothing to do
            return;
        }
        (
            /* uint80 roundId */,
            int256 answer,
            uint256 startedAt,
            /* uint256 updatedAt */,
            /* uint80 answeredInRound */
        ) = sequencerUptimeFeed.latestRoundData();

        // 0 = up,1 = down
        bool isSequencerUp = (answer == 0);
        if (!isSequencerUp) {
            revert OracleLib__SequencerDown();
        }

        // Make sure enough time has passed since sequencer came back
        uint256 timeSinceUp = block.timestamp - startedAt;

        /// @dev For Arbitrum, startedAt can be 0 when the feed is not initialized.
        if (timeSinceUp <= GRACE_PERIOD_TIME) {
            revert OracleLib__GracePeriodNotOver();
        }
    }

    function _getPriceBounds(AggregatorV3Interface priceFeed) private view returns (int256 min, int256 max) {
        // Default - no bounds
        min = type(int256).min;
        max = type(int256).max;

        address feed = address(priceFeed);

        // ethereum mainnet
        if (block.chainid == ETHEREUM_MAINNET) {
            //ETH/USD
            if (feed == 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419) {
                min = 100e8;
                max = 100_000e8;
            }

            //BTC/USD
            if (feed == 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c) {
                min = 1000e8;
                max = 1_000_000e8;
            }
        }

        if (block.chainid == SEPOLIA_TESTNET) {
            //ETH/USD
            if (feed == 0x694AA1769357215DE4FAC081bf1f309aDC325306) {
                min = 100e8;
                max = 100_000e8;
            }

            //BTC/USD
            if (feed == 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43) {
                min = 1000e8;
                max = 1_000_000e8;
            }
        }

        if (block.chainid == ARBITRUM_ONE_CHAIN_ID) {
            if (feed == 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612) {
                //ETH/USD
                min = 100e8;
                max = 100_000e8;
            }
            if (feed == 0x6ce185860a4963106506C203335A2910413708e9) {
                //BTC/USD
                min = 1000e8;
                max = 1_000_000e8;
            }
        }
        if (block.chainid == ZKSYNC_MAINNET_CHAIN_ID) {
            if (feed == 0x6D41d1dc818112880b40e26BD6FD347E41008eDA) {
                //ETH/USD
                min = 100e8;
                max = 100_000e8;
            }

            if (feed == 0x4Cba285c15e3B540C474A114a7b135193e4f1EA6) {
                //BTC/USD
                min = 1000e8;
                max = 1_000_000e8;
            }
        }
    }

    function getTimeOut(
        AggregatorV3Interface /*chainlinkFeed */
    )
        public
        pure
        returns (uint256)
    {
        return TIMEOUT;
    }

    function getGracePeriod(
        AggregatorV3Interface /* chainlinkFeed */
    )
        public
        pure
        returns (uint256)
    {
        return GRACE_PERIOD_TIME;
    }
}
