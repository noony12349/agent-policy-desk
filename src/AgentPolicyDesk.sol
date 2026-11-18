// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {SafeToken} from "./libraries/SafeToken.sol";

/// @title AgentPolicyDesk
/// @author Open-source Agent ID policy desk. Not affiliated with any exchange brand.
/// @notice 链上规则执行助手：持有 Agent ID 的地址写入交易限额，并把 USDT 存入该策略的托管。
///         只有绑定的执行者（也必须持有 Agent ID）能在规则内支取。
///         On-chain policy desk for Agent ID wallets. The owner escrows token units.
///         Only the bound executor can pull, and only inside the written limits.
///
/// @dev IMMUTABLE. No proxy, no contract owner, no admin, no rescue, no sweep.
///      Deploying this contract grants the deployer no power over user funds.
///
///      RISK / 风险
///      - USDT pulled by the executor leaves this contract immediately.
///      - Until that pull is repaid, the contract cannot recover it.
///      - `close` returns only the token still escrowed for that policy.
///      - A repay smaller than the outstanding pull realizes the difference as loss.
///      - One repay settles the whole outstanding pull. It is not a partial installment.
///      - Recorded volume is whatever the executor reports at repay time.
///        This contract does not see, and does not verify, off-chain or external trades.
///      - Token amounts are raw base units. The BSC USDT this project targets has 18 decimals.
///      - Sending tokens directly to this contract does not credit any policy and cannot be withdrawn.
///
///      PERMISSIONS / 权限（全部特权都在下面这些函数上，没有隐藏入口）
///      - createPolicy: any Agent ID holder. Binds an executor that also holds an Agent ID.
///      - deposit: policy owner only. Allowance must equal the deposit amount. Unlimited allowance is refused.
///      - pull: bound executor only, and only while the policy is open and inside the limits.
///      - repay: bound executor only. May be less than the pull. Allowed while paused, expired, or closed.
///      - pause / unpause / close: policy owner only. `close` pays remaining escrow to that owner, not to the deployer.
///
///      GLOBAL PAUSE: none. There is no third party who can freeze or move funds.
contract AgentPolicyDesk {
    enum Status {
        Active,
        Paused,
        Expired,
        Closed,
        Completed,
        LossLimit
    }

    /// @notice Limits are fixed at creation. Accounting fields start at zero and move only through this contract.
    struct Policy {
        address owner;
        address executor;
        uint256 maxPerTrade;
        uint256 volumeTarget;
        uint256 maxLoss;
        uint64 expiry;
        bool paused;
        bool closed;
        uint256 escrow;
        uint256 outstanding;
        uint256 realizedLoss;
        uint256 recordedVolume;
    }

    struct PolicyView {
        uint256 id;
        Policy policy;
        string ownerHandle;
        string executorHandle;
        Status status;
    }

    error ZeroAddress();
    error NotAContract(address account);
    error AgentIdRequired(address account);
    error PolicyNotFound(uint256 policyId);
    error MaxPerTradeZero();
    error VolumeTargetZero();
    error MaxLossZero();
    error ExpiryNotFuture();
    error NotOwner(address caller);
    error NotExecutor(address caller);
    error PolicyIsClosed(uint256 policyId);
    error PolicyIsPaused(uint256 policyId);
    error PolicyExpired(uint256 policyId);
    error PolicyCompleted(uint256 policyId);
    error LossLimitReached(uint256 policyId);
    error OutstandingExists(uint256 policyId);
    error NoOutstanding(uint256 policyId);
    error AmountZero();
    error ExceedsMaxPerTrade(uint256 amount, uint256 maxPerTrade);
    error ExceedsEscrow(uint256 amount, uint256 escrow);
    error ExceedsOutstanding(uint256 amount, uint256 outstanding);
    error ApprovalMustBeExact(uint256 allowance, uint256 amount);
    error UnexpectedTransferAmount(uint256 expected, uint256 actual);
    error DepositsClosed(uint256 policyId);
    error AlreadyPaused(uint256 policyId);
    error NotPaused(uint256 policyId);
    error Insolvency();
    error Reentrancy();
    error NativeNotAccepted();

    event PolicyCreated(
        uint256 indexed policyId,
        address indexed owner,
        address indexed executor,
        uint256 maxPerTrade,
        uint256 volumeTarget,
        uint256 maxLoss,
        uint64 expiry
    );

    event Deposited(uint256 indexed policyId, address indexed owner, uint256 amount, uint256 escrow);

    event Pulled(
        uint256 indexed policyId, address indexed executor, uint256 amount, uint256 escrow, uint256 outstanding
    );

    event Repaid(
        uint256 indexed policyId,
        address indexed executor,
        uint256 repayAmount,
        uint256 lossRealized,
        uint256 realizedLoss,
        uint256 recordedVolume,
        uint256 escrow,
        bool forwardedToOwner
    );

    event VolumeRecorded(
        uint256 indexed policyId, address indexed executor, uint256 volumeAdded, uint256 recordedVolume
    );

    event PolicyPaused(uint256 indexed policyId, address indexed owner);
    event PolicyUnpaused(uint256 indexed policyId, address indexed owner);

    /// @param returnedEscrow Token still in escrow and sent back to the owner.
    /// @param unrepaidOutstanding Token already pulled and not yet repaid. It is NOT sent anywhere by close.
    event PolicyClosed(
        uint256 indexed policyId, address indexed owner, uint256 returnedEscrow, uint256 unrepaidOutstanding
    );

    IAgentRegistry public immutable agentRegistry;
    IERC20Minimal public immutable usdt;

    /// @notice Sum of `Policy.escrow` across every policy. Direct token transfers are not included.
    uint256 public totalEscrow;

    uint256 public policyCount;

    mapping(uint256 id => Policy policy) private _policies;
    mapping(address owner => uint256[] ids) private _ownerPolicyIds;
    mapping(address executor => uint256[] ids) private _executorPolicyIds;

    uint256 private constant _UNLOCKED = 1;
    uint256 private constant _LOCKED = 2;
    uint256 private _lock = _UNLOCKED;

    modifier nonReentrant() {
        if (_lock != _UNLOCKED) revert Reentrancy();
        _lock = _LOCKED;
        _;
        _lock = _UNLOCKED;
    }

    /// @param agentRegistry_ Agent ID registry. On BSC this is the SPACE ID Agent ID contract.
    /// @param usdt_ Escrow token. On BSC this is USDT (18 decimals). Amounts are raw base units.
    constructor(address agentRegistry_, address usdt_) {
        if (agentRegistry_ == address(0) || usdt_ == address(0)) revert ZeroAddress();
        if (agentRegistry_.code.length == 0) revert NotAContract(agentRegistry_);
        if (usdt_.code.length == 0) revert NotAContract(usdt_);
        agentRegistry = IAgentRegistry(agentRegistry_);
        usdt = IERC20Minimal(usdt_);
    }

    /// @notice Create a policy. Caller and `executor` must each currently hold an Agent ID.
    /// @dev Owner and executor may be the same address. Parameters cannot be changed later.
    ///      `maxPerTrade`, `volumeTarget`, and `maxLoss` must be non-zero.
    ///      A zero max-loss would make every pull impossible under the `realizedLoss >= maxLoss` rule,
    ///      so it is rejected instead of creating a dead policy.
    /// @param executor The only address allowed to pull and repay. Must hold an Agent ID.
    /// @param maxPerTrade Maximum token that one pull may take.
    /// @param volumeTarget Once recorded volume reaches this, further pulls stop.
    /// @param maxLoss Once cumulative realized loss reaches this, further pulls stop.
    /// @param expiry Unix time at which pulls start failing. Must be in the future.
    function createPolicy(address executor, uint256 maxPerTrade, uint256 volumeTarget, uint256 maxLoss, uint64 expiry)
        external
        nonReentrant
        returns (uint256 policyId)
    {
        if (executor == address(0)) revert ZeroAddress();
        if (maxPerTrade == 0) revert MaxPerTradeZero();
        if (volumeTarget == 0) revert VolumeTargetZero();
        if (maxLoss == 0) revert MaxLossZero();
        if (expiry <= block.timestamp) revert ExpiryNotFuture();
        _requireAgent(msg.sender);
        _requireAgent(executor);

        policyId = ++policyCount;
        _policies[policyId] = Policy({
            owner: msg.sender,
            executor: executor,
            maxPerTrade: maxPerTrade,
            volumeTarget: volumeTarget,
            maxLoss: maxLoss,
            expiry: expiry,
            paused: false,
            closed: false,
            escrow: 0,
            outstanding: 0,
            realizedLoss: 0,
            recordedVolume: 0
        });
        _ownerPolicyIds[msg.sender].push(policyId);
        _executorPolicyIds[executor].push(policyId);

        emit PolicyCreated(policyId, msg.sender, executor, maxPerTrade, volumeTarget, maxLoss, expiry);
    }

    /// @notice Owner deposits escrow. The token allowance must equal `amount` exactly.
    /// @dev Unlimited approvals and any allowance other than `amount` revert. Nothing is pre-approved.
    ///      Deposits are refused once the policy is closed, expired, completed, or at the loss limit.
    ///      Deposits are allowed while paused, so the owner can fund a policy before unpausing it.
    function deposit(uint256 policyId, uint256 amount) external nonReentrant {
        Policy storage policy = _policy(policyId);
        if (msg.sender != policy.owner) revert NotOwner(msg.sender);
        if (amount == 0) revert AmountZero();
        if (!_depositsOpen(policy)) revert DepositsClosed(policyId);

        policy.escrow += amount;
        totalEscrow += amount;
        emit Deposited(policyId, msg.sender, amount, policy.escrow);
        _takeToken(msg.sender, amount);
        _assertSolvent();
    }

    /// @notice Executor pulls escrow. At most one pull may be outstanding.
    /// @dev Refuses paused, closed, expired, completed, and loss-limited policies.
    ///      `amount` must be non-zero, at most `maxPerTrade`, and at most current escrow.
    ///      Tokens are sent to the executor. They are no longer recoverable by `close` until repaid.
    function pull(uint256 policyId, uint256 amount) external nonReentrant {
        Policy storage policy = _policy(policyId);
        if (msg.sender != policy.executor) revert NotExecutor(msg.sender);
        if (policy.closed) revert PolicyIsClosed(policyId);
        if (policy.paused) revert PolicyIsPaused(policyId);
        if (block.timestamp >= policy.expiry) revert PolicyExpired(policyId);
        if (policy.recordedVolume >= policy.volumeTarget) revert PolicyCompleted(policyId);
        if (policy.realizedLoss >= policy.maxLoss) revert LossLimitReached(policyId);
        if (policy.outstanding != 0) revert OutstandingExists(policyId);
        if (amount == 0) revert AmountZero();
        if (amount > policy.maxPerTrade) revert ExceedsMaxPerTrade(amount, policy.maxPerTrade);
        if (amount > policy.escrow) revert ExceedsEscrow(amount, policy.escrow);

        policy.escrow -= amount;
        totalEscrow -= amount;
        policy.outstanding = amount;
        emit Pulled(policyId, msg.sender, amount, policy.escrow, policy.outstanding);
        _sendToken(msg.sender, amount);
        _assertSolvent();
    }

    /// @notice Executor settles the outstanding pull and optionally records volume.
    /// @dev `repayAmount` may be less than outstanding, including zero. The unpaid difference is
    ///      realized loss and the outstanding flag is cleared in this same call. A second repay
    ///      cannot pay the remainder later.
    ///      If the policy is still open, repaid tokens return to escrow.
    ///      If the policy is already closed, repaid tokens are forwarded to the owner.
    ///      They are not locked in a closed policy.
    ///      Repay is allowed while paused or expired so the executor can return funds.
    ///      `volumeAdded` is the executor's own report. It is not checked against an external venue.
    function repay(uint256 policyId, uint256 repayAmount, uint256 volumeAdded) external nonReentrant {
        Policy storage policy = _policy(policyId);
        if (msg.sender != policy.executor) revert NotExecutor(msg.sender);
        if (policy.outstanding == 0) revert NoOutstanding(policyId);
        if (repayAmount > policy.outstanding) revert ExceedsOutstanding(repayAmount, policy.outstanding);

        uint256 loss = policy.outstanding - repayAmount;
        bool closed = policy.closed;

        policy.outstanding = 0;
        policy.realizedLoss += loss;
        policy.recordedVolume += volumeAdded;
        if (!closed && repayAmount > 0) {
            policy.escrow += repayAmount;
            totalEscrow += repayAmount;
        }

        emit Repaid(
            policyId, msg.sender, repayAmount, loss, policy.realizedLoss, policy.recordedVolume, policy.escrow, closed
        );
        if (volumeAdded > 0) {
            emit VolumeRecorded(policyId, msg.sender, volumeAdded, policy.recordedVolume);
        }

        if (repayAmount > 0) {
            _takeToken(msg.sender, repayAmount);
            if (closed) {
                _sendToken(policy.owner, repayAmount);
            }
        }
        _assertSolvent();
    }

    /// @notice Owner pauses pulls. Escrow does not move. Repay stays available.
    function pause(uint256 policyId) external nonReentrant {
        Policy storage policy = _policy(policyId);
        if (msg.sender != policy.owner) revert NotOwner(msg.sender);
        if (policy.closed) revert PolicyIsClosed(policyId);
        if (policy.paused) revert AlreadyPaused(policyId);
        policy.paused = true;
        emit PolicyPaused(policyId, msg.sender);
    }

    /// @notice Owner unpauses pulls. Other limits (expiry, loss, volume, outstanding) still apply.
    function unpause(uint256 policyId) external nonReentrant {
        Policy storage policy = _policy(policyId);
        if (msg.sender != policy.owner) revert NotOwner(msg.sender);
        if (policy.closed) revert PolicyIsClosed(policyId);
        if (!policy.paused) revert NotPaused(policyId);
        policy.paused = false;
        emit PolicyUnpaused(policyId, msg.sender);
    }

    /// @notice Owner closes the policy and receives only the token still in escrow.
    /// @dev Funds already pulled and not repaid stay with the executor. This function cannot claw them back.
    ///      The contract deployer does not receive the refund. The policy owner does.
    ///      Close is allowed while paused and while a pull is outstanding.
    function close(uint256 policyId) external nonReentrant {
        Policy storage policy = _policy(policyId);
        if (msg.sender != policy.owner) revert NotOwner(msg.sender);
        if (policy.closed) revert PolicyIsClosed(policyId);

        uint256 refund = policy.escrow;
        uint256 unrepaid = policy.outstanding;
        policy.closed = true;
        policy.escrow = 0;
        totalEscrow -= refund;
        emit PolicyClosed(policyId, policy.owner, refund, unrepaid);

        if (refund > 0) {
            _sendToken(policy.owner, refund);
        }
        _assertSolvent();
    }

    /// @notice Policy plus both parties' Agent ID handles. Handles are display data, not the access check.
    /// @dev A missing or reverting `handleOf` becomes an empty string. Access control uses `balanceOf` at creation.
    function getPolicy(uint256 policyId) external view returns (PolicyView memory viewData) {
        Policy storage stored = _policy(policyId);
        Policy memory policy = stored;
        viewData = PolicyView({
            id: policyId,
            policy: policy,
            ownerHandle: _handleOf(policy.owner),
            executorHandle: _handleOf(policy.executor),
            status: _status(policy)
        });
    }

    /// @notice Policy ids created by `owner`, oldest first. Closed policies remain in the list.
    function ownerPolicyIds(address owner) external view returns (uint256[] memory) {
        return _ownerPolicyIds[owner];
    }

    /// @notice Policy ids bound to `executor`, oldest first.
    function executorPolicyIds(address executor) external view returns (uint256[] memory) {
        return _executorPolicyIds[executor];
    }

    receive() external payable {
        revert NativeNotAccepted();
    }

    fallback() external payable {
        revert NativeNotAccepted();
    }

    function _requireAgent(address account) internal view {
        if (agentRegistry.balanceOf(account) == 0) revert AgentIdRequired(account);
    }

    function _policy(uint256 policyId) internal view returns (Policy storage policy) {
        policy = _policies[policyId];
        if (policy.owner == address(0)) revert PolicyNotFound(policyId);
    }

    function _depositsOpen(Policy storage policy) internal view returns (bool) {
        if (policy.closed) return false;
        if (block.timestamp >= policy.expiry) return false;
        if (policy.recordedVolume >= policy.volumeTarget) return false;
        if (policy.realizedLoss >= policy.maxLoss) return false;
        return true;
    }

    /// @dev Priority: closed, then volume target, then loss limit, then expiry, then pause.
    function _status(Policy memory policy) internal view returns (Status) {
        if (policy.closed) return Status.Closed;
        if (policy.recordedVolume >= policy.volumeTarget) return Status.Completed;
        if (policy.realizedLoss >= policy.maxLoss) return Status.LossLimit;
        if (block.timestamp >= policy.expiry) return Status.Expired;
        if (policy.paused) return Status.Paused;
        return Status.Active;
    }

    function _handleOf(address account) internal view returns (string memory) {
        try agentRegistry.handleOf(account) returns (string memory handle) {
            return handle;
        } catch {
            return "";
        }
    }

    /// @dev Allowance must be exactly `amount`. `type(uint256).max` is always refused.
    ///      The token balance must increase by `amount`. Fee-on-transfer tokens revert.
    function _takeToken(address from, uint256 amount) internal {
        uint256 allowance = usdt.allowance(from, address(this));
        if (allowance != amount || allowance == type(uint256).max) {
            revert ApprovalMustBeExact(allowance, amount);
        }
        uint256 beforeBal = usdt.balanceOf(address(this));
        SafeToken.safeTransferFrom(usdt, from, address(this), amount);
        uint256 received = usdt.balanceOf(address(this)) - beforeBal;
        if (received != amount) revert UnexpectedTransferAmount(amount, received);
    }

    function _sendToken(address to, uint256 amount) internal {
        uint256 beforeBal = usdt.balanceOf(address(this));
        SafeToken.safeTransfer(usdt, to, amount);
        uint256 sent = beforeBal - usdt.balanceOf(address(this));
        if (sent != amount) revert UnexpectedTransferAmount(amount, sent);
    }

    function _assertSolvent() internal view {
        if (usdt.balanceOf(address(this)) < totalEscrow) revert Insolvency();
    }
}
