// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFlashBorrowerLiesAboutTheAmount is IERC3156FlashBorrower {
    bool private _called;
    address public tokenReceived;
    uint256 public amountReceived;
    uint256 public feeReceived;
    bytes public dataReceived;

    uint256 public balanceInsideCallback;
    bool public receivedBeforeCallback;

    address public initiatorReceived;

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

        // Observe balance during callback
        balanceInsideCallback = IERC20(token).balanceOf(address(this));
        receivedBeforeCallback = balanceInsideCallback >= amount;

        // Mint or assume the borrower already has less than required
        // Intentionally underpay: totalRepay - 1 wei
        uint256 fakeRepayment = amount + fee - 1;

        // Approve the full expected amount (so ERC20 approve does not fail)
        IERC20(token).approve(msg.sender, amount + fee);

        // Actually transfer less than required to FlashMint contract
        IERC20(token).transfer(msg.sender, fakeRepayment);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function called() external view returns (bool) {
        return _called;
    }
}
