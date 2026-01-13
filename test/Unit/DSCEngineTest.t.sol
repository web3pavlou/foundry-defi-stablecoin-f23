//SPDX-License-Identifier:MIT

pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { DSCEngine } from "../../src/DSCEngine.sol";
import { DeployDSC } from "../../script/DeployDSC.s.sol";
import { HelperConfig } from "../../script/HelperConfig.s.sol";
import { DWebThreePavlouStableCoin } from "../../src/DWebThreePavlouStableCoin.sol";
import { OracleLib } from "../../src/Libraries/OracleLib.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { ERC20MintableBurnableDecimals } from "../Mocks/ERC20MintableBurnableDecimals.sol";
import { MockV3Aggregator } from "../Mocks/MockV3Aggregator.sol";
import { MockFailedTransfer } from "../Mocks/MockFailedTransfer.sol";
import { MockDex } from "../Mocks/MockDex.sol";
import { MockFailedTransferFrom } from "../Mocks/MockFailedTransferFrom.sol";
import { MockFailedMintDSC } from "../Mocks/MockFailedMintDsc.sol";
import { MockMoreDebtDSC } from "../Mocks/MockMoreDebtDSC.sol";
import { MockFlashLiquidator } from "../Mocks/MockFlashLiquidator.sol";
import { MockFlashBorrower } from "../Mocks/MockFlashBorrower.sol";
import { MockBadFlashBorrower } from "../Mocks/MockBadFlashBorrower.sol";
import { MockBorrowerReverts } from "../Mocks/MockBorrowerReverts.sol";
import { MockFlashBorrowerRejectsWrongToken } from "../Mocks/MockFlashBorrowerRejectsWrongToken.sol";
import { MockFlashBorrowerLiesAboutTheAmount } from "../Mocks/MockFlashBorrowerLiesAboutTheAmount.sol";
import { MockFlashBorrowerLiesAboutTheFee } from "../Mocks/MockFlashBorrowerLiesAboutTheFee.sol";
import { IWETH } from "./Interfaces/IWETH.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { FlashMintDWebThreePavlou } from "../../src/FlashMintDWebThreePavlou.sol";

contract DSCEngineTest is Test {
    ////////////
    // errors //
    ////////////
    error OwnableUnauthorizedAccount(address caller);

    DeployDSC deployer;
    DWebThreePavlouStableCoin public dsc;
    DSCEngine public dsce;
    HelperConfig public helperConfig;
    FlashMintDWebThreePavlou public flashMinter;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;
    uint256 wethMaxPriceAge;
    uint256 wbtcMaxPriceAge;

    uint256 wethDecimals;
    uint256 wbtcDecimals;
    uint256 feedDecimals;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    address user = address(1);
    address exploiter = address(2);

    //Liquidation
    address liquidator = makeAddr("liquidator");
    uint256 collateralToCover = 20 ether;

    address public constant WBTC_WHALE = 0xB8Dc6B63746519F64bB7f7007DBfb86A0eB04479;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    // liquidation constants
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public constant LIQUIDATION_PRECISION = 100;
    uint256 public constant LIQUIDATION_BONUS = 10;
    // flashMint constants
    uint256 public constant MAX_FLASH_MINT_AMOUNT = 1_000_000e18;
    uint256 private constant FLASH_LOAN_AMOUNT = 1000e18;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CollateralTokenAdded(address indexed token, address indexed priceFeed, uint8 tokenDecimals, uint8 feedDecimals);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event DscMinted(address indexed user, uint256 amount);
    event DscBurned(address indexed onBehalfOf, address indexed dscFrom, uint256 amount, bool wasFlashRepayment);
    event CollateralDeposited(address indexed user, address indexed weth, uint256 indexed STARTING_USER_BALANCE);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount);
    event Liquidation(address indexed liquidator, address indexed user, address indexed collateral, uint256 debtBurned, uint256 collateralSeized);

    event FlashMinterDeployed(address engine, address token);

    event FlashLoanExecuted(address indexed initiator, address indexed receiver, address indexed token, uint256 amount, uint256 fee, address feeRecipient);

    event FlashMinterUpdated(address indexed newFlashMinter);

    event FlashDebtIncreased(address indexed borrower, uint256 amount);
    event FlashDebtDecreased(address indexed borrower, uint256 amount);

    event MinPositionValueUsdChanged(uint256 indexed newMinPositionValueUsd);
    event MinDebtThresholdUpdated(address indexed token, uint256 indexed newMinDebtThresholdUsd);
    event FlashFeeBpsUpdated(uint256 oldFlashFeeBps, uint256 newFlashFeeBps);
    event MaxPriceAgeUpdated(address indexed token, uint256 maxPriceAge);

    function setUp() public {
        deployer = new DeployDSC();

        (dsc, dsce, helperConfig, flashMinter) = deployer.run();

        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey, wethMaxPriceAge, wbtcMaxPriceAge) = helperConfig.activeNetworkConfig();

        if (block.chainid == 31_337) {
            // Local Anvil
            vm.deal(user, amountCollateral);

            ERC20MintableBurnableDecimals(weth).mint(user, amountCollateral);
            ERC20MintableBurnableDecimals(wbtc).mint(user, amountCollateral);
            ERC20MintableBurnableDecimals(weth).mint(exploiter, amountCollateral);

            wethDecimals = ERC20MintableBurnableDecimals(weth).decimals();
            wbtcDecimals = ERC20MintableBurnableDecimals(wbtc).decimals();
            feedDecimals = helperConfig.FEED_DECIMALS();
        } else {
            // Sepolia
            weth = 0xdd13E55209Fd76AfE204dBda4007C227904f0a81; // WETH9 on Sepolia
            // wbtc = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063; // Testnet WBTC

            // give user some ETH to wrap into WETH
            vm.deal(user, STARTING_USER_BALANCE);

            // wrap ETH -> WETH
            vm.startPrank(user);
            //declare a minimal interface like this in src/Interfaces/IWeth.sol
            IWETH(weth).deposit{ value: amountCollateral }();
            vm.stopPrank();

            // // fund user with WBTC by impersonating a whale
            // vm.startPrank(WBTC_WHALE);
            // IERC20(wbtc).transfer(user, amountCollateral);
            // vm.stopPrank();
        }
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testConstructorEmitsCollateralTokenAdded() public {
        delete tokenAddresses;
        delete priceFeedAddresses;

        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);

        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        tokenAddresses[0] = weth;
        tokenAddresses[1] = wbtc;

        priceFeedAddresses[0] = ethUsdPriceFeed;
        priceFeedAddresses[1] = btcUsdPriceFeed;

        uint8 wethDec = ERC20MintableBurnableDecimals(weth).decimals();
        uint8 wbtcDec = ERC20MintableBurnableDecimals(wbtc).decimals();

        uint8 ethFeedDec = MockV3Aggregator(ethUsdPriceFeed).decimals();
        uint8 btcFeedDec = MockV3Aggregator(btcUsdPriceFeed).decimals();

        // 1) Ownable emits first
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(address(0), address(this));

        // 2) then your constructor emits CollateralTokenAdded twice
        vm.expectEmit(true, true, false, true);
        emit CollateralTokenAdded(weth, ethUsdPriceFeed, wethDec, ethFeedDec);

        vm.expectEmit(true, true, false, true);
        emit CollateralTokenAdded(wbtc, btcUsdPriceFeed, wbtcDec, btcFeedDec);

        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc), address(this));
    }

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);

        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc), vm.addr(deployerKey));
    }

    function testRevertsIfCollateralTokenAlreadyExists() public {
        delete tokenAddresses;
        delete priceFeedAddresses;

        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);

        tokenAddresses.push(weth);
        priceFeedAddresses.push(weth);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__CollateralTokenAlreadyExists.selector, weth));

        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc), vm.addr(deployerKey));
    }

    function testRevertsIfCollateralTokenIsNotContract() public {
        delete tokenAddresses;
        delete priceFeedAddresses;

        address notAContract = makeAddr("notAContract");

        tokenAddresses.push(notAContract);
        priceFeedAddresses.push(ethUsdPriceFeed);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__InvalidCollateralToken.selector, notAContract));

        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc), vm.addr(deployerKey));
    }

    function testRevertsIfPriceFeedIsNotCorrect() public {
        delete tokenAddresses;
        delete priceFeedAddresses;

        address notAContractFeed = makeAddr("notAContractFeed");

        tokenAddresses.push(weth);
        priceFeedAddresses.push(notAContractFeed);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__InvalidPriceFeed.selector, notAContractFeed));

        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc), vm.addr(deployerKey));
    }

    function testRevertsIfInvalidEoaDsc() public {
        delete tokenAddresses;
        delete priceFeedAddresses;

        address notDscContract = makeAddr("notDscContract");

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__InvalidDsc.selector, notDscContract));

        new DSCEngine(tokenAddresses, priceFeedAddresses, notDscContract, vm.addr(deployerKey));
    }

    function testRevertsIfInvalidZeroAddressDsc() public {
        delete tokenAddresses;
        delete priceFeedAddresses;

        address invalidDscAddress = address(0);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__InvalidDsc.selector, invalidDscAddress));

        new DSCEngine(tokenAddresses, priceFeedAddresses, invalidDscAddress, vm.addr(deployerKey));
    }

    function testFlashLoanRevertsIfFlashMinterNotAuthorizedToMint() public {
        if (block.chainid != 31_337) return;

        delete tokenAddresses;
        delete priceFeedAddresses;

        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        DWebThreePavlouStableCoin localDsc = new DWebThreePavlouStableCoin(address(this));
        DSCEngine fresh = new DSCEngine(tokenAddresses, priceFeedAddresses, address(localDsc), address(this));
        FlashMintDWebThreePavlou fm = new FlashMintDWebThreePavlou(address(fresh), address(localDsc));

        // seed *fresh* so maxFlashLoan() > 0
        ERC20MintableBurnableDecimals(weth).mint(user, amountCollateral);

        vm.startPrank(user);
        IERC20(weth).approve(address(fresh), amountCollateral);
        fresh.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        // we do NOT call fresh.setFlashMinter(address(fm)),
        // so localDsc.minter is still 0x0 => mint must revert

        MockFlashBorrower borrower = new MockFlashBorrower();

        vm.expectRevert(DWebThreePavlouStableCoin.DWebThreePavlouSC__NotAuthorized.selector);
        fm.flashLoan(IERC3156FlashBorrower(address(borrower)), address(localDsc), 1e18, hex"");
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE
    //////////////////////////////////////////////////////////////*/

    function testGetUsdValue() public view {
        // get current ETH/USD price from mock
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();

        // pick an arbitrary ETH amount to test
        uint256 ethAmount = 15e18; // 15 ETH

        uint8 decimals = MockV3Aggregator(ethUsdPriceFeed).decimals();
        uint256 priceWithDecimals = (uint256(price) * dsce.getPrecision()) / (dsce.getBaseTen() ** decimals);

        uint256 expectedUsd = (priceWithDecimals * ethAmount) / dsce.getPrecision();

        // query DSCEngine for actual USD value
        uint256 usdValue = dsce.getUsdValue(weth, ethAmount);

        // assert equality
        assertEq(usdValue, expectedUsd);
    }

    function testRevertsGetUsdValueWithZeroTokenAddress() public {
        // pick an arbitrary ETH amount to test
        uint256 ethAmount = 15e18; // 15 ETH

        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        // query DSCEngine for actual USD value
        dsce.getUsdValue(address(0), ethAmount);
    }

    function testGetUsdValueWethHardcoded() public view {
        uint256 ethAmount = 15 * 10 ** wethDecimals; // 15 ETH * $2000/ETH = $30,000
        uint256 expectedUsd = 30_000 ether;
        uint256 usdValue = dsce.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    function testGetUsdValueWbtcHardcoded() public view {
        uint256 btcAmount = 15 * 10 ** wbtcDecimals;
        // 15 BTC * $1000/BTC = $15,000
        uint256 expectedUsd = 15_000 ether;
        uint256 usdValue = dsce.getUsdValue(wbtc, btcAmount);
        assertEq(usdValue, expectedUsd);
    }

    function testFeedDecimalsAreNonZeroForWeth() public {
        feedDecimals = dsce.getFeedDecimals(weth);
        assertTrue(feedDecimals > 0);
    }

    function testTokenDecimalsAreNonZeroForWeth() public view {
        uint8 tokenDecimals = dsce.getTokenDecimals(weth);
        assertTrue(tokenDecimals > 0);
    }

    function testGetTokenAmountFromUsd() public {
        // set feed addresses for this test
        priceFeedAddresses = [ethUsdPriceFeed];

        // get current ETH/USD price from mock or real feed
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();

        //pick an arbitrary USD amount to test
        uint256 usdAmount = 100 ether;

        uint8 feedDec = MockV3Aggregator(ethUsdPriceFeed).decimals();
        uint8 tokenDec = dsce.getTokenDecimals(weth); // or IERC20Metadata(weth).decimals() in tests

        uint256 normalizedPrice = (uint256(price) * dsce.getPrecision()) / (dsce.getBaseTen() ** feedDec);

        uint256 expectedWeth = Math.mulDiv(usdAmount, dsce.getBaseTen() ** tokenDec, normalizedPrice, Math.Rounding.Ceil);

        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    function testRevertsGetTokenAmountFromUsdWithZeroTokenAddress() public {
        //pick an arbitrary USD amount to test
        uint256 usdAmount = 100 ether;

        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        // query DSCEngine for actual USD value
        dsce.getTokenAmountFromUsd(address(0), usdAmount);
    }

    function testGetWethTokenAmountFromUsdHardcoded() public view {
        // If we want $10,000 of WETH @ $2000/WETH, that would be 5 WETH
        uint256 expectedWeth = 5 * 10 ** wethDecimals;
        uint256 amountWeth = dsce.getTokenAmountFromUsd(weth, 10_000 ether);
        assertEq(amountWeth, expectedWeth);
    }

    function testGetWbtcTokenAmountFromUsdHardocoded() public view {
        // If we want $10,000 of WBTC @ $1000/WBTC, that would be 10 WBTC
        uint256 expectedWbtc = 10 * 10 ** wbtcDecimals;
        uint256 amountWbtc = dsce.getTokenAmountFromUsd(wbtc, 10_000 ether);
        assertEq(amountWbtc, expectedWbtc);
    }

    function testCantExploitTokenDecimals() public {
        // Set initial prices for WETH and WBTC.

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(2000 * dsce.getBaseTen() ** feedDecimals)); // $2,000
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(int256(30_000 * dsce.getBaseTen() ** feedDecimals)); // $30,000

        // User deposits 1 WETH and mints maximum DSC allowed by liquidation threshold.
        vm.startPrank(user);
        uint256 amountWethDeposited = 1 * dsce.getBaseTen() ** wethDecimals; // 1 WETH
        uint256 expectedValueWeth = 2000 ether; // $2,000
        uint256 amountDscFromWeth = (expectedValueWeth * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountWethDeposited);
        dsce.depositCollateralAndMintDsc(weth, amountWethDeposited, amountDscFromWeth);
        assertEq(dsc.balanceOf(user), amountDscFromWeth);
        vm.stopPrank();

        // Verify WETH valuation is consistent.
        //2000.000000000000000000
        uint256 valueWeth = dsce.getUsdValue(weth, amountWethDeposited);
        assertEq(valueWeth, expectedValueWeth);

        // Reciprocal check: converting USD back to token should yield original amount.
        uint256 amountWeth = dsce.getTokenAmountFromUsd(weth, expectedValueWeth);
        assertEq(amountWeth, amountWethDeposited);

        // User deposits 1 WBTC and mints corresponding DSC.
        vm.startPrank(user);
        uint256 amountWbtcDeposited = 1 * dsce.getBaseTen() ** wbtcDecimals; // 1 WBTC
        // This was the flaw WBTC has 8 decimals, so naive calculations can misprice it. Here we scale with protocol
        // precision.
        uint256 expectedValueWbtc = 30_000 * dsce.getPrecision(); // that used to be( $0.000003 != $30,000)
        uint256 amountDscFromWbtc = (expectedValueWbtc * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        ERC20MintableBurnableDecimals(wbtc).approve(address(dsce), amountWbtcDeposited);
        dsce.depositCollateralAndMintDsc(wbtc, amountWbtcDeposited, amountDscFromWbtc);
        // Confirm user's total DSC balance matches sum of WETH and WBTC borrowings.
        assertEq(dsc.balanceOf(user), amountDscFromWbtc + amountDscFromWeth);
        vm.stopPrank();

        // The user's 1 WBTC is worth $30000.000000000000000000 as expected
        uint256 valueWbtc = dsce.getUsdValue(wbtc, amountWbtcDeposited);
        console.log("value of wbtc is:", valueWbtc);
        assertEq(valueWbtc, expectedValueWbtc);

        // Reciprocal check for WBTC as well.
        uint256 amountWbtc = dsce.getTokenAmountFromUsd(wbtc, expectedValueWbtc);
        assertEq(amountWbtc, amountWbtcDeposited);

        // Price drop: WBTC falls slightly, making the user eligible for liquidation.
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(int256(29_999 * dsce.getBaseTen() ** feedDecimals)); // $29,999
        assertTrue(dsce.getHealthFactor(user) < MIN_HEALTH_FACTOR);

        // The exploiter liquidates the user's WBTC,
        // The amount is matching now the price drop,
        // After this, the exploiter  doesn't end up with more WBTC than they should,
        // The exploiter paid 16000.000000000000000000 - 15999.000351100000000000 = 0.9996489
        // which is the exact price drop
        vm.startPrank(exploiter);
        // fetch the actual DSC debt of the user
        (uint256 totalDscMinted,) = dsce.getAccountInformation(user);
        uint256 userDebt = dsc.balanceOf(user);

        console.log("user's debt before liquidation:", userDebt);
        uint256 debtToPay = (totalDscMinted * LIQUIDATION_PRECISION) / (LIQUIDATION_PRECISION + LIQUIDATION_BONUS);
        // Ensure exploiter has enough DSC to perform the liquidation
        deal(address(dsc), exploiter, 20_000 ether);

        dsc.approve(address(dsce), debtToPay);
        dsce.liquidate(wbtc, user, debtToPay);
        vm.stopPrank();
        uint256 newUserDebt;
        // Capture updated user debt after liquidation.
        (, newUserDebt) = dsce.getAccountInformation(user);
        console.log("user's debt after liquidation:", newUserDebt);

        // Assertions: ensure the decimal exploit is mitigated.

        // Exploiter should not end up with more WBTC than they should
        uint256 exploiterWbtcBalance = ERC20MintableBurnableDecimals(wbtc).balanceOf(exploiter);
        uint256 userWbtcRemaining = dsce.getCollateralBalanceOfUser(user, wbtc);

        // Exploiter should receive some WBTC, but not the full collateral due to proper capping.
        assertLt(exploiterWbtcBalance, amountWbtcDeposited, "Exploit succeeded: exploiter took full collateral");
        assertGt(exploiterWbtcBalance, 0, "Liquidation failed: exploiter got nothing");

        // User retains remaining WBTC; no full-drain occurs.
        assertGt(userWbtcRemaining, 0, "User lost all collateral due to decimal exploit");

        // Health factor should improve after liquidation (system stable again)
        uint256 hfAfter = dsce.getHealthFactor(user);
        console.log("heAfter is:", hfAfter);
        assertGt(hfAfter, MIN_HEALTH_FACTOR, "Health factor did not recover");
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testSucceedsWithWbtcAsCollateral() public {
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, false, address(dsce));
        emit CollateralDeposited(user, wbtc, AMOUNT_COLLATERAL);

        dsce.depositCollateral(wbtc, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 userCollateral = dsce.getCollateralBalanceOfUser(user, wbtc);
        assertEq(userCollateral, AMOUNT_COLLATERAL, "WBTC collateral not recorded correctly");
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20MintableBurnableDecimals randomToken = new ERC20MintableBurnableDecimals("RAN", "RAN", 4);
        ERC20MintableBurnableDecimals(randomToken).mint(user, amountCollateral);
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(randomToken), 100);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);
        uint256 expectedDscMinted = 0;
        uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositedAmount);
    }

    function testCanDepositCollateralAndEmitsAnEvent() public {
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, false, address(dsce));
        emit CollateralDeposited(user, weth, STARTING_USER_BALANCE);

        dsce.depositCollateral(weth, STARTING_USER_BALANCE);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    DEPOSIT COLLATERAL AND MINT DSC
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        //  Get the ETH/USD price and decimals from the mock feed
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint8 decimals = MockV3Aggregator(ethUsdPriceFeed).decimals();

        //  Calculate how much DSC we’d try to mint (equal to full collateral value)
        uint256 usdValueOfCollateral = (uint256(price) * dsce.getPrecision()) / (dsce.getBaseTen() ** decimals);
        amountToMint = (usdValueOfCollateral * amountCollateral) / dsce.getPrecision();

        //  Approve collateral transfer
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);

        //  Compute expected health factor after minting
        uint256 collateralUsd = dsce.getUsdValue(weth, amountCollateral);
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(amountToMint, collateralUsd);

        //  Expect revert with correct selector & argument
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));

        //  Try to deposit + mint (should revert)
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintDsc() {
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintDsc {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    /*//////////////////////////////////////////////////////////////
                             MINT DSC
    //////////////////////////////////////////////////////////////*/

    function testRevertsifMintFails() public {
        address owner = makeAddr("owner");

        // Deploy mock DSC with owner
        vm.prank(owner);
        MockFailedMintDSC mockFailedMintDSC = new MockFailedMintDSC(owner);

        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];

        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockFailedMintDSC), vm.addr(deployerKey));

        // Transfer DSC ownership to engine
        vm.prank(owner);
        mockFailedMintDSC.transferOwnership(address(mockDsce));

        //user approves DSCEngine
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(mockDsce), amountCollateral);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(user);
        dsce.mintDsc(amountToMint);

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    function testMintsDscAndEmitsAnEvent() public depositedCollateral {
        vm.startPrank(user);

        vm.expectEmit(true, false, false, true, address(dsce));
        emit DscMinted(user, amountToMint);
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testMintDscSucceedsWhenCollateralAboveMinPositionValue() public {
        uint256 minPosition = dsce.getMinPositionValueUsd();

        vm.startPrank(user);

        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);

        uint256 collateralUsd = dsce.getAccountCollateralValue(user);
        assertGe(collateralUsd, minPosition);

        // Mint a safe amount so health factor stays > 1
        // HF = (collateralUsd * 0.5) / minted, so minted <= collateralUsd/2 is safe.
        amountToMint = collateralUsd / 4;
        dsce.mintDsc(amountToMint);

        vm.stopPrank();

        assertEq(dsc.balanceOf(user), amountToMint);
        (uint256 minted,) = dsce.getAccountInformation(user);
        assertEq(minted, amountToMint);

        assertGe(dsce.getHealthFactor(user), MIN_HEALTH_FACTOR);
    }

    function testMintDscRevertsIfCollateralStillBelowMinPositionAfterDeposit() public {
        uint256 minPosition = dsce.getMinPositionValueUsd();
        uint256 tiny = 1; // 1 wei of WETH (guaranteed to be << $250)

        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), tiny);
        dsce.depositCollateral(weth, tiny);

        uint256 collateralUsd = dsce.getAccountCollateralValue(user);
        assertLt(collateralUsd, minPosition);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BelowMinPositionValue.selector, collateralUsd, minPosition));
        dsce.mintDsc(1e18);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        REDEEM COLLATERAL
    //////////////////////////////////////////////////////////////*/
    function testRevertsIfTransferFromFails() public {
        address owner = msg.sender;
        vm.prank(owner);

        MockFailedTransferFrom mockCollateralToken = new MockFailedTransferFrom(owner);

        tokenAddresses = [address(mockCollateralToken)];
        priceFeedAddresses = [ethUsdPriceFeed];

        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc), vm.addr(deployerKey));

        mockCollateralToken.mint(user, amountCollateral);

        vm.startPrank(user);
        ERC20MintableBurnableDecimals(address(mockCollateralToken)).approve(address(mockDsce), amountCollateral);

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(mockCollateralToken)));
        mockDsce.depositCollateral(address(mockCollateralToken), amountCollateral);

        vm.stopPrank();
    }

    function testRevertsRedeemZeroCollateral() public {
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        uint256 userBalanceBeforeRedeem = dsce.getCollateralBalanceOfUser(user, weth);
        assertEq(userBalanceBeforeRedeem, amountCollateral);
        dsce.redeemCollateral(weth, amountCollateral);
        uint256 userBalanceAfterRedeem = dsce.getCollateralBalanceOfUser(user, weth);
        assertEq(userBalanceAfterRedeem, 0);
        vm.stopPrank();
    }

    function testRevertsRedeemCollateralIfHealthFactorIsBroken() public {
        // Arrange
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint8 decimals = MockV3Aggregator(ethUsdPriceFeed).decimals();

        uint256 usdValuePerCollateralUnit = (uint256(price) * dsce.getPrecision()) / (dsce.getBaseTen() ** decimals);
        amountToMint = (usdValuePerCollateralUnit * amountCollateral) / dsce.getPrecision() / 2; // safe mint

        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);

        // Simulate price drop (collateral halves in USD)
        int256 lowerPrice = price / 2;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(lowerPrice);

        // Remaining collateral *after redeeming half*
        uint256 remainingCollateral = amountCollateral - (amountCollateral / 2);
        uint256 collateralValueAfterDrop = dsce.getUsdValue(weth, remainingCollateral);
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(amountToMint, collateralValueAfterDrop);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.redeemCollateral(weth, amountCollateral / 2);

        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(dsce));
        emit CollateralRedeemed(user, user, address(weth), amountCollateral);
        vm.startPrank(user);

        dsce.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
        bytes32 expectedSig = keccak256("CollateralRedeemed(address,address,address,uint256)");
        console.logBytes32(expectedSig);
    }

    /*//////////////////////////////////////////////////////////////
                      REDEEM COLLATERAL FOR DSC
    //////////////////////////////////////////////////////////////*/

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintDsc {
        vm.startPrank(user);
        dsc.approve(address(dsce), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testMustBeAValidTokenAddress() public depositedCollateralAndMintDsc {
        vm.startPrank(user);
        dsc.approve(address(dsce), amountCollateral);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.redeemCollateralForDsc(address(1), amountCollateral, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        dsc.approve(address(dsce), amountToMint);

        dsce.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           HEALTH FACTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dsce.getHealthFactor(user);
        assertEq(expectedHealthFactor, healthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        //we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dsce.getHealthFactor(user);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    /*//////////////////////////////////////////////////////////////
                         BURN DSC
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfBurntAmountIsZero() public {
        vm.startPrank(user);
        dsc.approve(address(dsce), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function userSuccesfullyBurnsTheirCollateral() public depositedCollateralAndMintDsc {
        vm.startPrank(user);
        dsc.approve(address(dsce), amountToMint);
        dsce.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalanceAfterBurns = dsc.balanceOf(user);
        assertEq(userBalanceAfterBurns, 0);
    }

    function testCantBurnMoreThanUserHas() public {
        vm.startPrank(user);
        vm.expectRevert();
        dsce.burnDsc(1);
        vm.stopPrank();
    }

    function testBurnDscEmitsEventNonFlash() public {
        uint256 burnAmount = 50e18;

        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        dsce.mintDsc(amountToMint);

        dsc.approve(address(dsce), burnAmount);

        vm.expectEmit(true, true, false, true, address(dsce));
        emit DscBurned(user, user, burnAmount, false);

        dsce.burnDsc(burnAmount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           LIQUIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertsWhenHealthFactorWorsensOnLiquidation() public {
        address owner = makeAddr("owner");

        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed, owner);

        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];

        //Arrange-owner
        vm.startPrank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc), address(this));
        mockDsc.transferOwnership(address(mockDsce));
        vm.stopPrank();
        //Arrange-user
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(mockDsce), amountCollateral);
        mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        //Arrange- Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        uint256 debtToCover = 1 ether;

        mockDsc.approve(address(mockDsce), debtToCover);

        ERC20MintableBurnableDecimals(weth).approve(address(mockDsce), collateralToCover);
        mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);

        // Act
        int256 ethUsdUpdatePrice = 18e8;
        console.log("Before drop:", mockDsce.getHealthFactor(user));
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatePrice);
        console.log("After drop:", mockDsce.getHealthFactor(user));

        // Act + Assert (as liquidator)
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockDsce.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateIfHealthFactorOk() public {
        uint256 debtToCover = 1 ether;

        // --- Give liquidator WETH depending on environment ---
        if (block.chainid == 31_337) {
            //  Local Anvil environment
            ERC20MintableBurnableDecimals(weth).mint(liquidator, collateralToCover);
        } else {
            //  Sepolia (or other live/forked testnet)
            // Fund liquidator with ETH and wrap it into WETH
            vm.deal(liquidator, collateralToCover + 0.1 ether);

            vm.startPrank(liquidator);
            IWETH(weth).deposit{ value: collateralToCover }(); // Wrap ETH → WETH
            vm.stopPrank();
        }

        // --- Liquidator deposits collateral and mints DSC ---
        vm.startPrank(liquidator);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        vm.stopPrank();

        // --- Try to liquidate a healthy position (should revert) ---
        vm.startPrank(liquidator);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    function testCriticalHealthFactor() public {
        // 1. Owner sets a $5 dust-threshold for WETH
        vm.prank(dsce.owner());
        dsce.setMinDebtThreshold(weth, 5e18);

        // 2. Oracle prices BEFORE crash
        // Need >= $250 total to pass minPositionValueUsd at mint time.
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(105e8));
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(int256(150e8));

        // 3. Victim opens position and mints
        uint256 depositWeth = 1 ether; // 1 WETH
        uint256 depositWbtc = 10 ** uint256(wbtcDecimals); // 1 WBTC (1e8 if 8 decimals)

        vm.startPrank(user);

        ERC20MintableBurnableDecimals(weth).approve(address(dsce), depositWeth);
        dsce.depositCollateral(weth, depositWeth);

        ERC20MintableBurnableDecimals(wbtc).approve(address(dsce), depositWbtc);
        dsce.depositCollateralAndMintDsc(wbtc, depositWbtc, amountToMint);

        vm.stopPrank();

        // sanity: mint succeeded & user is NOT liquidatable pre-crash
        assertGe(dsce.getHealthFactor(user), MIN_HEALTH_FACTOR);

        // 4. Crash BTC to $1 (NOT 0, OracleLib rejects 0)
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(int256(1e8)); // $1

        // sanity: now must be liquidatable
        uint256 hf = dsce.getHealthFactor(user);
        assertLt(hf, MIN_HEALTH_FACTOR, "User should be liquidatable after crash");

        // 5. Liquidator
        uint256 liqColl = 10 ether;
        ERC20MintableBurnableDecimals(weth).mint(liquidator, liqColl);

        vm.startPrank(liquidator);

        ERC20MintableBurnableDecimals(weth).approve(address(dsce), liqColl);
        dsce.depositCollateralAndMintDsc(weth, liqColl, amountToMint);

        dsc.approve(address(dsce), amountToMint);

        // 6. Liquidate
        dsce.liquidate(weth, user, amountToMint);

        vm.stopPrank();

        // 7. Assertions
        (uint256 userDebtAfter,) = dsce.getAccountInformation(user);
        assertEq(userDebtAfter, 0, "User debt should be wiped");

        assertEq(dsce.getCollateralBalanceOfUser(user, weth), 0, "User must lose their remaining WETH");

        uint256 hfAfter = dsce.getHealthFactor(user);
        assertGt(hfAfter, MIN_HEALTH_FACTOR);
    }

    function testLiquidateEmitsEvents() public {
        if (block.chainid != 31_337) return;

        // Arrange
        uint256 userCollateral = 1 ether;
        uint256 userDebt = 1000e18;
        uint256 debtToCover = 100e18;

        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), userCollateral);
        dsce.depositCollateral(weth, userCollateral);
        dsce.mintDsc(userDebt);
        vm.stopPrank();

        // drop ETH price to make HF < 1
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1900e8);
        assertLt(dsce.getHealthFactor(user), MIN_HEALTH_FACTOR);

        //Arrange: liquidator has DSC to burn
        uint256 liqCollateral = 1 ether;
        ERC20MintableBurnableDecimals(weth).mint(liquidator, liqCollateral);

        vm.startPrank(liquidator);
        IERC20(weth).approve(address(dsce), liqCollateral);
        dsce.depositCollateral(weth, liqCollateral);
        dsce.mintDsc(500e18);

        dsc.approve(address(dsce), debtToCover);

        // compute expected seized collateral using the engine's own math
        uint256 base = dsce.getTokenAmountFromUsd(weth, debtToCover);
        uint256 bonus = (base * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 seize = base + bonus;

        // order of emits inside liquidation:
        // 1) CollateralRedeemed (from=user, to=liquidator)
        // 2) DscBurned (onBehalfOf=user, dscFrom=liquidator)  <-- requires the engine patch above
        // 3) Liquidation
        vm.expectEmit(true, true, true, true, address(dsce));
        emit CollateralRedeemed(user, liquidator, weth, seize);

        vm.expectEmit(true, true, false, true, address(dsce));
        emit DscBurned(user, liquidator, debtToCover, false);

        vm.expectEmit(true, true, true, true, address(dsce));
        emit Liquidation(liquidator, user, weth, debtToCover, seize);

        dsce.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    modifier liquidated() {
        //Arrange-user
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);

        ERC20MintableBurnableDecimals(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);

        // Act
        dsce.liquidate(weth, user, amountToMint);
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);

        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint) + (dsce.getTokenAmountFromUsd(weth, amountToMint) * dsce.getLiquidationBonus() / dsce.getLiquidationPrecision());
        console.log(expectedWeth, ":The expected weth amount");
        uint256 hardCodedExpected = 6_111_111_111_111_111_111;
        assertEq(liquidatorWethBalance, expectedWeth);
        assertEq(liquidatorWethBalance, hardCodedExpected);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, amountToMint) + (dsce.getTokenAmountFromUsd(weth, amountToMint) * dsce.getLiquidationBonus() / dsce.getLiquidationPrecision());

        uint256 usdAmountLiquidated = dsce.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = dsce.getUsdValue(weth, amountCollateral) - (usdAmountLiquidated);
        (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(user);
        uint256 hardCodedExpected = 70_000_000_000_000_000_002;
        console.log(userCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpected);
    }

    function testLiquidatorTakesOnUserDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = dsce.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dsce.getAccountInformation(user);
        console.log("user's debt after being liquidated(if there is none):", userDscMinted);
        assertEq(userDscMinted, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           MIN DEBT THRESHOLD
    //////////////////////////////////////////////////////////////*/

    function testPartialLiquidationRespectsMinDebtThreshold() public {
        uint256 minThresholdUsd = 5e18;

        address engineOwner = dsce.owner();

        vm.prank(engineOwner);
        dsce.setMinDebtThreshold(weth, minThresholdUsd);

        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral); // 10 ETH
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint); // mint 100 DSC
        vm.stopPrank();

        int256 ethUsdUpdatePrice = 18e8; // $18 -> user undercollateralized
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatePrice);

        ERC20Mock(weth).mint(liquidator, collateralToCover);
        vm.startPrank(liquidator);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint); // liquidator mints collateralToCover

        dsc.approve(address(dsce), amountToMint);

        uint256 debtToCover = 50e18; // partial liquidation attempt
        dsce.liquidate(weth, user, debtToCover);
        vm.stopPrank();

        // Assert: remaining user's collateral value in USD is >= minThresholdUsd
        (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(user);
        assertGe(userCollateralValueInUsd, minThresholdUsd);

        // If the code adjusted to leave the exact threshold, it should be very close (allow small rounding)
        uint256 tolerance = 1e12; // tiny USD tolerance (~0.000001 USD)
        if (userCollateralValueInUsd <= minThresholdUsd + 1e18) {
            // only check closeness if it's near the threshold
            assertApproxEqAbs(userCollateralValueInUsd, minThresholdUsd, tolerance);
        }
    }

    function testSetMinDebtThresholdEmitsEvent() public {
        address owner = dsce.owner();
        uint256 newThreshold = 50e18;

        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true, address(dsce));
        emit MinDebtThresholdUpdated(weth, newThreshold);

        dsce.setMinDebtThreshold(weth, newThreshold);
        vm.stopPrank();
    }

    function testPartialLiquidationRevertsBelowMinDebtThreshold() public {
        vm.prank(dsce.owner());
        dsce.setMinDebtThreshold(weth, 50e18);

        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        vm.startPrank(liquidator);

        uint256 debtToCover = 60e18;
        uint256 remainingDebt = amountToMint - debtToCover;

        ERC20MintableBurnableDecimals(weth).mint(liquidator, collateralToCover);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), debtToCover);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__RemainingDebtBelowMinThreshold.selector, remainingDebt, dsce.getMinDebtThreshold(weth)));
        dsce.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    function testPartialLiquidationAllowedAtExactMinDebtThreshold() public {
        // remainingDebt > 0 && remainingDebt < minDebtThreshold
        uint256 minDebtThreshold = 50e18;
        vm.prank(dsce.owner());
        dsce.setMinDebtThreshold(weth, minDebtThreshold);

        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        int256 ethUsdUpdatePrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatePrice);

        collateralToCover = 60 ether;
        ERC20MintableBurnableDecimals(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), minDebtThreshold); // we burn 50 DSC

        dsce.liquidate(weth, user, minDebtThreshold);
        vm.stopPrank();

        (uint256 userDebtAfter,) = dsce.getAccountInformation(user);
        assertEq(userDebtAfter, amountToMint - minDebtThreshold);
    }

    function testFullLiquidationAllowedWhenDebtBelowMinDebtThreshold() public {
        uint256 minDebtThreshold = 50e18;
        vm.prank(dsce.owner());
        dsce.setMinDebtThreshold(weth, minDebtThreshold);

        // USER: small debt 30 DSC (below threshold)
        amountToMint = 30e18;
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral); // 10 ETH
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Make user  undercollateralized
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(5e8); // 1 WETH = $5 → HF ≈ 0.83 < 1

        // LIQUIDATOR: airdrop a large DSC amount to liquidator in order not to hit ` DSCEngine__BelowMinPositionValue`
        // error
        uint256 liquidatorDscBalance = 1000e18;
        deal(address(dsc), liquidator, liquidatorDscBalance);
        vm.startPrank(liquidator);
        dsc.approve(address(dsce), type(uint256).max); // try to "over-cover"
        dsce.liquidate(weth, user, type(uint256).max); // clamps to 30e18 internally
        vm.stopPrank();

        (uint256 userDebtAfter,) = dsce.getAccountInformation(user);
        assertEq(userDebtAfter, 0); // full wipe is allowed even though 30 < minDebtThreshold(50)
    }

    function testPartialLiquidationRevertsWhenMinDebtThresholdIsZero() public {
        vm.prank(dsce.owner());
        dsce.setMinDebtThreshold(weth, 0);

        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        vm.startPrank(liquidator);

        uint256 debtToCover = 60e18;

        ERC20MintableBurnableDecimals(weth).mint(liquidator, collateralToCover);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), debtToCover);

        dsce.liquidate(weth, user, debtToCover);
        vm.stopPrank();

        (uint256 userDebtAfter,) = dsce.getAccountInformation(user);
        assertEq(userDebtAfter, amountToMint - debtToCover); // 40e18
    }

    function testSubsequentLiquidationsRevertsWhenItWouldCreateDust() public {
        uint256 minDebtThreshold = 50e18;
        vm.prank(dsce.owner());
        dsce.setMinDebtThreshold(weth, minDebtThreshold);

        // USER: open position with enough collateral at high price
        uint256 initialDebt = 100e18;
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral); // 10 WETH
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, initialDebt);
        vm.stopPrank();

        // Drop price so:
        //  - user is liquidatable (HF < 1)
        //  - but C/D is between 1.1x and 2x, so partial liq can improve HF
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(15e8); // 1 WETH = $15

        // Liquidator: give plenty of DSC via deal
        uint256 liquidatorDscBalance = 1000e18;
        deal(address(dsc), liquidator, liquidatorDscBalance);

        vm.startPrank(liquidator);
        dsc.approve(address(dsce), liquidatorDscBalance);

        //First liquidation: valid partial
        uint256 firstDebtToCover = 40e18;
        dsce.liquidate(weth, user, firstDebtToCover);

        (uint256 userDebtAfterFirst,) = dsce.getAccountInformation(user);
        assertEq(userDebtAfterFirst, 60e18); // 100 - 40

        //  Second liquidation: would create dust, should revert
        uint256 secondDebtToCover = 20e18;
        uint256 remainingDebt = userDebtAfterFirst - secondDebtToCover; // 40e18

        // Sanity check: 0 < remainingDebt < minDebtThreshold
        assertEq(remainingDebt, 40e18);
        assertLt(remainingDebt, minDebtThreshold);
        assertGt(remainingDebt, 0);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__RemainingDebtBelowMinThreshold.selector, remainingDebt, minDebtThreshold));
        dsce.liquidate(weth, user, secondDebtToCover);

        vm.stopPrank();
    }

    function testMinDebtThresholdIsPerCollateralToken() public {
        // Set threshold ONLY for WETH
        uint256 wethMinThreshold = 50e18;
        vm.prank(dsce.owner());
        dsce.setMinDebtThreshold(weth, wethMinThreshold);
        // WBTC threshold stays 0

        amountToMint = 100e18; // 100 DSC debt
        uint256 wbtcCollateral = 10 * (10 ** wbtcDecimals); // 10 WBTC

        // Pre-crash price: 40$
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(int256(40e8));

        vm.startPrank(user);
        ERC20MintableBurnableDecimals(wbtc).approve(address(dsce), wbtcCollateral);
        dsce.depositCollateralAndMintDsc(wbtc, wbtcCollateral, amountToMint);
        vm.stopPrank();

        // Crash to ≈ 11.1$
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(int256(111 * 1e7));

        // User is now liquidatable
        uint256 hfBefore = dsce.getHealthFactor(user);
        assertLt(hfBefore, MIN_HEALTH_FACTOR);

        // Liquidator gets DSC externally
        uint256 liquidatorDscBalance = 1000e18;
        deal(address(dsc), liquidator, liquidatorDscBalance);

        vm.startPrank(liquidator);
        dsc.approve(address(dsce), 60e18);

        // dust threshold is ONLY set for WETH, so this must NOT revert
        dsce.liquidate(wbtc, user, 60e18);
        vm.stopPrank();

        (uint256 userDebtAfter,) = dsce.getAccountInformation(user);

        // Some DSC was burned and debt is exactly 40
        assertEq(userDebtAfter, 40e18, "User should be left with 40 DSC debt");

        // HF strictly improved vs pre-liquidation, but does not need to be > 1
        uint256 hfAfter = dsce.getHealthFactor(user);
        assertGt(hfAfter, hfBefore);
    }

    function testLiquidationDebtIsCappedByBucketValue() public {
        // 1. Set up oracle prices for a healthy initial position
        //
        // Pre-crash:
        //   WETH = $800
        //   WBTC = $800
        // User will deposit 1 WETH + 1 WBTC and mint 700 DSC.
        // Total collateral = $1600
        // Threshold = 50% -> effective collateral = $800
        // HF_before = 800 / 700 ≈ 1.14 > 1 → OK.
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(800e8));
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(int256(800e8));

        amountToMint = 700e18;
        uint256 wethAmount = 1 ether;
        uint256 wbtcAmount = 1 * (10 ** wbtcDecimals);

        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), wethAmount);
        ERC20MintableBurnableDecimals(wbtc).approve(address(dsce), wbtcAmount);

        dsce.depositCollateral(weth, wethAmount);
        dsce.depositCollateralAndMintDsc(wbtc, wbtcAmount, amountToMint);
        vm.stopPrank();

        uint256 hfBeforePriceMove = dsce.getHealthFactor(user);
        assertGt(hfBeforePriceMove, MIN_HEALTH_FACTOR);

        // 2. Crash prices so the user becomes liquidatable,
        //    with WETH as the smaller bucket.
        //
        // Post-crash:
        //   WETH = $300
        //   WBTC = $700
        //   Total = $1000
        //   Threshold = 50% -> 500
        //   HF_afterCrash = 500 / 700 ≈ 0.714 < 1 → user is liquidatable.
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(300e8));
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(int256(700e8));

        uint256 hfAfterCrash = dsce.getHealthFactor(user);
        assertLt(hfAfterCrash, MIN_HEALTH_FACTOR);

        // Liquidator gets a lot of DSC and tries to burn "too much"
        uint256 liquidatorDscBalance = 1000e18;
        deal(address(dsc), liquidator, liquidatorDscBalance);

        vm.startPrank(liquidator);
        dsc.approve(address(dsce), liquidatorDscBalance);

        // Attempt to burn 1000 DSC from the WETH bucket alone.
        // The WETH bucket is only worth ~$300 after the crash, so
        // `actualDebtToBurn` must clamp to ≈ 300e18.
        uint256 debtToCover = 1000e18;
        dsce.liquidate(weth, user, debtToCover);
        vm.stopPrank();

        // Post-conditions

        (uint256 userDebtAfter,) = dsce.getAccountInformation(user);

        // Some debt was burned, but not all of it.
        assertGt(userDebtAfter, 0);
        assertLt(userDebtAfter, amountToMint);

        // Debt reduction should be approximately the WETH bucket value ($300).
        uint256 debtBurned = amountToMint - userDebtAfter;
        assertApproxEqAbs(debtBurned, 300e18, 1e15);

        // User's WETH should be fully seized (1 WETH -> 0)
        uint256 userWethAfter = dsce.getCollateralBalanceOfUser(user, weth);
        assertEq(userWethAfter, 0, "User WETH bucket should be fully seized");

        // Health factor must have strictly improved, even if still < 1
        uint256 hfFinal = dsce.getHealthFactor(user);
        assertGt(hfFinal, hfAfterCrash);
    }

    /*//////////////////////////////////////////////////////////////
                             BATCH-LIQUIDATE
    //////////////////////////////////////////////////////////////*/
    function testBatchLiquidateMultipleUsers() public {
        address alice = makeAddr("Alice");
        address bob = makeAddr("Bob");

        // Users setup

        vm.startPrank(alice);
        ERC20MintableBurnableDecimals(weth).mint(alice, amountCollateral);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        vm.startPrank(bob);
        ERC20MintableBurnableDecimals(weth).mint(bob, amountCollateral);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(18e8)); // crash WETH to $18

        vm.startPrank(liquidator);

        ERC20MintableBurnableDecimals(weth).mint(liquidator, amountCollateral * 10);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral * 10);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral * 10, amountToMint * 2); // enough DSC to cover both

        dsc.approve(address(dsce), amountToMint * 2);
        vm.stopPrank();

        // Prepare batch arrays

        address[] memory usersArr = new address[](2);
        usersArr[0] = alice;
        usersArr[1] = bob;

        uint256[] memory debtsArr = new uint256[](2);
        debtsArr[0] = amountToMint; // fully liquidate Alice
        debtsArr[1] = amountToMint; // fully liquidate Bob

        // Execute batchLiquidate as the liquidator

        vm.prank(liquidator);
        dsce.batchLiquidate(weth, usersArr, debtsArr);

        // Asserts

        (uint256 aliceDebtAfter,) = dsce.getAccountInformation(alice);
        (uint256 bobDebtAfter,) = dsce.getAccountInformation(bob);

        assertEq(aliceDebtAfter, 0, "Alice debt should be wiped");
        assertEq(bobDebtAfter, 0, "Bob debt should be wiped");
    }

    function testBatchLiquidateLengthMismatchReverts() public {
        address[] memory usersArr = new address[](1);
        usersArr[0] = user;

        uint256[] memory debtsArr = new uint256[](2);
        debtsArr[0] = amountToMint;
        debtsArr[1] = amountToMint;

        vm.expectRevert(DSCEngine.DSCEngine__BatchLengthMismatch.selector);
        dsce.batchLiquidate(weth, usersArr, debtsArr);
    }

    function testBatchLiquidateZeroLengthReverts() public {
        address[] memory usersArr = new address[](0);

        uint256[] memory debtsArr = new uint256[](0);

        vm.expectRevert(DSCEngine.DSCEngine__BatchEmpty.selector);
        dsce.batchLiquidate(weth, usersArr, debtsArr);
    }

    function testBatchLiquidateNeedsMoreThanZeroAmount() public {
        address alice = makeAddr("Alice");
        address bob = makeAddr("Bob");

        // Users setup

        vm.startPrank(alice);
        ERC20MintableBurnableDecimals(weth).mint(alice, amountCollateral);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        vm.startPrank(bob);
        ERC20MintableBurnableDecimals(weth).mint(bob, amountCollateral);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(18e8)); // crash WETH to $18

        // Liquidator setup

        vm.startPrank(liquidator);

        ERC20MintableBurnableDecimals(weth).mint(liquidator, amountCollateral * 10);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral * 10);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral * 10, amountToMint * 2); // enough DSC to cover both

        dsc.approve(address(dsce), amountToMint * 2);
        vm.stopPrank();

        //Prepare batch arrays

        address[] memory usersArr = new address[](2);
        usersArr[0] = alice;
        usersArr[1] = bob;

        uint256[] memory debtsArr = new uint256[](2);
        debtsArr[0] = 0; // try to liquidate zero amount
        debtsArr[1] = 0; //  same here

        // Execute batchLiquidate as the liquidator

        vm.prank(liquidator);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.batchLiquidate(weth, usersArr, debtsArr);
    }

    function testBatchLiquidateRevertsWhenTokenMismatch() public {
        ERC20MintableBurnableDecimals randomERC20Token = new ERC20MintableBurnableDecimals("RND", "RND", 18);

        address alice = makeAddr("Alice");
        address bob = makeAddr("Bob");

        // Users setup: both open identical positions

        vm.startPrank(alice);
        ERC20MintableBurnableDecimals(weth).mint(alice, amountCollateral);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        vm.startPrank(bob);
        ERC20MintableBurnableDecimals(weth).mint(bob, amountCollateral);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(18e8)); // crash WETH to $18

        //  Liquidator setup

        vm.startPrank(liquidator);
        // Give the liquidator a lot more collateral
        ERC20MintableBurnableDecimals(weth).mint(liquidator, amountCollateral * 10);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral * 10);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral * 10, amountToMint * 2); // enough DSC to cover both

        dsc.approve(address(dsce), amountToMint * 2);
        vm.stopPrank();

        //  Prepare batch arrays

        address[] memory usersArr = new address[](2);
        usersArr[0] = alice;
        usersArr[1] = bob;

        uint256[] memory debtsArr = new uint256[](2);
        debtsArr[0] = 0; // try to liquidate zero amount
        debtsArr[1] = 0; //  same here

        // Execute batchLiquidate as the liquidator

        vm.prank(liquidator);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.batchLiquidate(address(randomERC20Token), usersArr, debtsArr);
    }

    function testBatchLiquidateRevertsIfAnyUserNotLiquidatableAndIsAtomic() public {
        address alice = makeAddr("Alice");
        address carol = makeAddr("Carol");

        vm.startPrank(alice);
        ERC20MintableBurnableDecimals(weth).mint(alice, amountCollateral);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        vm.startPrank(carol);
        ERC20MintableBurnableDecimals(weth).mint(carol, amountCollateral);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint / 4);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(18e8));

        uint256 aliceDebtBefore;
        uint256 carolDebtBefore;
        (aliceDebtBefore,) = dsce.getAccountInformation(alice);
        (carolDebtBefore,) = dsce.getAccountInformation(carol);

        // liquidator setup

        uint256 liquidatorDscBalance = 1000e18;
        deal(address(dsc), liquidator, liquidatorDscBalance);
        vm.startPrank(liquidator);
        dsc.approve(address(dsce), liquidatorDscBalance);

        address[] memory usersArr = new address[](2);
        usersArr[0] = alice;
        usersArr[1] = carol;

        uint256[] memory debtsArr = new uint256[](2);
        debtsArr[0] = aliceDebtBefore;
        debtsArr[1] = carolDebtBefore;

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.batchLiquidate(weth, usersArr, debtsArr);
        vm.stopPrank();

        // state must be unchanged for both
        uint256 aliceDebtAfter;
        uint256 carolDebtAfter;
        (aliceDebtAfter,) = dsce.getAccountInformation(alice);
        (carolDebtAfter,) = dsce.getAccountInformation(carol);

        assertEq(aliceDebtAfter, aliceDebtBefore, "Alice should not be partially liquidated");
        assertEq(carolDebtAfter, carolDebtBefore, "Carol should not be touched");
    }

    function testBatchLiquidateRevertsIfUserHasNoDebtAndIsAtomic() public {
        address alice = makeAddr("Alice");
        address carol = makeAddr("Carol");

        vm.startPrank(alice);
        ERC20MintableBurnableDecimals(weth).mint(alice, amountCollateral);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        vm.startPrank(carol);
        ERC20MintableBurnableDecimals(weth).mint(carol, amountCollateral);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(18e8));

        uint256 aliceDebtBefore;
        uint256 carolDebtBefore;
        (aliceDebtBefore,) = dsce.getAccountInformation(alice);
        (carolDebtBefore,) = dsce.getAccountInformation(carol);
        assertEq(carolDebtBefore, 0);

        // liquidator setup

        uint256 liquidatorDscBalance = 1000e18;
        deal(address(dsc), liquidator, liquidatorDscBalance);
        vm.startPrank(liquidator);
        dsc.approve(address(dsce), liquidatorDscBalance);

        address[] memory usersArr = new address[](2);
        usersArr[0] = alice;
        usersArr[1] = carol;

        uint256[] memory debtsArr = new uint256[](2);
        debtsArr[0] = aliceDebtBefore;
        debtsArr[1] = 10e18; // any non-zero → will try to burn Bob's non-existent debt

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.batchLiquidate(weth, usersArr, debtsArr);
        vm.stopPrank();

        // state must be unchanged for both
        uint256 aliceDebtAfter;
        uint256 carolDebtAfter;
        (aliceDebtAfter,) = dsce.getAccountInformation(alice);
        (carolDebtAfter,) = dsce.getAccountInformation(carol);

        assertEq(aliceDebtAfter, aliceDebtBefore, "Alice state should be reverted");
        assertEq(carolDebtAfter, carolDebtBefore, "Carol state should be unchanged");
    }

    function testBatchLiquidateSameUserTwiceSplitsLiquidation() public {
        address alice = makeAddr("Alice");

        // Initial position: 10 WETH, 100 DSC debt
        vm.startPrank(alice);
        ERC20MintableBurnableDecimals(weth).mint(alice, amountCollateral);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, 100e18);
        vm.stopPrank();

        // Crash price to make Alice liquidatable
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(18e8));

        // Sanity: Alice must be liquidatable before batch
        uint256 hfBefore = dsce.getHealthFactor(alice);
        assertLt(hfBefore, MIN_HEALTH_FACTOR);

        // Liquidator setup
        uint256 liquidatorDscBalance = 1000e18;
        deal(address(dsc), liquidator, liquidatorDscBalance);
        vm.startPrank(liquidator);
        dsc.approve(address(dsce), liquidatorDscBalance);

        address[] memory usersArr = new address[](2);
        usersArr[0] = alice;
        usersArr[1] = alice;

        uint256[] memory debtsArr = new uint256[](2);
        debtsArr[0] = 20e18; // first partial burn keeps HF < 1
        debtsArr[1] = 80e18; // second finishes the position

        dsce.batchLiquidate(weth, usersArr, debtsArr);
        vm.stopPrank();

        (uint256 aliceDebtAfter,) = dsce.getAccountInformation(alice);
        assertEq(aliceDebtAfter, 0, "Alice's debt should be fully wiped across both iterations");

        uint256 hfAfter = dsce.getHealthFactor(alice);
        assertGt(hfAfter, hfBefore);
        assertEq(hfAfter, type(uint256).max); // since totalDscMinted == 0
    }

    function testBatchLiquidateSameUserTwiceDustOnSecondIterationRevertsAll() public {
        uint256 minDebtThreshold = 50e18;
        vm.prank(dsce.owner());
        dsce.setMinDebtThreshold(weth, minDebtThreshold);

        address alice = makeAddr("Alice");

        vm.startPrank(alice);
        ERC20MintableBurnableDecimals(weth).mint(alice, amountCollateral);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, 100e18);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(15e8)); // liquidatable

        (uint256 debtBefore,) = dsce.getAccountInformation(alice);

        uint256 liquidatorDscBalance = 1000e18;
        deal(address(dsc), liquidator, liquidatorDscBalance);
        vm.startPrank(liquidator);
        dsc.approve(address(dsce), liquidatorDscBalance);

        address[] memory usersArr = new address[](2);
        usersArr[0] = alice;
        usersArr[1] = alice;

        uint256[] memory debtsArr = new uint256[](2);
        debtsArr[0] = 40e18; // would leave 60
        debtsArr[1] = 20e18; // on the updated state would leave 40 -> < minThreshold -> revert

        uint256 remainingAfterSecond = debtBefore - debtsArr[0] - debtsArr[1];
        assertEq(remainingAfterSecond, 40e18);
        assertLt(remainingAfterSecond, minDebtThreshold);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__RemainingDebtBelowMinThreshold.selector, remainingAfterSecond, minDebtThreshold));
        dsce.batchLiquidate(weth, usersArr, debtsArr);
        vm.stopPrank();

        (uint256 debtAfter,) = dsce.getAccountInformation(alice);
        assertEq(debtAfter, debtBefore, "no partial progress should be committed");
    }

    /*//////////////////////////////////////////////////////////////
                               FLASH MINT
    //////////////////////////////////////////////////////////////*/

    function testConstructorRevertsOnZeroAddress() public {
        vm.expectRevert(FlashMintDWebThreePavlou.FlashMint__ZeroAddress.selector);
        new FlashMintDWebThreePavlou(address(0), address(dsc));

        vm.expectRevert(FlashMintDWebThreePavlou.FlashMint__ZeroAddress.selector);
        new FlashMintDWebThreePavlou(address(dsce), address(0));
    }

    function testFlashMintAllowsLiquidationOfUnsafePosition() public {
        // victim opens a position
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // DEX with DSC liquidity (no supply increase)
        MockDex dex = new MockDex(weth, address(dsc), 20e18);

        uint256 liqDsc = dsc.balanceOf(user); // no prank needed for a view
        vm.prank(user);
        dsc.transfer(address(dex), liqDsc);

        // crash price -> vault becomes unsafe
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(18e8);
        assertLt(dsce.getHealthFactor(user), MIN_HEALTH_FACTOR, "victim should be unsafe");

        // wire flash minter
        vm.prank(dsce.owner());
        dsce.setFlashMinter(address(flashMinter));

        // borrow only what engine allows
        uint256 debtToCover = dsce.maxFlashLoan(address(dsc));
        assertGt(debtToCover, 0, "no headroom for flash liquidation");

        MockFlashLiquidator liq = new MockFlashLiquidator(address(dsce), address(flashMinter), address(dsc), weth, address(dex), user);

        // prove we actually call liquidate()
        vm.expectCall(address(dsce), abi.encodeWithSelector(DSCEngine.liquidate.selector, weth, user, debtToCover));

        flashMinter.flashLoan(IERC3156FlashBorrower(address(liq)), address(dsc), debtToCover, hex"");

        // unique assertion: position is now safe (or at least improved to >= 1)
        assertGe(dsce.getHealthFactor(user), MIN_HEALTH_FACTOR, "victim should be safe after flash liquidation");

        // bonus should leave some WETH profit after swapping enough to repay
        assertGt(IERC20(weth).balanceOf(address(liq)), 0, "liquidator should keep some WETH profit");
    }

    function testFlashMintAllowsFullLiquidationOfUnsafePositionPathB() public {
        if (block.chainid != 31_337) return;

        //  Pre-crash surplus collateral (economically rational)
        ERC20MintableBurnableDecimals(weth).mint(exploiter, 20 ether);

        vm.startPrank(exploiter);
        IERC20(weth).approve(address(dsce), 20 ether);
        dsce.depositCollateral(weth, 20 ether);
        vm.stopPrank();

        // Arrange
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        //  DEX funded with victim’s existing DSC (no supply increase)
        MockDex dex = new MockDex(weth, address(dsc), 20e18);

        vm.startPrank(user); // Path B (no prank-consumed-by-balanceOf issues)
        dsc.transfer(address(dex), dsc.balanceOf(user));
        vm.stopPrank();

        //  Crash price
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(18e8);
        assertLt(dsce.getHealthFactor(user), MIN_HEALTH_FACTOR, "victim should be unsafe");

        //  Ensure flash minter wired
        vm.prank(dsce.owner());
        dsce.setFlashMinter(address(flashMinter));

        //  Borrow exactly the victim debt (full liquidation)
        (uint256 debtBefore,) = dsce.getAccountInformation(user);

        uint256 headroom = dsce.maxFlashLoan(address(dsc));
        assertGe(headroom, debtBefore, "not enough flash headroom for full liquidation");

        MockFlashLiquidator liq = new MockFlashLiquidator(address(dsce), address(flashMinter), address(dsc), weth, address(dex), user);

        // Prove we actually call liquidate()
        vm.expectCall(address(dsce), abi.encodeWithSelector(DSCEngine.liquidate.selector, weth, user, debtBefore));

        //  Act
        flashMinter.flashLoan(IERC3156FlashBorrower(address(liq)), address(dsc), debtBefore, hex"");

        // Assert: debt cleared
        (uint256 debtAfter,) = dsce.getAccountInformation(user);
        assertEq(debtAfter, 0, "victim debt should be cleared");

        // Liquidator should keep some WETH profit after swapping enough to repay
        assertGt(IERC20(weth).balanceOf(address(liq)), 0, "liquidator should profit in WETH");
    }

    function testFlashMintLiquidationRevertsWithoutHeadroom() public {
        if (block.chainid != 31_337) return;

        // Arrange
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // DEX funded (so failure is truly headroom, not liquidity)
        MockDex dex = new MockDex(weth, address(dsc), 20e18);
        vm.startPrank(user);
        dsc.transfer(address(dex), dsc.balanceOf(user));
        vm.stopPrank();

        // Crash price
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(18e8);
        assertLt(dsce.getHealthFactor(user), MIN_HEALTH_FACTOR);

        vm.prank(dsce.owner());
        dsce.setFlashMinter(address(flashMinter));

        (uint256 debtBefore,) = dsce.getAccountInformation(user);
        uint256 headroom = dsce.maxFlashLoan(address(dsc));
        assertLt(headroom, debtBefore, "this test assumes insufficient headroom");

        MockFlashLiquidator liq = new MockFlashLiquidator(address(dsce), address(flashMinter), address(dsc), weth, address(dex), user);

        vm.expectRevert(FlashMintDWebThreePavlou.FlashMint__AmountTooLarge.selector);
        flashMinter.flashLoan(IERC3156FlashBorrower(address(liq)), address(dsc), debtBefore, hex"");
    }

    function testFlashMintLiquidationRevertsIfDexHasInsufficientDsc() public {
        if (block.chainid != 31_337) return;

        // Pre-crash surplus collateral so headroom is not the reason we fail
        ERC20MintableBurnableDecimals(weth).mint(exploiter, 20 ether);
        vm.startPrank(exploiter);
        IERC20(weth).approve(address(dsce), 20 ether);
        dsce.depositCollateral(weth, 20 ether);
        vm.stopPrank();

        // Arrange
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // DEX funded with TOO LITTLE DSC
        MockDex dex = new MockDex(weth, address(dsc), 20e18);
        vm.startPrank(user);
        dsc.transfer(address(dex), 1e18); // intentionally tiny
        vm.stopPrank();

        // Crash price
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(18e8);

        vm.prank(dsce.owner());
        dsce.setFlashMinter(address(flashMinter));

        (uint256 debtBefore,) = dsce.getAccountInformation(user);
        uint256 headroom = dsce.maxFlashLoan(address(dsc));
        assertGe(headroom, debtBefore, "need headroom so failure is due to DEX liquidity");

        MockFlashLiquidator liq = new MockFlashLiquidator(address(dsce), address(flashMinter), address(dsc), weth, address(dex), user);

        // swap will fail with ERC20 insufficient balance inside DEX
        vm.expectRevert();
        flashMinter.flashLoan(IERC3156FlashBorrower(address(liq)), address(dsc), debtBefore, hex"");
    }

    function testSupplyRemainsTheSameAfterFlashMintOccurs() public {
        uint256 amount = 1000e18;

        // Seed engine with collateral so maxFlashLoan > 0
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), 1 ether);
        dsce.depositCollateral(weth, 1 ether);
        vm.stopPrank();

        vm.prank(dsce.owner());
        dsce.setFlashFeeBps(5); // 5 bps = 0.05%

        uint256 fee = dsce.flashFee(address(dsc), amount);
        uint256 repayAmount = amount + fee;

        assertGe(dsce.maxFlashLoan(address(dsc)), amount, "not enough flash headroom");

        MockFlashBorrower borrower = new MockFlashBorrower();

        // Give borrower fee (must exist pre-flash)
        vm.prank(address(flashMinter));
        dsc.mint(address(borrower), fee);

        uint256 supplyBefore = dsc.totalSupply();
        assertEq(supplyBefore, fee);

        uint256 borrowerBalBefore = dsc.balanceOf(address(borrower));
        uint256 engineBalBefore = dsc.balanceOf(address(dsce));
        uint256 flashMinterBalBefore = dsc.balanceOf(address(flashMinter));

        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(dsc), amount, hex"");

        uint256 supplyAfter = dsc.totalSupply();

        // Principal minted then burned -> supply unchanged (fee already existed)
        assertEq(supplyAfter, supplyBefore);

        // Borrower must have had enough to cover repayAmount during pull:
        // during callback it receives `amount` (flash-minted), and already had `fee`
        assertEq(borrowerBalBefore + amount, repayAmount);

        // Fee moved from borrower -> engine (feeRecipient)
        assertEq(dsc.balanceOf(address(borrower)), 0);
        assertEq(dsc.balanceOf(address(dsce)) - engineBalBefore, fee);

        // FlashMinter ends with zero: it burns principal and forwards fee
        assertEq(dsc.balanceOf(address(flashMinter)) - flashMinterBalBefore, 0);
    }

    function testFlashLoanRevertsIfFlashMinterNotSetAsDscMinter() public {
        // deploy fresh system but DON'T call dsce.setFlashMinter(...)
        address[] memory tokens = new address[](2);
        tokens[0] = weth;
        tokens[1] = wbtc;

        address[] memory feeds = new address[](2);
        feeds[0] = ethUsdPriceFeed;
        feeds[1] = btcUsdPriceFeed;

        DWebThreePavlouStableCoin newDsc = new DWebThreePavlouStableCoin(address(this));
        DSCEngine fresh = new DSCEngine(tokens, feeds, address(newDsc), address(this));
        FlashMintDWebThreePavlou fm = new FlashMintDWebThreePavlou(address(fresh), address(newDsc));

        // Seed engine with collateral so maxFlashLoan > 0
        vm.startPrank(user);
        IERC20(weth).approve(address(fresh), 1 ether);
        fresh.depositCollateral(weth, 1 ether);
        vm.stopPrank();

        // make engine the DSC owner (like your script does), but still don't set minter
        newDsc.transferOwnership(address(fresh));

        MockFlashBorrower borrower = new MockFlashBorrower();

        vm.expectRevert(DWebThreePavlouStableCoin.DWebThreePavlouSC__NotAuthorized.selector);
        fm.flashLoan(IERC3156FlashBorrower(address(borrower)), address(newDsc), 1e18, hex"");
    }

    function testMaxFlashLoanRespectsCollateralAndCeiling() public {
        // Initially engine holds no collateral => maxFlashLoan should be 0
        uint256 maxBefore = dsce.maxFlashLoan(address(dsc));
        assertEq(maxBefore, 0);

        // Deposit some WETH as collateral
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        // Expected: USD value of that collateral, capped by MAX_FLASH_MINT_AMOUNT
        uint256 expected = dsce.getUsdValue(weth, amountCollateral);
        uint256 maxAfter = dsce.maxFlashLoan(address(dsc));

        // In our setup 10 WETH << 1,000,000 DSC, so we expect exact equality
        assertEq(maxAfter, expected);
        assertLe(maxAfter, MAX_FLASH_MINT_AMOUNT);

        // Unsupported token => 0
        ERC20MintableBurnableDecimals randomERC20Token = new ERC20MintableBurnableDecimals("RND", "RND", 18);
        uint256 maxLoanUnsupported = dsce.maxFlashLoan(address(randomERC20Token));
        assertEq(maxLoanUnsupported, 0);
    }

    function testMaxFlashLoanReturnsZeroForWrongToken() public {
        assertEq(flashMinter.maxFlashLoan(weth), 0);
    }

    function testMaxFlashLoanReturnsEngineValueForDsc() public {
        uint256 a = flashMinter.maxFlashLoan(address(dsc));
        uint256 b = dsce.maxFlashLoan(address(dsc));
        assertEq(a, b);
    }

    function testMaxFlashLoanCapsAtGlobalCeiling() public {
        // 600 WETH * $2000 = $1.2M > 1,000,000 => should cap
        uint256 hugeAmountToMint = 600 ether;

        // give user more WETH
        ERC20MintableBurnableDecimals(weth).mint(user, hugeAmountToMint);

        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), hugeAmountToMint);
        dsce.depositCollateral(weth, hugeAmountToMint);
        vm.stopPrank();

        uint256 maxLoan = dsce.maxFlashLoan(address(dsc));
        assertEq(maxLoan, MAX_FLASH_MINT_AMOUNT);
    }

    function testOwnerCanUpdateFlashFeeBps() public {
        uint256 amount = FLASH_LOAN_AMOUNT;

        // default is 0 bps
        uint256 defaultFee = dsce.flashFee(address(dsc), amount);
        uint256 expectedDefaultFee = 0;
        assertEq(defaultFee, expectedDefaultFee);

        // set fee to 15 bps
        vm.prank(dsce.owner());
        dsce.setFlashFeeBps(15);

        uint256 zeroFee = dsce.flashFee(address(dsc), amount);
        assertNotEq(zeroFee, 15);
    }

    function testSetFlashFeeBpsEmitsEvent() public {
        address owner = dsce.owner();
        uint256 newBps = 25;

        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true, address(dsce));
        emit FlashFeeBpsUpdated(dsce.getFlashFeeBps(), newBps);

        dsce.setFlashFeeBps(newBps);
        vm.stopPrank();
    }

    function testSetFlashFeeBpsRevertsIfAbovePrecision() public {
        vm.startPrank(dsce.owner());
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__InvalidFlashFeeBps.selector, 10_001));
        dsce.setFlashFeeBps(10_001);
        vm.stopPrank();
    }

    function testFlashFeeSupportedToken() public view {
        uint256 amount = 1000 ether;
        // fee = amount * FLASH_FEE_MUL/FLASH_FEE_PRECISION
        uint256 expectedFee = (amount * 0) / 10_000;

        uint256 flashFee = dsce.flashFee(address(dsc), amount);
        assertEq(expectedFee, flashFee);
    }

    function testFlashFeeReturnsZeroWhenAmountIsZero() public {
        uint256 fee = flashMinter.flashFee(address(dsc), 0);
        assertEq(fee, 0);
    }

    function testFlashFeeRevertsOnBadToken() public {
        vm.expectRevert(FlashMintDWebThreePavlou.FlashMint__BadToken.selector);
        flashMinter.flashFee(weth, 1e18);
    }

    function testFlashFeeUnsupportedTokenReverts() public {
        ERC20MintableBurnableDecimals randomERC20Token = new ERC20MintableBurnableDecimals("RND", "RND", 18);

        vm.expectRevert(FlashMintDWebThreePavlou.FlashMint__BadToken.selector);
        flashMinter.flashFee(address(randomERC20Token), 1000);
    }

    function testFlashLoanCallsBorrowerCallback() public {
        // seed the engine
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        // use the already-deployed flashMinter from setUp()
        MockFlashBorrower borrower = new MockFlashBorrower();
        bytes memory data = "test-data";

        // fund borrower enough to repay principal+fee by minting DSC as the flashMinter
        // flashMinter was already set as minter in DeployDSC.run() so we impersonate it
        uint256 repayAmount = FLASH_LOAN_AMOUNT + ((FLASH_LOAN_AMOUNT * 0) / 10_000);
        vm.prank(address(flashMinter));
        dsc.mint(address(borrower), repayAmount);

        // now execute the flash loan from the borrower address (initiator)
        vm.startPrank(address(borrower));
        flashMinter.flashLoan(borrower, address(dsc), FLASH_LOAN_AMOUNT, data);
        vm.stopPrank();

        // Assertions
        assertTrue(borrower.called(), "borrower callback not called");
        assertEq(borrower.tokenReceived(), address(dsc));
        assertEq(borrower.amountReceived(), FLASH_LOAN_AMOUNT);
        assertEq(borrower.feeReceived(), (FLASH_LOAN_AMOUNT * 0) / 10_000);
        assertEq(borrower.dataReceived(), data);
    }

    function testFlashLoanMustTransferAmountBeforetheCallbackToTheReceiver() public {
        // seed the engine
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        MockFlashBorrower borrower = new MockFlashBorrower();

        // flashMinter = new FlashMintDWebThreePavlou(address(dsce), address(dsc));

        // Only the owner can call setFlashMinter()
        vm.prank(dsce.owner());
        dsce.setFlashMinter(address(flashMinter));

        uint256 amount = 10e18;
        uint256 flashFee = dsce.flashFee(address(dsc), amount);

        // Give borrower only enough DSC to repay the fee (only if fee > 0)
        if (flashFee > 0) {
            vm.prank(address(flashMinter));
            dsc.mint(address(borrower), flashFee);
        }

        bytes memory data = "adc";

        flashMinter.flashLoan(borrower, address(dsc), amount, data);

        assertTrue(borrower.receivedBeforeCallback(), "Loan wasnt transferred before callback");

        uint256 expectedInsideCallbackBalance = amount + flashFee; // with fee=0 => amount
        assertEq(borrower.balanceInsideCallback(), expectedInsideCallbackBalance, "Callback saw unexpected balance");
    }

    function testSetFlashMinterRevertsIfNotOwner() public {
        address nonOwner = address(1);
        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        dsce.setFlashMinter(nonOwner);
        vm.stopPrank();
    }

    function testSetFlashMinterRevertsIfZero() public {
        vm.startPrank(dsce.owner());
        vm.expectRevert(DSCEngine.DSCEngine__InvalidFlashMinter.selector);
        dsce.setFlashMinter(address(0));
        vm.stopPrank();
    }

    function testFlashLoanParamsPassedExactly() public {
        // seed the engine
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        bytes memory arbitraryData = abi.encode("test-data", 42);

        MockFlashBorrower borrower = new MockFlashBorrower();

        // Fund borrower to be able to repay principal + fee (mint from flashMinter)
        uint256 fee = dsce.flashFee(address(dsc), FLASH_LOAN_AMOUNT);
        uint256 repayAmount = FLASH_LOAN_AMOUNT + fee;
        vm.prank(address(flashMinter));
        dsc.mint(address(borrower), repayAmount);

        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(dsce.getDsc()), FLASH_LOAN_AMOUNT, arbitraryData);

        // Asserts

        assertEq(borrower.tokenReceived(), address(dsce.getDsc()));
        assertEq(borrower.amountReceived(), FLASH_LOAN_AMOUNT);
        assertEq(borrower.dataReceived(), arbitraryData);
        assertEq(borrower.initiatorReceived(), address(this));
    }

    function testFlashLoanRevertsIfAmountTooLarge() public {
        MockFlashBorrower borrower = new MockFlashBorrower();

        vm.expectRevert(FlashMintDWebThreePavlou.FlashMint__AmountTooLarge.selector);
        flashMinter.flashLoan(borrower, address(dsc), MAX_FLASH_MINT_AMOUNT + 1, hex"");
    }

    function _performFlashLoan(
        MockFlashBorrower borrower,
        bytes memory userData
    ) internal returns (bool) {
        uint256 expectedFee = dsce.flashFee(address(dsc), FLASH_LOAN_AMOUNT);

        // Borrower will receive principal from the flashLoan mint,
        // so it only needs pre-balance for the fee (if any).
        if (expectedFee > 0) {
            vm.prank(address(flashMinter)); // flashMinter is the minter
            dsc.mint(address(borrower), expectedFee);
        }

        // initiator can be whoever
        return flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(dsc), FLASH_LOAN_AMOUNT, userData);
    }

    function testFlashLoanRevertsOnBadToken() public {
        MockFlashBorrower borrower = new MockFlashBorrower();

        vm.expectRevert(FlashMintDWebThreePavlou.FlashMint__BadToken.selector);
        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), weth, 1e18, hex"");
    }

    function testFlashLoanRevertsOnZeroAmount() public {
        MockFlashBorrower borrower = new MockFlashBorrower();

        vm.expectRevert(FlashMintDWebThreePavlou.FlashMint__MoreThanZero.selector);
        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(dsc), 0, hex"");
    }

    function testFlashLoanRevertsWhenAmountTooLarge() public {
        MockFlashBorrower borrower = new MockFlashBorrower();

        uint256 maxLoan = dsce.maxFlashLoan(address(dsc));
        // your system caps maxLoan well below type(uint256).max, but keep it safe anyway
        uint256 tooLarge = maxLoan + 1;

        vm.expectRevert(FlashMintDWebThreePavlou.FlashMint__AmountTooLarge.selector);
        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(dsc), tooLarge, hex"");
    }

    function testFlashLoanPassesCorrectFeeToBorrower() public {
        // seed the engine
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        MockFlashBorrower borrower = new MockFlashBorrower();
        bytes memory userData = "123";

        _performFlashLoan(borrower, userData);

        uint256 expectedFee = dsce.flashFee(address(dsc), FLASH_LOAN_AMOUNT);

        // Assertions
        assertTrue(borrower.called(), "onFlashLoan callback was not called");
        assertEq(borrower.feeReceived(), expectedFee, "fee mismatch");
        assertEq(borrower.amountReceived(), FLASH_LOAN_AMOUNT, "principal mismatch");
        assertEq(borrower.tokenReceived(), address(dsc), "token mismatch");
        assertEq(borrower.dataReceived(), userData, "data mismatch");
    }

    function testFlashLoanForwardsFeeWhenFeeBpsNonZero() public {
        if (block.chainid != 31_337) return;

        // turn on fee so we hit the `if (fee > 0)` branch in FlashMint
        vm.prank(dsce.owner());
        dsce.setFlashFeeBps(5); // 5 bps

        // fund user with DSC so user can pay the fee to the borrower (borrower only receives principal)
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), 10 ether);
        dsce.depositCollateralAndMintDsc(weth, 10 ether, 200e18);
        vm.stopPrank();

        MockFlashBorrower borrower = new MockFlashBorrower();

        uint256 amount = 100e18;
        uint256 fee = dsce.flashFee(address(dsc), amount);
        assertGt(fee, 0, "fee must be > 0 to cover branch");

        address feeRecipient = dsce.getFlashFeeRecipient();
        assertTrue(feeRecipient != address(0));

        // pre-fund borrower with the fee so it can repay amount+fee
        vm.prank(user);
        dsc.transfer(address(borrower), fee);

        uint256 feeRecipientBefore = dsc.balanceOf(feeRecipient);
        uint256 fmBefore = dsc.balanceOf(address(flashMinter));
        uint256 supplyBefore = dsc.totalSupply();

        // event should include fee + feeRecipient
        vm.expectEmit(true, true, true, true, address(flashMinter));
        emit FlashLoanExecuted(user, address(borrower), address(dsc), amount, fee, feeRecipient);

        vm.prank(user);
        bool ok = flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(dsc), amount, hex"");
        assertTrue(ok);

        // fee got forwarded
        assertEq(dsc.balanceOf(feeRecipient) - feeRecipientBefore, fee);

        // flash minter retains no DSC (principal burned, fee forwarded)
        assertEq(dsc.balanceOf(address(flashMinter)) - fmBefore, 0);

        // flashloan itself should not change totalSupply (mint+burn net 0, fee was pre-existing)
        assertEq(dsc.totalSupply(), supplyBefore);
    }

    function testFlashLoanCallbackReturnsCorrectSelector() public {
        // seed the engine
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        vm.prank(dsce.owner());
        dsce.setFlashFeeBps(0);

        MockFlashBorrower borrower = new MockFlashBorrower();

        bytes memory userData = "123";

        bool ok = _performFlashLoan(borrower, userData);

        assertTrue(ok, "flashLoan should succeed");
        assertTrue(borrower.called(), "Borrower callback not called");
        assertEq(borrower.amountReceived(), FLASH_LOAN_AMOUNT);
    }

    function testFlashLoanRevertsIfCallbackReturnsWrongValue() public {
        // seed the engine
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        MockBadFlashBorrower badBorrower = new MockBadFlashBorrower();
        bytes memory userData = "test-data";

        uint256 repayAmount = FLASH_LOAN_AMOUNT + dsce.flashFee(address(dsc), FLASH_LOAN_AMOUNT);

        // Fund borrower
        vm.prank(address(flashMinter));
        dsc.mint(address(badBorrower), repayAmount);

        // Expect revert
        vm.expectRevert(FlashMintDWebThreePavlou.FlashMint__CallbackFailed.selector);

        flashMinter.flashLoan(IERC3156FlashBorrower(address(badBorrower)), address(dsc), FLASH_LOAN_AMOUNT, userData);
    }

    function testFlashLoanRepaysSuccessfully() public {
        // seed the engine
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        MockFlashBorrower borrower = new MockFlashBorrower();
        bytes memory data = "repay-test";

        // Execute flash loan
        bool result = _performFlashLoan(borrower, data);

        uint256 expectedFee = dsce.flashFee(address(dsc), FLASH_LOAN_AMOUNT);

        assertTrue(result, "flashLoan should return true on successful repayment");

        // Verify the borrower's balance is back to 0
        assert(dsc.balanceOf(address(borrower)) >= 0);

        // Verify the fee went to DSCEngine
        uint256 engineFee = dsc.balanceOf(address(dsce));
        assertEq(engineFee, expectedFee, "engine did not receive flash loan fee");
    }

    function testFlashLoanReceiverMustReturnCorrectHashAndApprove() public {
        // seed the engine
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        MockFlashBorrower borrower = new MockFlashBorrower();
        bytes memory data = "absdkjn";

        vm.startPrank(dsce.owner());
        dsce.setFlashMinter(address(flashMinter));
        vm.stopPrank();

        bool success = _performFlashLoan(borrower, data);

        assertTrue(success);
        assertEq(borrower.tokenReceived(), address(dsc));
        assertEq(borrower.amountReceived(), FLASH_LOAN_AMOUNT);
    }

    function testFlashMintExecuteFlashMintNoEngineLedgerFeeZero() public {
        uint256 amount = 1000e18;

        // Ensure fee is zero (default == 0)
        vm.prank(dsce.owner());
        dsce.setFlashFeeBps(0);

        // Seed collateral so maxFlashLoan > 0
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), 2 ether);
        dsce.depositCollateral(weth, 2 ether);
        vm.stopPrank();

        assertGe(dsce.maxFlashLoan(address(dsc)), amount, "insufficient flash headroom");

        MockFlashBorrower borrower = new MockFlashBorrower();

        uint256 supplyBefore = dsc.totalSupply();
        uint256 engineBalBefore = dsc.balanceOf(address(dsce));
        uint256 flashMinterBalBefore = dsc.balanceOf(address(flashMinter));

        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(dsc), amount, hex"");

        // Fee = 0 => total supply should be unchanged (mint amount then burn amount)
        assertEq(dsc.totalSupply(), supplyBefore);

        // Engine receives no fee
        assertEq(dsc.balanceOf(address(dsce)), engineBalBefore);

        // FlashMinter should not retain tokens after burning principal
        assertEq(dsc.balanceOf(address(flashMinter)), flashMinterBalBefore);

        // Borrower ends with 0 (it repaid principal)
        assertEq(dsc.balanceOf(address(borrower)), 0);

        // Callback executed and fee was 0
        assertTrue(borrower.called());
        assertEq(borrower.feeReceived(), 0);
    }

    function testFlashLoanPrincipalNotHealedInsideCallbackFeeZeroStillSettles() public {
        // seed the engine
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        // fee = 0
        vm.prank(dsce.owner());
        dsce.setFlashFeeBps(0);

        MockFlashBorrower borrower = new MockFlashBorrower();
        bytes memory data = hex"";

        uint256 supplyBefore = dsc.totalSupply();
        uint256 engineBalBefore = dsc.balanceOf(address(dsce));
        uint256 flashMinterBalBefore = dsc.balanceOf(address(flashMinter));
        uint256 borrowerBalBefore = dsc.balanceOf(address(borrower));

        // run flash loan (initiator can be anything)
        vm.prank(address(borrower));
        flashMinter.flashLoan(borrower, address(dsc), FLASH_LOAN_AMOUNT, data);

        // callback happened
        assertTrue(borrower.called());

        // fee=0 => engine gets nothing
        assertEq(dsc.balanceOf(address(dsce)) - engineBalBefore, 0);

        // flashMinter should not retain funds (principal burned, fee forwarded)
        assertEq(dsc.balanceOf(address(flashMinter)) - flashMinterBalBefore, 0);

        // borrower ends with no leftover DSC (it repaid exactly principal, fee=0)
        assertEq(dsc.balanceOf(address(borrower)) - borrowerBalBefore, 0);

        // total supply unchanged by principal (mint then burn), fee=0 so no net mint
        assertEq(dsc.totalSupply(), supplyBefore);
    }

    function testFlashLoanRevertsIfBorrowerDoesNotApprove() public {
        MockBadFlashBorrower badBorrower = new MockBadFlashBorrower();

        bytes memory data = "sdfjhfg";

        vm.startPrank(dsce.owner());
        dsce.setFlashMinter(address(flashMinter));
        vm.stopPrank();

        vm.expectRevert();

        flashMinter.flashLoan(IERC3156FlashBorrower(address(badBorrower)), address(dsc), FLASH_LOAN_AMOUNT, data);
    }

    function testFlashLoanRevertsIfBorrowerReverts() public {
        MockBorrowerReverts borrowerReverts = new MockBorrowerReverts();
        bytes memory data = "dadff";

        vm.startPrank(dsce.owner());
        dsce.setFlashMinter(address(flashMinter));
        vm.stopPrank();

        vm.expectRevert();

        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrowerReverts)), address(dsc), FLASH_LOAN_AMOUNT, data);
    }

    function testEngineFlashFeeReturnsZeroForUnsupportedTokens() public {
        ERC20MintableBurnableDecimals rnd = new ERC20MintableBurnableDecimals("RND", "RND", 18);

        uint256 fee = dsce.flashFee(address(rnd), FLASH_LOAN_AMOUNT);
        assertEq(fee, 0);
    }

    function testFlashFeeReturnsForSupportedDsc() public view {
        uint256 expectedFee = (FLASH_LOAN_AMOUNT * 0) / 10_000;
        uint256 fee = dsce.flashFee(address(dsc), FLASH_LOAN_AMOUNT);
        assertEq(fee, expectedFee);
    }

    function testFlashLoanRevertsForUnsupportedTokens() public {
        ERC20MintableBurnableDecimals rnd = new ERC20MintableBurnableDecimals("RND", "RND", 18);
        MockFlashBorrower borrower = new MockFlashBorrower();

        vm.expectRevert(FlashMintDWebThreePavlou.FlashMint__BadToken.selector);
        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(rnd), 1e18, hex"");
    }

    function testRevertsIfTokenIsWrong() public {
        // borrower can be anything; it won't be called because lender reverts early
        ERC20MintableBurnableDecimals randomERC20Token = new ERC20MintableBurnableDecimals("RND", "RND", 18);

        MockFlashBorrowerRejectsWrongToken borrower = new MockFlashBorrowerRejectsWrongToken(address(randomERC20Token));

        uint256 supplyBefore = dsc.totalSupply();

        vm.expectRevert(FlashMintDWebThreePavlou.FlashMint__BadToken.selector);
        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(0xBAD), FLASH_LOAN_AMOUNT, "");

        // callback never ran
        assertFalse(borrower.called());

        // nothing minted/burned because revert happens before mint
        assertEq(dsc.totalSupply(), supplyBefore);
    }

    function testRevertsIfBorrowerLiesAboutAmount() public {
        MockFlashBorrowerLiesAboutTheAmount lyingBorrower = new MockFlashBorrowerLiesAboutTheAmount();

        bytes memory data = "dadff";

        vm.startPrank(dsce.owner());
        dsce.setFlashMinter(address(flashMinter));
        vm.stopPrank();

        vm.expectRevert();

        flashMinter.flashLoan(IERC3156FlashBorrower(address(lyingBorrower)), address(dsc), FLASH_LOAN_AMOUNT, data);
    }

    function testDoesNotRevertIfBorrowerLiesAboutFeeWhenFeeIsZero() public {
        if (block.chainid != 31_337) return;
        MockFlashBorrowerLiesAboutTheFee lyingBorrower = new MockFlashBorrowerLiesAboutTheFee();
        bytes memory data = "dadff";

        // fee = 0
        vm.prank(dsce.owner());
        dsce.setFlashFeeBps(0);

        // seed protocol with collateral so maxFlashLoan > 0
        address lp = makeAddr("lp");
        uint256 seedCollateral = 1 ether; // enough to cover 1000e18

        ERC20MintableBurnableDecimals(weth).mint(lp, seedCollateral);

        vm.startPrank(lp);
        IERC20(weth).approve(address(dsce), seedCollateral);
        dsce.depositCollateral(weth, seedCollateral);
        vm.stopPrank();

        // sanity
        uint256 maxLoan = dsce.maxFlashLoan(address(dsc));
        assertGe(maxLoan, FLASH_LOAN_AMOUNT, "not enough headroom for flash loan");

        // No expectRevert here: borrower "lying about fee" shouldn't matter when fee == 0
        flashMinter.flashLoan(IERC3156FlashBorrower(address(lyingBorrower)), address(dsc), FLASH_LOAN_AMOUNT, data);
    }

    function testExecuteFlashMintRevertsIfBadAmount() public {
        MockFlashBorrower borrower = new MockFlashBorrower();

        vm.prank(address(dsce));
        vm.expectRevert(FlashMintDWebThreePavlou.FlashMint__MoreThanZero.selector);

        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(dsc), 0, hex"");
    }

    function testExecuteFlashMintRevertsIfBadToken() public {
        MockFlashBorrower borrower = new MockFlashBorrower();
        ERC20MintableBurnableDecimals fake = new ERC20MintableBurnableDecimals("FAKE", "FAKE", 18);

        vm.prank(address(dsce));
        vm.expectRevert(FlashMintDWebThreePavlou.FlashMint__BadToken.selector);

        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(fake), 1e18, hex"");
    }

    function testFlashLoanSelectorIsCorrect() public view {
        bytes4 selector = flashMinter.flashLoan.selector;
        assertEq(selector, bytes4(keccak256("flashLoan(address,address,uint256,bytes)")), "flashLoan function should have correct selector");
    }

    function testFlashLoanWithDifferentInitiatorAndReceiver() public {
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        // Arrange
        MockFlashBorrower receiver = new MockFlashBorrower(); // The actual borrower receiving the loan
        address initiator = address(1); // The contract/address initiating the flash loan
        bytes memory data = "flexible-initiator-test";

        uint256 fee = dsce.flashFee(address(dsc), FLASH_LOAN_AMOUNT);
        uint256 repayAmount = FLASH_LOAN_AMOUNT + fee;

        // Fund receiver so it can repay principal + fee
        vm.prank(address(flashMinter));
        dsc.mint(address(receiver), repayAmount);

        // Act
        // Impersonate the initiator calling the flashLoan
        vm.prank(initiator);
        flashMinter.flashLoan(
            IERC3156FlashBorrower(address(receiver)), // receiver
            address(dsc),
            FLASH_LOAN_AMOUNT,
            data
        );

        // Assert
        assertTrue(receiver.called(), "Receiver callback not called");
        assertEq(receiver.amountReceived(), FLASH_LOAN_AMOUNT);
        assertEq(receiver.feeReceived(), fee);
        assertEq(receiver.dataReceived(), data);
        assertEq(receiver.initiatorReceived(), initiator); // Check EIP-3156: initiator param is preserved
    }

    function testFlashLoanDataParameterPassedCorrectly() public {
        // seed the engine
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        // Arrange
        MockFlashBorrower borrower = new MockFlashBorrower();

        bytes memory arbitraryData = abi.encode("user-message", uint256(42), address(this));

        uint256 fee = dsce.flashFee(address(dsc), FLASH_LOAN_AMOUNT);
        uint256 repayAmount = FLASH_LOAN_AMOUNT + fee;

        // Fund borrower so it can repay the fee
        vm.prank(address(flashMinter));
        dsc.mint(address(borrower), repayAmount);

        // Act
        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(dsc), FLASH_LOAN_AMOUNT, arbitraryData);

        // Assert
        assertTrue(borrower.called(), "Borrower callback was not called");
        assertEq(borrower.dataReceived(), arbitraryData, "Data parameter was modified");
        assertEq(borrower.amountReceived(), FLASH_LOAN_AMOUNT, "Principal mismatch");
        assertEq(borrower.feeReceived(), fee, "Fee mismatch");
        assertEq(borrower.tokenReceived(), address(dsc), "Token mismatch");
    }

    function testFlashLoanInitiatorMatchesMsgSender() public {
        // seed the engine
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        MockFlashBorrower borrower = new MockFlashBorrower();
        bytes memory data = "initiator-test";

        // Fund borrower with principal + fee
        uint256 fee = dsce.flashFee(address(dsc), FLASH_LOAN_AMOUNT);
        uint256 repayAmount = FLASH_LOAN_AMOUNT + fee;
        vm.prank(address(flashMinter));
        dsc.mint(address(borrower), repayAmount);

        // Execute flash loan
        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(dsc), FLASH_LOAN_AMOUNT, data);

        // Assert: initiator received inside callback matches lender contract (flashMinter)
        assertEq(borrower.initiatorReceived(), address(this), "initiator does not match msg.sender");
    }

    function testFlashLoanEmitsFlashMinterExecuted() public {
        // seed the engine
        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        MockFlashBorrower borrower = new MockFlashBorrower();

        uint256 amount = FLASH_LOAN_AMOUNT;

        vm.prank(dsce.owner());
        dsce.setFlashFeeBps(0);

        uint256 fee = dsce.flashFee(address(dsc), amount);
        assertEq(fee, 0);

        address feeRecipient = dsce.getFlashFeeRecipient();
        bytes memory data = "event-test";

        vm.expectEmit(true, true, true, true, address(flashMinter));
        emit FlashLoanExecuted(address(this), address(borrower), address(dsc), amount, fee, feeRecipient);

        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(dsc), amount, data);
    }

    /*//////////////////////////////////////////////////////////////
                              MAX PRICE AGE
    //////////////////////////////////////////////////////////////*/
    function testStrictMaxPriceAgeMakesPriceStaleSooner() public {
        uint256 strictAge = 30 minutes;

        vm.prank(dsce.owner());
        dsce.setMaxPriceAge(weth, strictAge);

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(2000e8);

        //warp beyond strictAge but still below default TIMEOUT
        vm.warp(block.timestamp + strictAge + 1 seconds);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        dsce.getUsdValue(weth, 1 ether);
    }

    function testLooseMaxPriceAgeAllowsOlderButStillBoundedPrice() public {
        // Set 24h age - Arbitrum style
        uint256 arbStyleAge = 24 hours;
        vm.prank(dsce.owner());
        dsce.setMaxPriceAge(weth, arbStyleAge);

        // price fresh
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(2000e8);

        //  Warp past the 3h default ΤΙΜΕOUT but less than 24h
        vm.warp(block.timestamp + 4 hours);

        // With default TIMEOUT this would revert, but with override it should pass

        dsce.getUsdValue(weth, 1 ether);
    }

    function testDefaultMaxPriceAgeUsesOracleLibTimeout() public {
        // *Don’t* call setMaxPriceAge here -> s_maxPriceAge[weth] == 0,
        // so DSCEngine should fall back to OracleLib.getTimeOut()
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(2000e8);

        // Warp less than 3h -> no revert
        vm.warp(block.timestamp + 2 hours);
        dsce.getUsdValue(weth, 1 ether);

        // Warp beyond 3h -> now should revert
        vm.warp(block.timestamp + 4 hours);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        dsce.getUsdValue(weth, 1 ether);
    }

    function testMintDscRevertsWhenPriceStale() public {
        // deposit fresh collateral
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        // set strict age
        vm.prank(dsce.owner());
        dsce.setMaxPriceAge(weth, 1 hours);

        // warp beyond that
        vm.warp(block.timestamp + 2 hours);

        // mintDsc internally calls getAccountCollateralValue -> _getUsdValue -> staleCheckLatestRoundData
        vm.startPrank(user);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testSetMaxPriceAgeEmitsEvent() public {
        address owner = dsce.owner();
        uint256 newAge = 3600;

        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true, address(dsce));
        emit MaxPriceAgeUpdated(weth, newAge);

        dsce.setMaxPriceAge(weth, newAge);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           ADDITIONAL TESTING
    //////////////////////////////////////////////////////////////*/

    function _totalSystemCollateralValueUsd() internal view returns (uint256 totalUsd) {
        address[] memory tokens = dsce.getCollateralTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            uint256 bal = IERC20(t).balanceOf(address(dsce));
            if (bal == 0) continue;
            totalUsd += dsce.getUsdValue(t, bal);
        }
    }

    function _assertSystemSolvent() internal view {
        address[] memory tokens = dsce.getCollateralTokens();

        uint256 totalCollateralUsd;
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 bal = IERC20(token).balanceOf(address(dsce));
            if (bal == 0) continue;

            totalCollateralUsd += dsce.getUsdValue(token, bal);
        }

        uint256 supply = dsc.totalSupply();
        assertGe(totalCollateralUsd, supply, "INVARIANT BROKEN: collateralUsd < totalSupply");
    }

    function _flashLoanExecutedStats(
        Vm.Log[] memory logs,
        address expectedInitiator,
        address expectedReceiver,
        address expectedToken
    ) internal view returns (uint256 count, uint256 sumAmount, uint256 sumFee, address feeRecipient) {
        // matches your trace: FlashLoanExecuted(..., feeRecipient)
        bytes32 sig = keccak256("FlashLoanExecuted(address,address,address,uint256,uint256,address)");

        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory l = logs[i];

            if (l.emitter != address(flashMinter)) continue;
            if (l.topics.length == 0) continue;
            if (l.topics[0] != sig) continue;

            address initiator = address(uint160(uint256(l.topics[1])));
            address receiver = address(uint160(uint256(l.topics[2])));
            address token = address(uint160(uint256(l.topics[3])));

            if (initiator != expectedInitiator) continue;
            if (receiver != expectedReceiver) continue;
            if (token != expectedToken) continue;

            (uint256 amt, uint256 fee, address fr) = abi.decode(l.data, (uint256, uint256, address));

            count++;
            sumAmount += amt;
            sumFee += fee;
            feeRecipient = fr;
        }
    }

    function testFlashLoanEmitsFlashLoanExecutedOnceAndSettlesFeeZero() public {
        uint256 amount = 100e18;

        // Seed engine collateral so maxFlashLoan() > 0
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        // fee = 0
        vm.prank(dsce.owner());
        dsce.setFlashFeeBps(0);

        MockFlashBorrower borrower = new MockFlashBorrower();

        vm.recordLogs();
        vm.prank(exploiter); // initiator irrelevant
        flashMinter.flashLoan(IERC3156FlashBorrower(address(borrower)), address(dsc), amount, hex"");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Assert: FlashLoanExecuted emitted exactly once
        (uint256 count, uint256 sumAmount, uint256 sumFee, address feeRecipient) = _flashLoanExecutedStats(logs, exploiter, address(borrower), address(dsc));

        assertEq(count, 1, "FlashLoanExecuted should be emitted once");
        assertEq(sumAmount, amount, "sum amount should equal principal");
        assertEq(sumFee, 0, "fee should be 0");
        assertEq(feeRecipient, address(dsce), "fee recipient should be DSCEngine");

        // Sanity: borrower callback ran and got the principal inside callback
        assertTrue(borrower.called(), "borrower callback not called");
        assertEq(borrower.amountReceived(), amount);

        // Net effects
        assertEq(dsc.totalSupply(), 0, "principal should mint+burn => no supply");
        assertEq(dsc.balanceOf(address(flashMinter)), 0, "flashMinter should not retain tokens");
    }

    function testBurnDscEmitsDscBurnedFalseWhenNotFlashRepayment() public {
        uint256 burnAmount = 25e18;

        // Arrange: user mints DSC so they can burn
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);

        // Approve engine to pull DSC for burn (non-flash path uses safeTransferFrom)
        dsc.approve(address(dsce), burnAmount);

        // Act (record logs because ERC20 emits Transfer before DscBurned)
        vm.recordLogs();
        dsce.burnDsc(burnAmount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.stopPrank();

        // Assert: find DSCEngine.DscBurned(onBehalfOf=user, dscFrom=user, amount=burnAmount, wasFlashRepayment=false)
        bytes32 sig = keccak256("DscBurned(address,address,uint256,bool)");
        bool found;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(dsce)) continue;
            if (logs[i].topics.length < 3) continue;
            if (logs[i].topics[0] != sig) continue;

            address onBehalfOf = address(uint160(uint256(logs[i].topics[1])));
            address dscFrom = address(uint160(uint256(logs[i].topics[2])));
            (uint256 amt, bool wasFlash) = abi.decode(logs[i].data, (uint256, bool));

            assertEq(onBehalfOf, user);
            assertEq(dscFrom, user);
            assertEq(amt, burnAmount);
            assertEq(wasFlash, false);

            found = true;
            break;
        }

        assertTrue(found, "DscBurned event not found");

        // debt reduced
        (uint256 debtAfter,) = dsce.getAccountInformation(user);
        assertEq(debtAfter, amountToMint - burnAmount);
    }

    function testFlashLiquidationRevertsWhenTargetIsHealthyNoCollateralProfit() public {
        if (block.chainid != 31_337) return;

        // Make user safely collateralized
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(3000e8)); // $3000

        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        assertGe(dsce.getHealthFactor(user), MIN_HEALTH_FACTOR, "User should be healthy");

        // MockDex is required by your MockFlashLiquidator constructor; it won't be used (revert happens earlier)
        MockDex dex = new MockDex(weth, address(dsc), 20e18);

        MockFlashLiquidator flashLiq = new MockFlashLiquidator(address(dsce), address(flashMinter), address(dsc), weth, address(dex), user);

        // Snapshot balances (ensure no collateral leakage)
        uint256 liqWethBefore = IERC20(weth).balanceOf(address(flashLiq));
        uint256 engineWethBefore = IERC20(weth).balanceOf(address(dsce));
        uint256 supplyBefore = dsc.totalSupply();

        bytes memory data = abi.encode(user, weth, amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        vm.prank(address(flashLiq));
        flashMinter.flashLoan(IERC3156FlashBorrower(address(flashLiq)), address(dsc), amountToMint, data);

        // State must be unchanged because tx reverted
        assertEq(IERC20(weth).balanceOf(address(flashLiq)), liqWethBefore, "Liquidator should not gain collateral");
        assertEq(IERC20(weth).balanceOf(address(dsce)), engineWethBefore, "Engine collateral must be unchanged");
        assertEq(dsc.totalSupply(), supplyBefore, "Supply must be unchanged on revert");

        _assertSystemSolvent();
    }

    function testFreeProfitAttemptNoRepayFlashLiquidationReverts() public {
        if (block.chainid != 31_337) return;

        // Safe mint time
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(300e8)); // $300

        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), 1 ether);
        dsce.depositCollateralAndMintDsc(weth, 1 ether, 100e18);
        vm.stopPrank();

        // Unsafe now (but still enough value to cover debt)
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(105e8)); // $105
        assertLt(dsce.getHealthFactor(user), MIN_HEALTH_FACTOR);

        MockBadFlashBorrower attacker = new MockBadFlashBorrower();

        bytes memory data = abi.encode(user, weth, 100e18);

        // This MUST revert if repayment enforcement is correct
        vm.expectRevert();
        flashMinter.flashLoan(attacker, address(dsc), 100e18, data);

        // State unchanged after revert: still solvent
        _assertSystemSolvent();
    }

    function testInvariant_SystemCollateralUsdGteTotalSupplyAfterFlashLiquidation() public {
        if (block.chainid != 31_337) return;

        // --- Make mint time safe ---
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(300e8)); // $300

        // Victim opens position
        uint256 userDeposit = 1 ether;
        uint256 userDebt = 100e18;

        ERC20MintableBurnableDecimals(weth).mint(user, userDeposit);

        vm.startPrank(user);
        IERC20(weth).approve(address(dsce), userDeposit);
        dsce.depositCollateralAndMintDsc(weth, userDeposit, userDebt);
        vm.stopPrank();

        // Baseline invariant
        _assertSystemSolvent();

        // --- Create a "real" DSC liquidity provider (backed DSC) ---
        address lp = makeAddr("lp");
        uint256 lpDeposit = 2 ether;
        uint256 lpMint = 100e18; // enough to cover repay, and keep LP healthy after crash

        ERC20MintableBurnableDecimals(weth).mint(lp, lpDeposit);

        vm.startPrank(lp);
        IERC20(weth).approve(address(dsce), lpDeposit);
        dsce.depositCollateralAndMintDsc(weth, lpDeposit, lpMint);
        vm.stopPrank();

        // --- Crash price: user becomes unsafe ---
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(105e8)); // $105

        assertLt(dsce.getHealthFactor(user), MIN_HEALTH_FACTOR, "User should be liquidatable after drop");
        assertGe(dsce.getHealthFactor(lp), MIN_HEALTH_FACTOR, "LP should remain healthy (for clean liquidity)");

        // --- DEX seeded with backed DSC ---
        // Choose a rate that makes repay feasible with seized WETH
        MockDex dex = new MockDex(
            weth,
            address(dsc),
            200e18 /* 200 DSC per 1 WETH */
        );

        vm.prank(lp);
        IERC20(address(dsc)).transfer(address(dex), lpMint);

        // --- Flash liquidator borrower (dex-aware mock) ---
        MockFlashLiquidator flashLiq = new MockFlashLiquidator(address(dsce), address(flashMinter), address(dsc), weth, address(dex), user);

        // Act: flashLoan -> callback -> liquidation -> swap -> repay
        bytes memory data = abi.encode(user, weth, userDebt);

        vm.prank(address(flashLiq));
        flashMinter.flashLoan(IERC3156FlashBorrower(address(flashLiq)), address(dsc), userDebt, data);

        // User’s debt should be wiped
        (uint256 userDebtAfter,) = dsce.getAccountInformation(user);
        assertEq(userDebtAfter, 0, "User debt should be wiped");

        // User still holds originally minted DSC (liquidator burned THEIR DSC, not user's tokens)
        assertEq(dsc.balanceOf(user), userDebt, "User still holds originally minted DSC");

        // Critical solvency check
        _assertSystemSolvent();
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/
    function testSetMinPositionValueUsdUpdatesValue() public {
        // Arrange
        uint256 newValue = 500e18;
        vm.prank(dsce.owner());
        // Act – call setter as owner
        dsce.setMinPositionValueUsd(newValue);

        // Assert – getter should now return the new value
        uint256 actual = dsce.getMinPositionValueUsd();
        assertEq(actual, newValue);
    }

    function testSetMinPositionValueUsdRevertsIfNonOwner() public {
        // Arrange
        uint256 newValue = 500e18;
        address pretender;
        vm.prank(pretender);
        vm.expectRevert();
        dsce.setMinPositionValueUsd(newValue);
    }

    function testSetMinPositionValueUsdRevertsOnZero() public {
        uint256 newValue = 0;

        vm.prank(dsce.owner());
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.setMinPositionValueUsd(newValue);
    }

    function testSetMinPositionValueUsdEmitsEvent() public {
        address owner = dsce.owner();
        uint256 newMin = 500e18;

        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true, address(dsce));
        emit MinPositionValueUsdChanged(newMin);

        dsce.setMinPositionValueUsd(newMin);
        vm.stopPrank();
    }

    function testSetFlashFeeBpsUpdatesFee() public {
        uint256 newBps = 50;
        vm.prank(dsce.owner());
        dsce.setFlashFeeBps(newBps);

        assertEq(dsce.getFlashFeeBps(), newBps);

        uint256 amount = 1000e18;
        uint256 expected = (amount * newBps) / 10_000;
        assertEq(dsce.flashFee(address(dsc), amount), expected);
    }

    function testSetFlashFeeBpsRevertsAbovePrecision() public {
        vm.prank(dsce.owner());
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__InvalidFlashFeeBps.selector, 10_001));
        dsce.setFlashFeeBps(10_001);
    }

    function testSetFlashMinterRevertsIfNewMinterAddressZero() public {
        vm.prank(dsce.owner());
        vm.expectRevert(DSCEngine.DSCEngine__InvalidFlashMinter.selector);
        dsce.setFlashMinter(address(0));
    }

    function testSetFlashMinterRevertsIfNewMinterHasNoCode() public {
        address eoa = makeAddr("eoa");

        vm.prank(dsce.owner());
        vm.expectRevert(DSCEngine.DSCEngine__InvalidFlashMinter.selector);
        dsce.setFlashMinter(address(eoa));
    }

    function testSetFlashMinterDoesntRevertOnCodeLengthCheckForRealContracts() public {
        FlashMintDWebThreePavlou fresh = new FlashMintDWebThreePavlou(address(dsce), address(dsc));

        vm.prank(dsce.owner());

        dsce.setFlashMinter(address(fresh));

        assertEq(dsce.getFlashMinter(), address(fresh));
    }

    function testSetFlashMinterRevertsIfEngineMismatch() public {
        DSCEngine fakeEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc), dsce.owner());

        FlashMintDWebThreePavlou wrong = new FlashMintDWebThreePavlou(address(fakeEngine), address(dsc));

        vm.prank(dsce.owner());
        vm.expectRevert(DSCEngine.DSCEngine__InvalidFlashMinter.selector);
        dsce.setFlashMinter(address(wrong));
    }

    function testSetFlashMinterRevertsIfDscMismatch() public {
        DWebThreePavlouStableCoin otherDsc = new DWebThreePavlouStableCoin(dsce.owner());
        FlashMintDWebThreePavlou wrong = new FlashMintDWebThreePavlou(address(dsce), address(otherDsc));

        vm.prank(dsce.owner());
        vm.expectRevert(DSCEngine.DSCEngine__InvalidFlashMinter.selector);
        dsce.setFlashMinter(address(wrong));
    }

    function testSetFlashMinterEmitsFlashMinterUpdated() public {
        address owner = dsce.owner();

        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(dsce));
        emit FlashMinterUpdated(address(flashMinter));

        dsce.setFlashMinter(address(flashMinter));
    }

    function testSetFlashMinterRevertsIfZeroAddress() public {
        vm.prank(dsce.owner());
        vm.expectRevert(DSCEngine.DSCEngine__InvalidFlashMinter.selector);
        dsce.setFlashMinter(address(0));
    }

    function testSetWethMaxPriceAgeToArbitrumOneHeartBeat() public {
        vm.prank(dsce.owner());
        dsce.setMaxPriceAge(weth, 24 hours);
    }

    function testSetWethMaxPriceAgeToZeroReverts() public {
        vm.prank(dsce.owner());
        vm.expectRevert(DSCEngine.DSCEngine__MaxPriceAgeMustBeMoreThanZero.selector);
        dsce.setMaxPriceAge(weth, 0);
    }

    function testSetMaxPriceNotOnwerReverts() public {
        address attacker = address(1);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, attacker));
        dsce.setMaxPriceAge(weth, 2 hours);
    }

    function testSetMaxPriceForUknownTokenReverts() public {
        ERC20MintableBurnableDecimals randomToken = new ERC20MintableBurnableDecimals("RAN", "RAN", 4);
        vm.prank(dsce.owner());
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.setMaxPriceAge(address(randomToken), 1 hours);
    }

    function testSetMaxPriceEmitsAnEvent() public {
        uint256 newAge = 24 hours;

        vm.prank(dsce.owner());
        vm.expectEmit(true, true, true, true);
        emit MaxPriceAgeUpdated(weth, newAge);

        dsce.setMaxPriceAge(weth, newAge);
    }

    /*//////////////////////////////////////////////////////////////
                    VIEW & PURE FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = dsce.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = dsce.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        uint256 expectedCollateralValueInUsd = dsce.getUsdValue(weth, amountCollateral);
        (, uint256 collateralValue) = dsce.getAccountInformation(user);
        assertEq(expectedCollateralValueInUsd, collateralValue);
    }

    function testGetCollateralBalanceOfUser() public depositedCollateral {
        uint256 collateralBalance = dsce.getCollateralBalanceOfUser(user, weth);
        assertEq(collateralBalance, amountCollateral);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(user);
        ERC20MintableBurnableDecimals(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        uint256 collateralValue = dsce.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, amountCollateral);

        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public view {
        address dscAddress = dsce.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testGetLiquidationPrecision() public view {
        uint256 liquidationPrecision = dsce.getLiquidationPrecision();
        assertEq(liquidationPrecision, LIQUIDATION_PRECISION);
    }

    function testGetMinPositionValueUsd() public view {
        uint256 expectedMinPositionValueUsd = dsce.getMinPositionValueUsd();
        assertEq(expectedMinPositionValueUsd, 250e18);
    }

    function testGetFlashFeeRecipient() public view {
        address expectedFlashFeeRecipient = dsce.getFlashFeeRecipient();
        assertEq(expectedFlashFeeRecipient, address(dsce));
    }

    function testGetFlashMinter() public view {
        address expectedFlashMinter = dsce.getFlashMinter();
        assertEq(expectedFlashMinter, address(flashMinter));
    }

    function testGetTokenDecimalsWeth() public view {
        assertEq(dsce.getTokenDecimals(weth), wethDecimals);
    }

    function testGetTokenDecimalsWbtc() public view {
        assertEq(dsce.getTokenDecimals(wbtc), wbtcDecimals);
    }

    function testGetFeedDecimalsWeth() public view {
        assertEq(dsce.getFeedDecimals(weth), feedDecimals);
    }

    function testGetFeedDecimalsWbtc() public view {
        assertEq(dsce.getFeedDecimals(wbtc), feedDecimals);
    }

    function testGetFlashFeeBpsDefaultIs0() public view {
        assertEq(dsce.getFlashFeeBps(), 0);
    }

    function testGetMinDebtThresholdDefaultIsZero() public view {
        assertEq(dsce.getMinDebtThreshold(weth), 0);
    }

    function testGetMaxPriceAgeReturnsConfiguredValues() public view {
        // These come from HelperConfig.activeNetworkConfig()
        assertEq(dsce.getMaxPriceAge(weth), wethMaxPriceAge);
        assertEq(dsce.getMaxPriceAge(wbtc), wbtcMaxPriceAge);
    }

    function testGettersReturnCorrectAddresses() public {
        assertEq(flashMinter.getDsce(), address(dsce));
        assertEq(flashMinter.getDsc(), address(dsc));
    }
}

