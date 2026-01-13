// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DSCEngine } from "../../src/DSCEngine.sol";
import { DWebThreePavlouStableCoin } from "../../src/DWebThreePavlouStableCoin.sol";
import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFlashBorrowerRejectsWrongToken is IERC3156FlashBorrower {
    bool private _called;
    address public tokenReceived;
    uint256 public amountReceived;
    uint256 public feeReceived;
    bytes public dataReceived;

    uint256 public balanceInsideCallback;
    bool public receivedBeforeCallback;

    address public initiatorReceived;

    address public expectedToken;

    constructor(
        address _expectedToken
    ) {
        expectedToken = _expectedToken;
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        initiatorReceived = initiator;

        _called = true;
        tokenReceived = token;
        amountReceived = amount;
        feeReceived = fee;
        dataReceived = data;

        // observe balance during callback
        balanceInsideCallback = IERC20(token).balanceOf(address(this));

        receivedBeforeCallback = balanceInsideCallback >= amount;

        // Approve caller (FlashMint contract) to pull amount + fee
        IERC20(token).approve(msg.sender, amount + fee);
        // Malicious lender sends a wrong token
        require(token == expectedToken, "Received wrong token!");
        return keccak256("IERC3156FlashBorrower.onFlashLoan");
    }

    function called() external view returns (bool) {
        return _called;
    }
}
