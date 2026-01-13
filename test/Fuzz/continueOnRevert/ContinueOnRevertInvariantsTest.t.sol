//SPDX-License-Identifier:MIT
pragma solidity ^0.8.29;

// Invariants in this suite are "technical/accounting" invariants.
// /// forge-config: default.invariant.fail-on-revert = false

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import "forge-std/console2.sol";
import { DSCEngine } from "../../../src/DSCEngine.sol";
import { DWebThreePavlouStableCoin } from "../../../src/DWebThreePavlouStableCoin.sol";
import { DeployDSC } from "../../../script/DeployDSC.s.sol";
import { HelperConfig } from "../../../script/HelperConfig.s.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { FlashMintDWebThreePavlou } from "../../../src/FlashMintDWebThreePavlou.sol";
import { ContinueOnRevertHandler } from "./ContinueOnRevertHandler.t.sol";

contract ContinueOnRevertInvariants is StdInvariant, Test {
    DSCEngine public dsce;
    DWebThreePavlouStableCoin public dsc;
    HelperConfig public helperConfig;
    FlashMintDWebThreePavlou public flashMinter;

    address public weth;
    address public wbtc;

    ContinueOnRevertHandler public handler;

    function setUp() external {
        DeployDSC deployer = new DeployDSC();
        (dsc, dsce, helperConfig, flashMinter) = deployer.run();

        (,, weth, wbtc,,,) = helperConfig.activeNetworkConfig();

        handler = new ContinueOnRevertHandler(dsce, dsc);

        targetContract(address(handler));

        // Make senders explicit
        targetSender(makeAddr("actor1"));
        targetSender(makeAddr("actor2"));
        targetSender(makeAddr("actor3"));
        targetSender(makeAddr("actor4"));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.mintAndDepositCollateral.selector;
        selectors[1] = handler.mintDsc.selector;
        selectors[2] = handler.burnDsc.selector;
        selectors[3] = handler.redeemCollateral.selector;
        selectors[4] = handler.transferDsc.selector;
        selectors[5] = handler.liquidate.selector;
        selectors[6] = handler.updateCollateralPrice.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    // Core invariants

    /// Engine ERC20 balances should equal sum of tracked deposits over actors.
    function _engineBalancesMatchTrackedDeposits() internal view {
        address[] memory tokens = dsce.getCollateralTokens();

        uint256 len = handler.actorLength();

        for (uint256 t = 0; t < tokens.length; t++) {
            address token = tokens[t];

            uint256 engineBal = IERC20(token).balanceOf(address(dsce));
            uint256 sum;

            for (uint256 i = 0; i < len; i++) {
                address a = handler.actorAt(i);
                sum += dsce.getCollateralBalanceOfUser(a, token);
            }

            assertEq(engineBal, sum);
        }
    }

    /// Total supply should equal sum of minted debt tracked by the handler (mint/burn only).
    /// (Transfers don’t affect totalSupply.)
    function _totalSupplyEqualsSumTrackedDebt() internal view {
        uint256 len = handler.actorLength();
        uint256 sumDebt;

        for (uint256 i = 0; i < len; i++) {
            address a = handler.actorAt(i);
            sumDebt += handler.trackedDebt(a);
        }

        assertEq(dsc.totalSupply(), sumDebt);
    }

    /// Mint should never *succeed* and end with HF < minHF.
    function _userCantCreateStablecoinWithPoorHealthFactor() internal view {
        assertFalse(handler.mintedWithPoorHealthFactor());
    }

    /// If liquidation succeeds and HF is measurable before/after, HF must improve.
    function _liquidationsImproveHfWhenTheySucceed() internal view {
        assertFalse(handler.liquidationDidNotImproveHf());
    }

    function invariant_all() public view {
        _liquidationsImproveHfWhenTheySucceed();
        _userCantCreateStablecoinWithPoorHealthFactor();
        _totalSupplyEqualsSumTrackedDebt();
        _engineBalancesMatchTrackedDeposits();
    }

    // function afterInvariant() public view {
    //     console2.log("actors", handler.actorLength());
    //     console2.log("mintSuccessCount", handler.mintSuccessCount());
    //     console2.log("liquidationSuccessCount", handler.liquidationSuccessCount());
    //     console2.log("totalSupply", dsc.totalSupply());
    //     console2.log("wethEngineBal", IERC20(weth).balanceOf(address(dsce)));
    //     console2.log("wbtcEngineBal", IERC20(wbtc).balanceOf(address(dsce)));
    // }
}
