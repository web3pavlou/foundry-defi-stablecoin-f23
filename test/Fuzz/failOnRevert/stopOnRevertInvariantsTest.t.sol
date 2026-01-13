//SPDX-License-Identifier:MIT

//Have our invariants aka properties

//What are our Invariants??

//1.The total supply of DSC(the debt) minted must be less than the total value of collateral

//2.getter-view functions should never revert-evergreen invariant!!!!

pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { DSCEngine } from "../../../src/DSCEngine.sol";
import { DWebThreePavlouStableCoin } from "../../../src/DWebThreePavlouStableCoin.sol";
import { DeployDSC } from "../../../script/DeployDSC.s.sol";
import { HelperConfig } from "../../../script/HelperConfig.s.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { StopOnRevertHandler } from "./stopOnRevertHandler.t.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { FlashMintDWebThreePavlou } from "../../../src/FlashMintDWebThreePavlou.sol";
import { console2 } from "forge-std/console2.sol";
import { MockV3Aggregator } from "../../Mocks/MockV3Aggregator.sol";

contract StopOnRevertInvariants is StdInvariant, Test {
    DSCEngine public dsce;
    DWebThreePavlouStableCoin public dsc;
    HelperConfig public helperConfig;
    FlashMintDWebThreePavlou flashMinter;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 deployerKey;
    uint256 public wethMaxPriceAge;
    uint256 public wbtcMaxPriceAge;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    address public constant USER = address(1);
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    StopOnRevertHandler public handler;

    function setUp() external {
        DeployDSC deployer = new DeployDSC();
        (dsc, dsce, helperConfig, flashMinter) = deployer.run();

        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey, wethMaxPriceAge, wbtcMaxPriceAge) =
            helperConfig.activeNetworkConfig();

        handler = new StopOnRevertHandler(dsce, dsc);
        targetContract(address(handler));

        targetSender(makeAddr("actor1"));
        targetSender(makeAddr("actor2"));
        targetSender(makeAddr("actor3"));
        targetSender(makeAddr("actor4"));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.mintAndDepositCollateral.selector;
        selectors[1] = handler.mintDsc.selector;
        selectors[2] = handler.burnDsc.selector;
        selectors[3] = handler.redeemCollateral.selector;
        selectors[4] = handler.transferDsc.selector;
        selectors[5] = handler.liquidate.selector;
        // selectors[6] = handler.updateCollateralPrice.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    // This doesn't hold if oracle comes into play
    function invariant_protocolMustHaveMoreValueThatTotalSupplyDollars() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 wethDeposited = ERC20Mock(weth).balanceOf(address(dsce));
        uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, wethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, wbtcDeposited);

        console2.log("wethValue: ", wethValue);
        console2.log("wbtcValue: ", wbtcValue);
        console2.log("totalSupply: ", totalSupply);
        (, int256 ethPrice,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        (, int256 btcPrice,,,) = MockV3Aggregator(btcUsdPriceFeed).latestRoundData();
        console2.log("ethPrice", uint256(ethPrice));
        console2.log("btcPrice", uint256(btcPrice));

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersCantRevert() external view {
        dsce.getCollateralTokens();
        dsce.getLiquidationBonus();
        dsce.getLiquidationThreshold();
        dsce.getLiquidationPrecision();
        dsce.getMinHealthFactor();
        dsce.getMinPositionValueUsd();
        dsce.getPrecision();
        dsce.getDsc();
        dsce.getFlashMinter();
    }
}
