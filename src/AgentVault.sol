// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AgentVault
/// @notice A personal stablecoin vault that lets its owner grant a scoped,
///         revocable spending session to an AI agent — and enforces the
///         guardrails on-chain, so the agent can never exceed them.
///
///         The owner deposits tUSD8, then creates a session for one agent
///         address with four hard limits:
///           1. a total spending cap for the whole session,
///           2. a per-payment cap for any single payment,
///           3. an expiry timestamp after which the session is dead,
///           4. an allowlist of recipient addresses (nothing else can be paid).
///
///         The agent may only call `executePayment`, and only within those
///         limits. Every action emits an event, forming a permanent,
///         verifiable audit trail. The owner can revoke a session instantly
///         and withdraw any remaining balance at any time.
///
///         This contract holds no privileged upgrade path and no admin key
///         beyond the owner: the guardrails are the code, not a promise.
interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract AgentVault {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotOwner();
    error NotSessionAgent();
    error SessionNotFound();
    error SessionIsRevoked();
    error SessionExpired();
    error ExceedsPerTxCap(uint256 amount, uint256 perTxCap);
    error ExceedsSessionCap(uint256 requested, uint256 remaining);
    error RecipientNotAllowed(address recipient);
    error InsufficientVaultBalance(uint256 requested, uint256 available);
    error InvalidExpiry();
    error InvalidCap();
    error EmptyAllowlist();
    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();

    // ---------------------------------------------------------------------
    // Events — the on-chain audit trail
    // ---------------------------------------------------------------------

    event Deposited(address indexed from, uint256 amount, uint256 vaultBalanceAfter);
    event Withdrawn(address indexed to, uint256 amount, uint256 vaultBalanceAfter);
    event SessionCreated(
        uint256 indexed sessionId,
        address indexed agent,
        uint256 cap,
        uint256 perTxCap,
        uint256 expiry,
        address[] recipients
    );
    event SessionRevoked(uint256 indexed sessionId, address indexed agent);
    event PaymentExecuted(
        uint256 indexed sessionId,
        address indexed agent,
        address indexed to,
        uint256 amount,
        string memo,
        uint256 sessionSpentAfter
    );

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    struct Session {
        address agent;
        uint256 cap; // total spend allowed over the session lifetime
        uint256 perTxCap; // max amount of any single payment
        uint256 expiry; // unix timestamp; payments after this revert
        uint256 spent; // cumulative amount paid under this session
        bool revoked;
        address[] recipients; // allowlist, kept for enumeration / UI
    }

    IERC20Minimal public immutable token;
    address public immutable owner;

    Session[] private _sessions;

    /// @dev sessionId => recipient => allowed. O(1) allowlist check.
    mapping(uint256 => mapping(address => bool)) private _allowed;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(address token_) {
        if (token_ == address(0)) revert ZeroAddress();
        token = IERC20Minimal(token_);
        owner = msg.sender;
    }

    // ---------------------------------------------------------------------
    // Funding
    // ---------------------------------------------------------------------

    /// @notice Deposit `amount` of the vault token. Caller must have
    ///         approved the vault first. Anyone may fund the vault; only the
    ///         owner may withdraw or grant sessions.
    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit Deposited(msg.sender, amount, token.balanceOf(address(this)));
    }

    /// @notice Withdraw `amount` back to the owner. Unspent session caps do
    ///         not lock funds: the owner can always pull the balance out.
    function withdraw(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = token.balanceOf(address(this));
        if (amount > balance) revert InsufficientVaultBalance(amount, balance);
        if (!token.transfer(owner, amount)) revert TransferFailed();
        emit Withdrawn(owner, amount, token.balanceOf(address(this)));
    }

    // ---------------------------------------------------------------------
    // Sessions
    // ---------------------------------------------------------------------

    /// @notice Grant a scoped spending session to `agent`.
    /// @param cap Total amount the agent may spend across the session.
    /// @param perTxCap Maximum amount of any single payment (must be <= cap).
    /// @param expiry Unix timestamp after which the session stops working.
    /// @param recipients Allowlist of addresses the agent may pay.
    /// @return sessionId The id of the newly created session.
    function createSession(address agent, uint256 cap, uint256 perTxCap, uint256 expiry, address[] calldata recipients)
        external
        onlyOwner
        returns (uint256 sessionId)
    {
        if (agent == address(0)) revert ZeroAddress();
        if (cap == 0 || perTxCap == 0 || perTxCap > cap) revert InvalidCap();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (recipients.length == 0) revert EmptyAllowlist();

        sessionId = _sessions.length;
        _sessions.push(
            Session({
                agent: agent,
                cap: cap,
                perTxCap: perTxCap,
                expiry: expiry,
                spent: 0,
                revoked: false,
                recipients: recipients
            })
        );
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            _allowed[sessionId][recipients[i]] = true;
        }

        emit SessionCreated(sessionId, agent, cap, perTxCap, expiry, recipients);
    }

    /// @notice Instantly kill a session. Irreversible; create a new session
    ///         to grant access again. Any in-flight payment after revocation
    ///         reverts.
    function revokeSession(uint256 sessionId) external onlyOwner {
        Session storage session = _getSession(sessionId);
        session.revoked = true;
        emit SessionRevoked(sessionId, session.agent);
    }

    // ---------------------------------------------------------------------
    // Agent payments — every guardrail is checked here, on-chain.
    // ---------------------------------------------------------------------

    /// @notice Pay `amount` to `to` from the vault under `sessionId`.
    ///         Callable only by the session's agent, and only while every
    ///         guardrail holds: not revoked, not expired, recipient
    ///         allowlisted, within per-payment cap, within total cap, and
    ///         the vault is funded.
    /// @param memo Human-readable note recorded in the audit trail (e.g.
    ///        an invoice id). Stored in the event, not in contract storage.
    function executePayment(uint256 sessionId, address to, uint256 amount, string calldata memo) external {
        Session storage session = _getSession(sessionId);

        if (msg.sender != session.agent) revert NotSessionAgent();
        if (session.revoked) revert SessionIsRevoked();
        if (block.timestamp > session.expiry) revert SessionExpired();
        if (amount == 0) revert ZeroAmount();
        if (!_allowed[sessionId][to]) revert RecipientNotAllowed(to);
        if (amount > session.perTxCap) revert ExceedsPerTxCap(amount, session.perTxCap);

        uint256 remaining = session.cap - session.spent;
        if (amount > remaining) revert ExceedsSessionCap(amount, remaining);

        uint256 balance = token.balanceOf(address(this));
        if (amount > balance) revert InsufficientVaultBalance(amount, balance);

        // Checks complete: update state before the external call.
        session.spent += amount;
        if (!token.transfer(to, amount)) revert TransferFailed();

        emit PaymentExecuted(sessionId, msg.sender, to, amount, memo, session.spent);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function sessionCount() external view returns (uint256) {
        return _sessions.length;
    }

    function getSession(uint256 sessionId)
        external
        view
        returns (
            address agent,
            uint256 cap,
            uint256 perTxCap,
            uint256 expiry,
            uint256 spent,
            bool revoked,
            address[] memory recipients
        )
    {
        Session storage session = _getSession(sessionId);
        return (
            session.agent,
            session.cap,
            session.perTxCap,
            session.expiry,
            session.spent,
            session.revoked,
            session.recipients
        );
    }

    function isRecipientAllowed(uint256 sessionId, address recipient) external view returns (bool) {
        _getSession(sessionId); // reverts on unknown session
        return _allowed[sessionId][recipient];
    }

    /// @notice Spendable amount left under a session (cap minus spent).
    ///         Returns 0 for revoked or expired sessions.
    function remainingCap(uint256 sessionId) external view returns (uint256) {
        Session storage session = _getSession(sessionId);
        if (session.revoked || block.timestamp > session.expiry) return 0;
        return session.cap - session.spent;
    }

    function vaultBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _getSession(uint256 sessionId) internal view returns (Session storage) {
        if (sessionId >= _sessions.length) revert SessionNotFound();
        return _sessions[sessionId];
    }
}
