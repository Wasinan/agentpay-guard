// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockTUSD8
/// @notice LOCAL-TESTING ONLY. A minimal 6-decimal ERC-20 that mimics the
///         challenge's tUSD8 stablecoin for anvil / forge-test runs.
///
///         NEVER deploy this to Aevum testnet: the real tUSD8 is already
///         deployed at 0x456569838f1d43009A91ebA4263147Afd7233483 and the
///         Aevum deploy script takes that address as a parameter instead.
///
///         Deliberately dependency-free and minimal: balances, allowances,
///         transfers, and an open `mint` so local demos can fund accounts.
///         It implements only the ERC-20 surface AgentVault and the tests
///         rely on.
contract MockTUSD8 {
    string public constant name = "Mock tUSD8 (LOCAL TEST ONLY)";
    string public constant symbol = "tUSD8";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    error InsufficientBalance(uint256 requested, uint256 available);
    error InsufficientAllowance(uint256 requested, uint256 available);
    error ZeroAddress();

    /// @notice Mint `amount` (in 6-decimal units) to `to`. Open to anyone:
    ///         this token is worthless outside a local test chain.
    function mint(address to, uint256 amount) external {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (amount > allowed) revert InsufficientAllowance(amount, allowed);
        allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (amount > fromBalance) revert InsufficientBalance(amount, fromBalance);
        balanceOf[from] = fromBalance - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
