// SPDX-License-Identifier:MIT
pragma solidity ^0.8.18;

import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFlashBorrowerLiesAboutTheFee is IERC3156FlashBorrower {
    bool private _called;
    address public tokenReceived;
    uint256 public amountReceived;
    uint256 public feeReceived;
    bytes public dataReceived;

    uint256 public balanceInsideCallback;
    bool public receivedBeforeCallback;

    address public initiatorReceived;

    /// @dev the standard ERC3156 callback success value
    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @notice Called by the flash lender during the flash loan flow.
    /// Reverts if the fee passed is not what the borrower expects.
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
        // Borrower *pretends* fee is smaller
        uint256 fakeFee = fee / 2; // malicious!

        // Approve lender only for (amount + fakeFee)
        IERC20(token).approve(msg.sender, amount + fakeFee);

        // Return normal success selector — so DSCEngine proceeds to repayment
        return CALLBACK_SUCCESS;
    }

    function called() external view returns (bool) {
        return _called;
    }
}
