//SPDX-License-Identifier:MIT

pragma solidity ^0.8.29;

import { ERC20Burnable, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DWebThreePavlouSC
 * @author web3pavlou
 * Collateral: Exogenous(ETH & BTC).
 * Minting: Algorithmic.
 * Relative Stability: Pegged To USD.
 * Only the DSCEngine (as owner) and an optional flash minter contract are authorized to mint/burn.
 *  This contract is just  the ERC20 implementation of our stablecoin system
 * @dev Decimals for tokens and feeds are stored to handle price conversions accurately.
 */
contract DWebThreePavlouStableCoin is ERC20Burnable, Ownable {
    error DWebThreePavlouSC__MustBeMoreThanZero();
    error DWebThreePavlouSC__BurnAmountExceedsBalance();
    error DWebThreePavlouSC__NotZeroAddress();
    error DWebThreePavlouSC__BlockFunction();
    error DWebThreePavlouSC__NotAuthorized();

    address public minter;

    ////////////////////
    /// events        //
    ////////////////////
    event MinterSet(address indexed oldMinter, address indexed newMinter);

    ////////////////////
    /// Modifiers     //
    ////////////////////
    modifier onlyMinterOrOwner() {
        if (msg.sender != owner() && msg.sender != minter) revert DWebThreePavlouSC__NotAuthorized();
        _;
    }

    /**
     * @dev Sets the initial owner of the contract to the address provided
     */
    constructor(
        address owner
    ) ERC20("DWebThreePavlouSC", "DWTPSC") Ownable(owner) { }

    function burn(
        uint256 _amount
    ) public override onlyMinterOrOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DWebThreePavlouSC__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DWebThreePavlouSC__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function burnFrom(
        address,
        uint256
    ) public pure override {
        revert DWebThreePavlouSC__BlockFunction();
    }

    function mint(
        address _to,
        uint256 _amount
    ) external onlyMinterOrOwner returns (bool) {
        if (_to == address(0)) {
            revert DWebThreePavlouSC__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DWebThreePavlouSC__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }

    /// @notice Sets a new authorized minter address for the stablecoin.
    function setMinter(
        address _minter
    ) external onlyOwner {
        emit MinterSet(minter, _minter);
        minter = _minter;
    }
}
