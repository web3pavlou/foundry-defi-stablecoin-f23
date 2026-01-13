// SPDX-License-Identifier:MIT
pragma solidity ^0.8.18;

import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockBadFlashBorrower is IERC3156FlashBorrower {
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

        // observe balance during callback
        balanceInsideCallback = IERC20(token).balanceOf(address(this));

        receivedBeforeCallback = balanceInsideCallback >= amount;

        //  Borrower does not approve caller (FlashMint contract) to pull amount + fee
        IERC20(token).approve(msg.sender, amount + fee);

        // Borrower does not return the hash
        return keccak256("Wrong");
    }

    function called() external view returns (bool) {
        return _called;
    }
}
