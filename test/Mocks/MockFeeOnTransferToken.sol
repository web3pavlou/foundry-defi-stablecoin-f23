//SPDX-License-Identifier:MIT

pragma solidity 0.8.29;

contract MockFeeOnTransferToken {
    string public name = "FeeOnTransfer";
    string public symbol = "FOT";
    uint8 public immutable decimals;

    uint256 public immutable feeBps; // e.g. 1000 = 10%
    address public immutable feeRecipient;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(
        uint8 _decimals,
        uint256 _feeBps,
        address _feeRecipient
    ) {
        decimals = _decimals;
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        balanceOf[to] += amount;
    }

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;

        _transfer(from, to, amount);
        return true;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;

        uint256 fee = (amount * feeBps) / 10_000;
        uint256 net = amount - fee;

        if (net > 0) balanceOf[to] += net;
        if (fee > 0) balanceOf[feeRecipient] += fee;
    }
}
