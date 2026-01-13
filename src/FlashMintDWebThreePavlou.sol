// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC3156FlashBorrower, IERC3156FlashLender } from "@openzeppelin/contracts/interfaces/IERC3156.sol";
import { DWebThreePavlouStableCoin } from "./DWebThreePavlouStableCoin.sol";
import { DSCEngine } from "./DSCEngine.sol";

contract FlashMintDWebThreePavlou is ReentrancyGuard, IERC3156FlashLender {
    ///////////////
    // libraries //
    ///////////////
    using SafeERC20 for IERC20;

    ////////////
    // errors //
    ////////////
    error FlashMint__ZeroAddress();
    error FlashMint__BadToken();
    error FlashMint__MoreThanZero();
    error FlashMint__AmountTooLarge();
    error FlashMint__CallbackFailed();
    error FlashMint__BadFeeRecipient();
    error FlashMint__MintFailed();

    /////////////////
    //  immutables //
    /////////////////
    DWebThreePavlouStableCoin private immutable i_dsc;
    DSCEngine private immutable i_dsce;

    //  ERC3156 callback success value (OpenZeppelin style)
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    ////////////
    // events //
    ////////////

    event FlashMinterDeployed(address engine, address token);

    event FlashLoanExecuted(address indexed initiator, address indexed receiver, address indexed token, uint256 amount, uint256 fee, address feeRecipient);

    constructor(
        address _dscEngine,
        address _dscToken
    ) {
        if (_dscEngine == address(0) || _dscToken == address(0)) revert FlashMint__ZeroAddress();
        i_dsce = DSCEngine(_dscEngine);
        i_dsc = DWebThreePavlouStableCoin(_dscToken);

        emit FlashMinterDeployed(_dscEngine, _dscToken);
    }

    //////////////////////////////////////
    // IERC3156 external view functions //
    //////////////////////////////////////

    function maxFlashLoan(
        address token
    ) external view override returns (uint256) {
        if (token != address(i_dsc)) return 0;
        // DSCEngine is the risk manager
        return i_dsce.maxFlashLoan(token);
    }

    function flashFee(
        address token,
        uint256 amount
    ) external view override returns (uint256) {
        if (token != address(i_dsc)) revert FlashMint__BadToken();
        if (amount == 0) return 0;
        return i_dsce.flashFee(token, amount);
    }

    ///////////////////////
    // IERC3156 Lender   //
    ///////////////////////

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override nonReentrant returns (bool) {
        if (token != address(i_dsc)) revert FlashMint__BadToken();
        if (amount == 0) revert FlashMint__MoreThanZero();

        uint256 maxLoan = i_dsce.maxFlashLoan(token);
        if (amount > maxLoan) revert FlashMint__AmountTooLarge();

        uint256 fee = i_dsce.flashFee(token, amount);
        address feeRecipient = i_dsce.getFlashFeeRecipient();
        if (feeRecipient == address(0)) revert FlashMint__BadFeeRecipient();

        // 1) Mint principal to borrower
        bool ok = i_dsc.mint(address(receiver), amount);
        if (!ok) revert FlashMint__MintFailed();

        // 2) Callback
        // initiator = msg.sender (caller of flashLoan), lender = this contract (msg.sender inside callback)
        bytes32 callback = receiver.onFlashLoan(msg.sender, token, amount, fee, data);
        if (callback != CALLBACK_SUCCESS) revert FlashMint__CallbackFailed();

        // 3) Pull repayment to THIS contract
        uint256 totalRepay = amount + fee;
        IERC20(token).safeTransferFrom(address(receiver), address(this), totalRepay);

        // 4) Burn principal from THIS contract (we hold it now)
        i_dsc.burn(amount);

        // 5) Forward fee to Engine (or configured recipient)
        if (fee > 0) {
            IERC20(token).safeTransfer(feeRecipient, fee);
        }

        emit FlashLoanExecuted(msg.sender, address(receiver), token, amount, fee, feeRecipient);
        return true;
    }

    //////////////
    // getters  //
    //////////////

    function getDsce() external view returns (address) {
        return address(i_dsce);
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }
}
