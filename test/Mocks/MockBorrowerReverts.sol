// SPDX-License-Identifier:MIT
pragma solidity ^0.8.18;

import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockBorrowerReverts is IERC3156FlashBorrower {
    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external pure returns (bytes32) {
        revert("I break");
    }
}
