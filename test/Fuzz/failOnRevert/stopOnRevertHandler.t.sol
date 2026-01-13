//SPDX-License-Identifier:MIT

pragma solidity ^0.8.29;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Test } from "forge-std/Test.sol";
import { DSCEngine } from "../../../src/DSCEngine.sol";
import { DWebThreePavlouStableCoin } from "../../../src/DWebThreePavlouStableCoin.sol";
import { DeployDSC } from "../../../script/DeployDSC.s.sol";
import { HelperConfig } from "../../../script/HelperConfig.s.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { MockV3Aggregator } from "../../Mocks/MockV3Aggregator.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console2 } from "forge-std/console2.sol";

contract StopOnRevertHandler is Test {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Deployed contracts to interact with
    DSCEngine public dscEngine;
    DWebThreePavlouStableCoin public dsc;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;
    ERC20Mock public weth;
    ERC20Mock public wbtc;

    // Ghost Variables
    uint256 public constant MAX_WHOLE_TOKENS = 1_000_000; //1 M units max
    EnumerableSet.AddressSet private s_actors;
    uint256 public maxTotalSupplySeen;
    bool public mintedWithPoorHealthFactor;
    uint256 public mintSuccessCount;

    constructor(
        DSCEngine _dscEngine,
        DWebThreePavlouStableCoin _dsc
    ) {
        dscEngine = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(wbtc)));
    }

    ///////////////////
    // Actor Helpers //
    ///////////////////
    function actorLength() external view returns (uint256) {
        return s_actors.length();
    }

    function actorAt(
        uint256 index
    ) external view returns (address) {
        return s_actors.at(index); // Reverts if out of bounds
    }

    function _addActor(
        address actor
    ) internal {
        if (actor != address(0)) s_actors.add(actor);
    }

    function _pickActor(
        uint256 actorSeed
    ) internal view returns (address) {
        uint256 len = s_actors.length();
        if (len == 0) return address(0);
        return s_actors.at(actorSeed % len);
    }

    function _pickVictimNotSelf(
        uint256 actorSeed,
        address self
    ) internal view returns (address) {
        uint256 len = s_actors.length();
        if (len == 0) return address(0);

        uint256 idx = actorSeed % len;
        address victim = s_actors.at(idx);

        if (victim == self) {
            if (len == 1) return address(0);
            idx = (idx + 1) % len; // idx < len, so idx+1 cannot overflow
            victim = s_actors.at(idx);
        }

        return victim;
    }

    ///////////////////////
    /// Helper Functions //
    ///////////////////////
    function _getCollateralFromSeed(
        uint256 collateralSeed
    ) private view returns (ERC20Mock) {
        return (collateralSeed % 2 == 0) ? weth : wbtc;
    }

    function _maxTokenAmount(
        address token
    ) internal view returns (uint256) {
        uint8 dec = dscEngine.getTokenDecimals(token);
        return MAX_WHOLE_TOKENS * (10 ** uint256(dec));
    }

    function _maxPriceAnswer(
        address token
    ) internal view returns (uint256) {
        uint8 fDec = dscEngine.getFeedDecimals(token);
        uint256 scale = 10 ** uint256(fDec);
        return 1_000_000 * scale;
    }

    function _victimIsLiquidatable(
        uint256 debt,
        uint256 collUsd
    ) internal view returns (bool) {
        if (debt == 0) return false;

        uint256 hf = dscEngine.calculateHealthFactor(debt, collUsd);
        if (hf >= dscEngine.getMinHealthFactor()) return false;

        // Avoid DSCEngine__HealthFactorNotImproved in normal cases:
        // require enough system-level cushion to pay bonus.
        uint256 bonus = dscEngine.getLiquidationBonus();
        uint256 prec = dscEngine.getLiquidationPrecision();
        uint256 minCollForBonusModel = (debt * (prec + bonus)) / prec; // ~debt * 1.1
        if (collUsd <= minCollForBonusModel) return false;

        return true;
    }

    function _adjustDebtToAvoidDust(
        address collateral,
        uint256 victimDebt,
        uint256 debtToCover,
        uint256 maxDebt
    ) internal view returns (uint256) {
        uint256 minDebtThreshold = dscEngine.getMinDebtThreshold(collateral);
        if (minDebtThreshold == 0) return debtToCover;

        uint256 remaining = victimDebt - debtToCover;
        if (remaining > 0 && remaining < minDebtThreshold) {
            // Prefer "leave exactly minDebtThreshold" if possible, else full clear.
            uint256 adjusted = victimDebt > minDebtThreshold ? (victimDebt - minDebtThreshold) : victimDebt;
            if (adjusted == 0 || adjusted > maxDebt) return 0;
            return adjusted;
        }
        return debtToCover;
    }

    function _canSeizeFullBonus(
        address collateral,
        uint256 victimTokenBal,
        uint256 debtToCover
    ) internal view returns (bool) {
        uint256 baseTokens = dscEngine.getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonus = dscEngine.getLiquidationBonus();
        uint256 prec = dscEngine.getLiquidationPrecision();

        uint256 totalTokens = baseTokens + ((baseTokens * bonus) / prec);
        if (totalTokens > victimTokenBal) return false; // avoid bonus-reduction branch

        // Avoid DSCEngine's "cap debt to positionValueUsd" path for this collateral
        if (debtToCover > dscEngine.getUsdValue(collateral, victimTokenBal)) return false;

        return true;
    }

    // FUNCTIONS TO INTERACT WITH

    ///////////////
    // DSCEngine //
    ///////////////
    function mintAndDepositCollateral(
        uint256 collateralSeed,
        uint256 amountCollateral
    ) public {
        _addActor(msg.sender);
        // must be more than 0
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxAmount = _maxTokenAmount(address(collateral));

        uint256 minUsd = dscEngine.getMinPositionValueUsd();
        uint256 minAmount = dscEngine.getTokenAmountFromUsd(address(collateral), minUsd);

        // deposit at least minAmount so mintDsc can actually happen
        amountCollateral = _bound(amountCollateral, minAmount, maxAmount);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function mintDsc(
        uint256 amountDscToMint
    ) public {
        _addActor(msg.sender);

        // pick someone who actually exists in the system
        address actor = _pickActor(uint256(uint160(msg.sender)));
        if (actor == address(0)) return;

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(actor);
        uint256 minPosition = dscEngine.getMinPositionValueUsd();
        if (collateralValueInUsd < minPosition) return;

        uint256 threshold = dscEngine.getLiquidationThreshold();
        uint256 liquidationPrecision = dscEngine.getLiquidationPrecision();
        uint256 maxDebt = (collateralValueInUsd * threshold) / liquidationPrecision;
        if (totalDscMinted >= maxDebt) return;

        uint256 maxAdditional = maxDebt - totalDscMinted;
        if (maxAdditional == 0) return;

        amountDscToMint = _bound(amountDscToMint, 1, maxAdditional);

        vm.prank(actor);
        dscEngine.mintDsc(amountDscToMint);

        uint256 ts = dsc.totalSupply();
        maxTotalSupplySeen = (ts > maxTotalSupplySeen) ? ts : maxTotalSupplySeen;
    }

    function redeemCollateral(
        uint256 collateralSeed,
        uint256 amountCollateral
    ) public {
        _addActor(msg.sender);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateral = dscEngine.getCollateralBalanceOfUser(msg.sender, address(collateral));

        amountCollateral = _bound(amountCollateral, 0, maxCollateral);
        //vm.prank(msg.sender);
        if (amountCollateral == 0) {
            return;
        }

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(msg.sender);
        if (totalDscMinted > 0) {
            uint256 redeemUsd = dscEngine.getUsdValue(address(collateral), amountCollateral);
            uint256 newCollateralUsd = redeemUsd >= collateralValueInUsd ? 0 : (collateralValueInUsd - redeemUsd);
            uint256 newHf = dscEngine.calculateHealthFactor(totalDscMinted, newCollateralUsd);
            uint256 minHf = dscEngine.getMinHealthFactor();
            if (newHf < minHf) return;
        }

        vm.prank(msg.sender);
        dscEngine.redeemCollateral(address(collateral), amountCollateral);
    }

    function burnDsc(
        uint256 amountDsc
    ) public {
        _addActor(msg.sender);

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(msg.sender);
        uint256 bal = dsc.balanceOf(msg.sender);

        //  must not exceed minted debt, even if user received DSC via transfers
        uint256 maxBurn = totalDscMinted < bal ? totalDscMinted : bal;
        amountDsc = _bound(amountDsc, 0, maxBurn);
        if (amountDsc == 0) {
            return;
        }
        vm.startPrank(msg.sender);
        dsc.approve(address(dscEngine), amountDsc);
        dscEngine.burnDsc(amountDsc);
        vm.stopPrank();
    }

    function liquidate(
        uint256 collateralSeed,
        uint256 victimSeed,
        uint256 debtToCover
    ) public {
        _addActor(msg.sender);

        address victim = _pickVictimNotSelf(victimSeed, msg.sender);
        if (victim == address(0)) return;

        address collateral = address(_getCollateralFromSeed(collateralSeed));

        (uint256 victimDebt, uint256 victimCollUsd) = dscEngine.getAccountInformation(victim);
        if (!_victimIsLiquidatable(victimDebt, victimCollUsd)) return;

        uint256 liquidatorBal = dsc.balanceOf(msg.sender);
        if (liquidatorBal == 0) return;

        uint256 maxDebt = victimDebt < liquidatorBal ? victimDebt : liquidatorBal;
        if (maxDebt == 0) return;

        debtToCover = _bound(debtToCover, 1, maxDebt);

        debtToCover = _adjustDebtToAvoidDust(collateral, victimDebt, debtToCover, maxDebt);
        if (debtToCover == 0) return;

        uint256 victimTokenBal = dscEngine.getCollateralBalanceOfUser(victim, collateral);
        if (victimTokenBal == 0) return;

        if (!_canSeizeFullBonus(collateral, victimTokenBal, debtToCover)) return;

        vm.startPrank(msg.sender);
        dsc.approve(address(dscEngine), debtToCover);
        dscEngine.liquidate(collateral, victim, debtToCover);
        vm.stopPrank();
    }

    /////////////////////////////
    // DecentralizedStableCoin //
    /////////////////////////////
    function transferDsc(
        uint256 amountDsc,
        address to
    ) public {
        _addActor(msg.sender);
        if (to == address(0)) to = address(1);
        _addActor(to);
        if (to == address(0)) {
            to = address(1);
        }
        amountDsc = _bound(amountDsc, 0, dsc.balanceOf(msg.sender));
        vm.prank(msg.sender);
        dsc.transfer(to, amountDsc);
    }

    /////////////////////////////
    // Aggregator //
    /////////////////////////////
    function updateCollateralPrice(
        uint96 newPriceUsd,
        uint256 collateralSeed
    ) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        MockV3Aggregator feed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(collateral)));

        uint8 fDec = dscEngine.getFeedDecimals(address(collateral));

        (, int256 curr,,,) = feed.latestRoundData();
        uint256 currAnswer = uint256(curr);

        // still use fuzz input, but convert to answer-scale
        uint256 candidateUsd = uint256(_bound(uint256(newPriceUsd), 1, 1_000_000));
        uint256 candidateAnswer = candidateUsd * (10 ** uint256(fDec));

        // limit step change
        uint256 minAnswer = (currAnswer * 80) / 100; // -20%
        uint256 maxAnswer = (currAnswer * 120) / 100; // +20%

        uint256 nextAnswer = _bound(candidateAnswer, minAnswer, maxAnswer);
        feed.updateAnswer(int256(nextAnswer));
    }
}
