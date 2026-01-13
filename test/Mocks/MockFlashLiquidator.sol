//SPDX-License-Identifier:MIT
pragma solidity ^0.8.29;

import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { FlashMintDWebThreePavlou } from "../../src/FlashMintDWebThreePavlou.sol";
import { DSCEngine } from "../../src/DSCEngine.sol";
import { MockDex } from "./MockDex.sol";

contract MockFlashLiquidator is IERC3156FlashBorrower {
    DSCEngine public dsce;
    FlashMintDWebThreePavlou public lender;
    IERC20 public dsc;
    IERC20 public weth;
    MockDex public dex;
    address public victim;

    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    constructor(
        address _dsce,
        address _lender,
        address _dsc,
        address _weth,
        address _dex,
        address _victim
    ) {
        dsce = DSCEngine(_dsce);
        lender = FlashMintDWebThreePavlou(_lender);
        dsc = IERC20(_dsc);
        weth = IERC20(_weth);
        dex = MockDex(_dex);
        victim = _victim;
    }

    function onFlashLoan(
        address, /* initiator */
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata /* data */
    ) external returns (bytes32) {
        require(msg.sender == address(lender), "only lender");
        require(token == address(dsc), "bad token");

        // 1) Liquidate using flash-minted DSC
        dsc.approve(address(dsce), amount);
        dsce.liquidate(address(weth), victim, amount);

        // 2) Swap seized WETH -> DSC to repay amount+fee
        uint256 repay = amount + fee;
        uint256 dscPerWeth = dex.dscPerWeth();

        // wethIn = ceil(repay * 1e18 / dscPerWeth)
        uint256 wethIn = (repay * 1e18 + dscPerWeth - 1) / dscPerWeth;

        require(weth.balanceOf(address(this)) >= wethIn, "not enough WETH seized");

        weth.approve(address(dex), wethIn);
        dex.swapWethForDsc(wethIn, address(this));

        // 3) Approve lender pull
        dsc.approve(address(lender), repay);

        return CALLBACK_SUCCESS;
    }
}
