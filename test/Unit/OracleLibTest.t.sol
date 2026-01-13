//SPDX-License-Identifier:MIT

pragma solidity ^0.8.29;

import { Test, console } from "forge-std/Test.sol";

import { OracleLib } from "../../src/Libraries/OracleLib.sol";
import { MockV3Aggregator } from "../Mocks/MockV3Aggregator.sol";
import { MockSequencerUptimeFeed } from "../Mocks/MockSequencerUptimeFeed.sol";
import { MockConfigurableAggregator } from "../Mocks/MockConfigurableAggregator.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract OracleLibTest is Test {
    using OracleLib for AggregatorV3Interface;

    MockV3Aggregator public aggregator;
    MockSequencerUptimeFeed public sequencerUptimeFeed;

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42_161;
    address constant ARBITRUM_ONE_UPTIME_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    uint256 constant ZKSYNC_MAINNET_CHAIN_ID = 324;
    address constant ZKSYNC_MAINNET_UPTIME_FEED = 0x0E6AC8B967393dcD3D36677c126976157F993940;

    uint8 public constant DECIMALS = 8;
    int256 public constant INITIAL_ANSWER = 2000e8;

    uint256 internal maxPriceAge;

    function setUp() public {
        // Simulate Arbitrum One
        vm.chainId(ARBITRUM_ONE_CHAIN_ID);
        // Normal price feed
        aggregator = new MockV3Aggregator(DECIMALS, INITIAL_ANSWER);

        //Default timeout from OracleLib
        maxPriceAge = OracleLib.getTimeOut(AggregatorV3Interface(address(aggregator)));

        // Deploy a sequencer uptime mock implementation
        MockSequencerUptimeFeed impl = new MockSequencerUptimeFeed();

        // Install its code at the canonical uptime feed address that OracleLib uses
        vm.etch(ARBITRUM_ONE_UPTIME_FEED, address(impl).code);

        // Point our handle to that canonical address so we can call setStatus()
        sequencerUptimeFeed = MockSequencerUptimeFeed(ARBITRUM_ONE_UPTIME_FEED);

        // Move time forward so we’re well past t=0
        vm.warp(10 hours);
        vm.roll(block.number + 1); // redundant but just to be sure

        // Default baseline: sequencer UP and out of grace period
        sequencerUptimeFeed.setStatus(0, block.timestamp - 2 hours);
    }

    ///////////////////
    // Uptime Feed   //
    ///////////////////

    function testSequencerDown() public {
        sequencerUptimeFeed.setStatus(1, block.timestamp - 2 hours); // 1 -> sequencer 's down

        vm.expectRevert(OracleLib.OracleLib__SequencerDown.selector);
        AggregatorV3Interface(address(aggregator)).staleCheckLatestRoundData(maxPriceAge);
    }

    // Sequencer is up but grace period not over
    function testSequencerPeriodNotOverReverts() public {
        sequencerUptimeFeed.setStatus(0, block.timestamp - 10 minutes);

        vm.expectRevert(OracleLib.OracleLib__GracePeriodNotOver.selector);
        AggregatorV3Interface(address(aggregator)).staleCheckLatestRoundData(maxPriceAge);
    }

    // If on L1 sequencer gets ignored
    function testNoSequencerCheckOnL1() public {
        vm.chainId(1);
        aggregator.updateAnswer(INITIAL_ANSWER);

        AggregatorV3Interface(address(aggregator)).staleCheckLatestRoundData(maxPriceAge);
    }

    function testZkSyncSequencerHappyPath() public {
        vm.chainId(324);

        MockSequencerUptimeFeed zkImpl = new MockSequencerUptimeFeed();

        vm.etch(ZKSYNC_MAINNET_UPTIME_FEED, address(zkImpl).code);

        MockSequencerUptimeFeed zkSequencer = MockSequencerUptimeFeed(ZKSYNC_MAINNET_UPTIME_FEED);

        vm.warp(block.timestamp + 5 hours);
        zkSequencer.setStatus(0, block.timestamp - 2 hours);

        aggregator.updateAnswer(INITIAL_ANSWER);

        AggregatorV3Interface(address(aggregator)).staleCheckLatestRoundData(maxPriceAge);
    }

    ////////////////////////
    // Stale Price Checks //
    ////////////////////////

    // Price gets stale purely by time
    function testPriceRevertsOnStaleCheck() public {
        // Make time pass so that last price update becomes older than TIMEOUT (3 hours)
        vm.warp(block.timestamp + 4 hours + 1 seconds);
        vm.roll(block.number + 1);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        AggregatorV3Interface(address(aggregator)).staleCheckLatestRoundData(maxPriceAge);
    }

    function testFreshPriceDoesNotRevert() public {
        vm.warp(block.timestamp + 1 hours);

        //update the price so updatedAt = now (<TIMEOUT)
        aggregator.updateAnswer(INITIAL_ANSWER);

        AggregatorV3Interface(address(aggregator)).staleCheckLatestRoundData(maxPriceAge);
    }

    function testRevertsWhenUpdatedAtIsZero() public {
        aggregator.updateRoundData(1, INITIAL_ANSWER, 0, block.timestamp - 1);

        vm.expectRevert(OracleLib.OracleLib__PriceNotUpdatedProperly.selector);
        AggregatorV3Interface(address(aggregator)).staleCheckLatestRoundData(maxPriceAge);
    }

    function testRevertsWhenUpdatedAtIsInTheFuture() public {
        uint256 future = block.timestamp + 1;
        aggregator.updateRoundData(1, INITIAL_ANSWER, future, block.timestamp - 2);

        vm.expectRevert(OracleLib.OracleLib__PriceNotUpdatedProperly.selector);
        AggregatorV3Interface(address(aggregator)).staleCheckLatestRoundData(maxPriceAge);
    }

    function testRevertsWhenAnsweredInRoundLessThanRoundId() public {
        // Uses a configurable feed so we can set answeredInRound independently
        MockConfigurableAggregator feed = new MockConfigurableAggregator(DECIMALS);

        // answeredInRound (1) < roundId (2) => should revert
        feed.setRoundData({
            roundId_: 2,
            answer_: INITIAL_ANSWER,
            startedAt_: block.timestamp - 10,
            updatedAt_: block.timestamp - 1,
            answeredInRound_: 1
        });

        vm.expectRevert(OracleLib.OracleLib__PriceNotUpdatedProperly.selector);
        AggregatorV3Interface(address(feed)).staleCheckLatestRoundData(maxPriceAge);
    }

    function testRevertsWhenAnswerIsZeroEvenWithNoBounds() public {
        vm.chainId(252);

        MockConfigurableAggregator feed = new MockConfigurableAggregator(DECIMALS);

        feed.setRoundData({
            roundId_: 1,
            answer_: 0,
            startedAt_: block.timestamp - 10,
            updatedAt_: block.timestamp - 1,
            answeredInRound_: 1
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                OracleLib.OracleLib__PriceOutOfBounds.selector, int256(0), type(int256).min, type(int256).max
            )
        );

        AggregatorV3Interface(address(feed)).staleCheckLatestRoundData(maxPriceAge);
    }

    /////////////////////////////////////////////
    // Per-asset / per-chain maxPriceAge tests //
    /////////////////////////////////////////////

    /// @notice Simulate an "Arbitrum-style" 24h heartbeat:
    /// price is considered fresh up to 24 hours, then stale.
    function testArbitrumStyle24hHeartbeatAllowsUpTo24Hours() public {
        uint256 arbMaxAge = 24 hours;
        maxPriceAge = arbMaxAge;

        // fresh update now
        aggregator.updateAnswer(INITIAL_ANSWER);

        // 23 hours later -> should still be OK
        vm.warp(block.timestamp + 23 hours);
        AggregatorV3Interface(address(aggregator)).staleCheckLatestRoundData(maxPriceAge);
    }

    function testArbitrumStyle24hHeartbeatRevertsAfter24Hours() public {
        uint256 arbMaxAge = 24 hours;
        maxPriceAge = arbMaxAge;

        // fresh update now
        aggregator.updateAnswer(INITIAL_ANSWER);

        // 24h + 1 second later -> should revert
        vm.warp(block.timestamp + 24 hours + 1 seconds);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        AggregatorV3Interface(address(aggregator)).staleCheckLatestRoundData(maxPriceAge);
    }

    /// @notice Simulate an asset that we want to treat with a *stricter*
    /// max age (e.g. 30 minutes) even though the library default is 3 hours.
    function testAssetSpecificTighterMaxAgeCanBeStricterThanDefault() public {
        uint256 tightMaxAge = 30 minutes;
        maxPriceAge = tightMaxAge;

        // fresh update now
        aggregator.updateAnswer(INITIAL_ANSWER);

        // 1 hour later -> 1h > 30m, so we should now revert
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        AggregatorV3Interface(address(aggregator)).staleCheckLatestRoundData(maxPriceAge);
    }

    /////////////////////////////
    // Price Bounds Boundaries //
    /////////////////////////////

    function testEthUsdAtExactMinOnMainnetDoesNotRevert() public {
        vm.chainId(1);

        address MAINNET_ETH_USD_PRICEFEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);
        vm.etch(MAINNET_ETH_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(MAINNET_ETH_USD_PRICEFEED);

        // exact min (should NOT revert because check is answer < min)
        feed.updateAnswer(100e8);

        AggregatorV3Interface(MAINNET_ETH_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testBtcUsdAtExactMaxOnMainnetDoesNotRevert() public {
        vm.chainId(1);

        address MAINNET_BTC_USD_PRICEFEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);
        vm.etch(MAINNET_BTC_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(MAINNET_BTC_USD_PRICEFEED);

        // exact max (should NOT revert because check is answer > max)
        feed.updateAnswer(1_000_000e8);

        AggregatorV3Interface(MAINNET_BTC_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetDefaultNoPriceBoundForNotSetChainId() public {
        vm.chainId(252);

        address irrelevantAddressFeed = 0xf1769eB4D1943AF02ab1096D7893759F6177D6B8;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);
        vm.etch(irrelevantAddressFeed, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(irrelevantAddressFeed);

        int256 answer = 99e8;
        feed.updateAnswer(answer);

        // No revert => no sequencer check, and bounds default to min/max int256.
        AggregatorV3Interface(irrelevantAddressFeed).staleCheckLatestRoundData(maxPriceAge);
    }

    ////////////////////////
    // Price Bounds (ETH) //
    ////////////////////////

    function testGetBelowMinPriceBoundOnEthereumMainnetForEthUsdPriceFeedReverts() public {
        vm.chainId(1);

        address MAINNET_ETH_USD_PRICEFEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);

        vm.etch(MAINNET_ETH_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(MAINNET_ETH_USD_PRICEFEED);

        int256 answer = 99e8;
        int256 minAnswer = 100e8;
        int256 maxAnswer = 100_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );
        AggregatorV3Interface(MAINNET_ETH_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetAboveMaxPriceOnEthereumMainnetForEthUsdPriceFeedReverts() public {
        vm.chainId(1);

        address MAINNET_ETH_USD_PRICEFEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);

        vm.etch(MAINNET_ETH_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(MAINNET_ETH_USD_PRICEFEED);

        int256 answer = 100_001e8;
        int256 minAnswer = 100e8;
        int256 maxAnswer = 100_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );
        AggregatorV3Interface(MAINNET_ETH_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetBelowMinPriceOnArbitrumOneForEthUsdPriceFeedReverts() public {
        vm.chainId(42_161);

        address ARBITRUM_ONE_ETH_USD_PRICEFEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);

        vm.etch(ARBITRUM_ONE_ETH_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(ARBITRUM_ONE_ETH_USD_PRICEFEED);

        int256 answer = 99e8;
        int256 minAnswer = 100e8;
        int256 maxAnswer = 100_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );
        AggregatorV3Interface(ARBITRUM_ONE_ETH_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetAboveMaxPriceOnArbitrumOneForEthUsdPriceFeedReverts() public {
        vm.chainId(42_161);

        address ARBITRUM_ONE_ETH_USD_PRICEFEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);

        vm.etch(ARBITRUM_ONE_ETH_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(ARBITRUM_ONE_ETH_USD_PRICEFEED);

        int256 answer = 100_001e8;
        int256 minAnswer = 100e8;
        int256 maxAnswer = 100_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );
        AggregatorV3Interface(ARBITRUM_ONE_ETH_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetBelowMinPriceOnSepoliaTestnetForEthUsdPriceFeedReverts() public {
        vm.chainId(11_155_111);

        address SEPOLIA_TESTNET_ETH_USD_PRICEFEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);

        vm.etch(SEPOLIA_TESTNET_ETH_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(SEPOLIA_TESTNET_ETH_USD_PRICEFEED);

        int256 answer = 99e8;
        int256 minAnswer = 100e8;
        int256 maxAnswer = 100_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );
        AggregatorV3Interface(SEPOLIA_TESTNET_ETH_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetAboveMaxPriceOnSepoliaTestnetForEthUsdPriceFeedReverts() public {
        vm.chainId(11_155_111);

        address SEPOLIA_TESTNET_ETH_USD_PRICEFEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);

        vm.etch(SEPOLIA_TESTNET_ETH_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(SEPOLIA_TESTNET_ETH_USD_PRICEFEED);

        int256 answer = 100_001e8;
        int256 minAnswer = 100e8;
        int256 maxAnswer = 100_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );
        AggregatorV3Interface(SEPOLIA_TESTNET_ETH_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetBelowMinPriceOnZKSyncForEthUsdPriceFeedReverts() public {
        vm.chainId(324);

        MockSequencerUptimeFeed zkImpl = new MockSequencerUptimeFeed();

        vm.etch(ZKSYNC_MAINNET_UPTIME_FEED, address(zkImpl).code);

        MockSequencerUptimeFeed zkSequencer = MockSequencerUptimeFeed(ZKSYNC_MAINNET_UPTIME_FEED);

        zkSequencer.setStatus(0, block.timestamp - 2 hours);

        address ZK_SYNC_BTC_USD_PRICEFEED = 0x6D41d1dc818112880b40e26BD6FD347E41008eDA;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);

        vm.etch(ZK_SYNC_BTC_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(ZK_SYNC_BTC_USD_PRICEFEED);

        int256 answer = 99e8;
        int256 minAnswer = 100e8;
        int256 maxAnswer = 100_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );
        AggregatorV3Interface(ZK_SYNC_BTC_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetAboveMaxPriceOnZKSyncForEthUsdPriceFeedReverts() public {
        vm.chainId(324);

        MockSequencerUptimeFeed zkImpl = new MockSequencerUptimeFeed();

        vm.etch(ZKSYNC_MAINNET_UPTIME_FEED, address(zkImpl).code);

        MockSequencerUptimeFeed zkSequencer = MockSequencerUptimeFeed(ZKSYNC_MAINNET_UPTIME_FEED);

        zkSequencer.setStatus(0, block.timestamp - 2 hours);

        address ZK_SYNC_BTC_USD_PRICEFEED = 0x6D41d1dc818112880b40e26BD6FD347E41008eDA;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);

        vm.etch(ZK_SYNC_BTC_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(ZK_SYNC_BTC_USD_PRICEFEED);

        int256 answer = 100_001e8;
        int256 minAnswer = 100e8;
        int256 maxAnswer = 100_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );
        AggregatorV3Interface(ZK_SYNC_BTC_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    ////////////////////////
    // Price Bounds (BTC) //
    ////////////////////////

    function testGetBelowMinPriceOnZKSyncForBtcUsdPriceFeedReverts() public {
        vm.chainId(324);

        MockSequencerUptimeFeed zkImpl = new MockSequencerUptimeFeed();

        vm.etch(ZKSYNC_MAINNET_UPTIME_FEED, address(zkImpl).code);

        MockSequencerUptimeFeed zkSequencer = MockSequencerUptimeFeed(ZKSYNC_MAINNET_UPTIME_FEED);

        zkSequencer.setStatus(0, block.timestamp - 2 hours);

        address ZK_SYNC_BTC_USD_PRICEFEED = 0x4Cba285c15e3B540C474A114a7b135193e4f1EA6;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);

        vm.etch(ZK_SYNC_BTC_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(ZK_SYNC_BTC_USD_PRICEFEED);

        int256 answer = 999e8;
        int256 minAnswer = 1000e8;
        int256 maxAnswer = 1_000_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );
        AggregatorV3Interface(ZK_SYNC_BTC_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetBelowMinPriceBoundOnEthereumMainnetForBtcUsdPriceFeedReverts() public {
        vm.chainId(1);

        address MAINNET_BTC_USD_PRICEFEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);
        vm.etch(MAINNET_BTC_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(MAINNET_BTC_USD_PRICEFEED);

        int256 answer = 999e8;
        int256 minAnswer = 1000e8;
        int256 maxAnswer = 1_000_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );

        AggregatorV3Interface(MAINNET_BTC_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetAboveMaxPriceOnEthereumMainnetForBtcUsdPriceFeedReverts() public {
        vm.chainId(1);

        address MAINNET_BTC_USD_PRICEFEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);
        vm.etch(MAINNET_BTC_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(MAINNET_BTC_USD_PRICEFEED);

        int256 answer = 1_000_001e8;
        int256 minAnswer = 1000e8;
        int256 maxAnswer = 1_000_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );

        AggregatorV3Interface(MAINNET_BTC_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetBelowMinPriceOnSepoliaTestnetForBtcUsdPriceFeedReverts() public {
        vm.chainId(11_155_111);

        address SEPOLIA_BTC_USD_PRICEFEED = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);
        vm.etch(SEPOLIA_BTC_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(SEPOLIA_BTC_USD_PRICEFEED);

        int256 answer = 999e8;
        int256 minAnswer = 1000e8;
        int256 maxAnswer = 1_000_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );

        AggregatorV3Interface(SEPOLIA_BTC_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetAboveMaxPriceOnSepoliaTestnetForBtcUsdPriceFeedReverts() public {
        vm.chainId(11_155_111);

        address SEPOLIA_BTC_USD_PRICEFEED = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);
        vm.etch(SEPOLIA_BTC_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(SEPOLIA_BTC_USD_PRICEFEED);

        int256 answer = 1_000_001e8;
        int256 minAnswer = 1000e8;
        int256 maxAnswer = 1_000_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );

        AggregatorV3Interface(SEPOLIA_BTC_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetBelowMinPriceOnArbitrumOneForBtcUsdPriceFeedReverts() public {
        vm.chainId(42_161);

        // NOTE: setUp() already installed/initialized the ARBITRUM uptime feed and set it UP
        address ARBITRUM_ONE_BTC_USD_PRICEFEED = 0x6ce185860a4963106506C203335A2910413708e9;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);
        vm.etch(ARBITRUM_ONE_BTC_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(ARBITRUM_ONE_BTC_USD_PRICEFEED);

        int256 answer = 999e8;
        int256 minAnswer = 1000e8;
        int256 maxAnswer = 1_000_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );

        AggregatorV3Interface(ARBITRUM_ONE_BTC_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetAboveMaxPriceOnArbitrumOneForBtcUsdPriceFeedReverts() public {
        vm.chainId(42_161);

        address ARBITRUM_ONE_BTC_USD_PRICEFEED = 0x6ce185860a4963106506C203335A2910413708e9;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);
        vm.etch(ARBITRUM_ONE_BTC_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(ARBITRUM_ONE_BTC_USD_PRICEFEED);

        int256 answer = 1_000_001e8;
        int256 minAnswer = 1000e8;
        int256 maxAnswer = 1_000_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );

        AggregatorV3Interface(ARBITRUM_ONE_BTC_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }

    function testGetAboveMaxPriceOnZKSyncForBtcUsdPriceFeedReverts() public {
        vm.chainId(324);

        // Install zkSync sequencer uptime feed mock (required for chainId 324)
        MockSequencerUptimeFeed zkImpl = new MockSequencerUptimeFeed();
        vm.etch(ZKSYNC_MAINNET_UPTIME_FEED, address(zkImpl).code);
        MockSequencerUptimeFeed zkSequencer = MockSequencerUptimeFeed(ZKSYNC_MAINNET_UPTIME_FEED);
        zkSequencer.setStatus(0, block.timestamp - 2 hours);

        address ZK_SYNC_BTC_USD_PRICEFEED = 0x4Cba285c15e3B540C474A114a7b135193e4f1EA6;

        MockV3Aggregator impl = new MockV3Aggregator(8, 0);
        vm.etch(ZK_SYNC_BTC_USD_PRICEFEED, address(impl).code);

        MockV3Aggregator feed = MockV3Aggregator(ZK_SYNC_BTC_USD_PRICEFEED);

        int256 answer = 1_000_001e8;
        int256 minAnswer = 1000e8;
        int256 maxAnswer = 1_000_000e8;

        feed.updateAnswer(answer);

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__PriceOutOfBounds.selector, answer, minAnswer, maxAnswer)
        );

        AggregatorV3Interface(ZK_SYNC_BTC_USD_PRICEFEED).staleCheckLatestRoundData(maxPriceAge);
    }
    ///////////////
    // Getters  ///
    ///////////////

    function testGetTimeOut() public view {
        uint256 expectedTimeOut = 3 hours;
        assertEq(OracleLib.getTimeOut(AggregatorV3Interface(address(aggregator))), expectedTimeOut);
    }

    function testGetGracePeriod() public view {
        uint256 expectedGracePeriod = 1 hours;
        assertEq(OracleLib.getGracePeriod(AggregatorV3Interface(address(aggregator))), expectedGracePeriod);
    }
}
