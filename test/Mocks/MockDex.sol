// SPDX-License-Identifier:MIT

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity ^0.8.29;

contract MockDex {
    using SafeERC20 for IERC20;

    IERC20 public immutable WETH;
    IERC20 public immutable DSC;

    // out = wethIn * dscPerWeth / 1e18
    uint256 public immutable dscPerWeth;

    constructor(address weth, address dsc, uint256 _dscPerWeth) {
        WETH = IERC20(weth);
        DSC = IERC20(dsc);
        dscPerWeth = _dscPerWeth;
    }

    function swapWethForDsc(uint256 wethIn, address recipient) external returns (uint256 out) {
        WETH.safeTransferFrom(msg.sender, address(this), wethIn);
        out = (wethIn * dscPerWeth) / 1e18;
        DSC.safeTransfer(recipient, out);
    }
}
