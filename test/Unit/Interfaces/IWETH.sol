// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IWETH Interface
/// @notice Minimal interface for interacting with Wrapped Ether (WETH9)
/// @dev Used in testing and scripting to wrap/unwrap ETH
interface IWETH {
    /// @notice Deposit ETH and receive WETH
    /// @dev The amount of WETH minted equals msg.value
    function deposit() external payable;

    /// @notice Withdraw ETH by burning WETH
    /// @param wad The amount of WETH to unwrap into ETH
    function withdraw(uint256 wad) external;

    /// @notice Transfer WETH tokens
    /// @param to The recipient address
    /// @param value The amount to transfer
    /// @return success Whether the transfer succeeded
    function transfer(address to, uint256 value) external returns (bool);

    /// @notice Approve another address to spend WETH on your behalf
    /// @param spender The approved spender
    /// @param value The amount approved
    /// @return success Whether the approval succeeded
    function approve(address spender, uint256 value) external returns (bool);

    /// @notice Check the WETH balance of an address
    /// @param owner The account to query
    /// @return balance The WETH balance
    function balanceOf(address owner) external view returns (uint256);

    /// @notice Check the allowance of a spender for a given owner
    /// @param owner The owner of the WETH tokens
    /// @param spender The spender
    /// @return remaining The remaining allowance
    function allowance(address owner, address spender) external view returns (uint256);
}
