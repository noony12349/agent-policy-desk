// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentPolicyDesk} from "../src/AgentPolicyDesk.sol";
import {SafeToken} from "../src/libraries/SafeToken.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {MockUSDT, SilentUSDT, FalseUSDT, FeeUSDT} from "./mocks/MockUSDT.sol";

interface IAttacker {
    function onTokenHook() external;
}

/// @dev Credits tokens, then calls the attacker. Swallows the inner revert so a missing
///      reentrancy guard would be visible as corrupted accounting instead of a bubbled revert.
contract HookUSDT is MockUSDT {
    address public hook;
    bool public armed;
    bool public innerSucceeded;

    function arm(address hook_) external {
        hook = hook_;
        armed = true;
        innerSucceeded = false;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (armed) {
            armed = false;
            try IAttacker(hook).onTokenHook() {
                innerSucceeded = true;
            } catch {
                innerSucceeded = false;
            }
        }
        return true;
    }
}

contract EvilExecutor {
    AgentPolicyDesk public desk;
    HookUSDT public token;
    uint256 public attackId;
    uint256 public attackAmount;

    constructor(AgentPolicyDesk desk_, HookUSDT token_) {
        desk = desk_;
        token = token_;
    }

    function approve(uint256 amount) external {
        token.approve(address(desk), amount);
    }

    function pull(uint256 id, uint256 amount) external {
        desk.pull(id, amount);
    }

    function repay(uint256 id, uint256 amount, uint256 volume) external {
        desk.repay(id, amount, volume);
    }

    function setAttack(uint256 id, uint256 amount) external {
        attackId = id;
        attackAmount = amount;
    }

    function onTokenHook() external {
        desk.pull(attackId, attackAmount);
    }
}

contract AgentPolicyDeskTest is Test {
    MockAgentRegistry internal registry;
    MockUSDT internal usdt;
    AgentPolicyDesk internal desk;

    address internal owner;
    address internal executor;
    address internal stranger;

    uint256 internal constant MAX_PER_TRADE = 100 ether;
    uint256 internal constant VOLUME_TARGET = 1000 ether;
    uint256 internal constant MAX_LOSS = 50 ether;
    uint256 internal constant START = 1_000_000 ether;

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
    event PolicyClosed(
        uint256 indexed policyId, address indexed owner, uint256 returnedEscrow, uint256 unrepaidOutstanding
    );

    function setUp() public {
        registry = new MockAgentRegistry();
        usdt = new MockUSDT();
        desk = new AgentPolicyDesk(address(registry), address(usdt));

        owner = makeAddr("owner");
        executor = makeAddr("executor");
        stranger = makeAddr("stranger");

        registry.setAgent(owner, "880");
        registry.setAgent(executor, "executor880");
        usdt.mint(owner, START);
        usdt.mint(executor, START);
    }

    function test_happyPath_createDepositPullRepay() public {
        uint256 ownerBefore = usdt.balanceOf(owner);
        uint256 executorBefore = usdt.balanceOf(executor);
        uint256 id = _createDefault();

        AgentPolicyDesk.PolicyView memory viewData = desk.getPolicy(id);
        assertEq(viewData.ownerHandle, "880");
        assertEq(viewData.executorHandle, "executor880");
        assertEq(uint8(viewData.status), uint8(AgentPolicyDesk.Status.Active));
        assertEq(desk.ownerPolicyIds(owner)[0], id);
        assertEq(desk.executorPolicyIds(executor)[0], id);
        assertEq(desk.policyCount(), 1);

        _deposit(id, 200 ether);
        assertEq(usdt.allowance(owner, address(desk)), 0);

        vm.prank(executor);
        desk.pull(id, 40 ether);

        _approve(executor, 40 ether);
        vm.prank(executor);
        desk.repay(id, 40 ether, 40 ether);

        AgentPolicyDesk.Policy memory policy = desk.getPolicy(id).policy;
        assertEq(policy.escrow, 200 ether);
        assertEq(policy.outstanding, 0);
        assertEq(policy.realizedLoss, 0);
        assertEq(policy.recordedVolume, 40 ether);
        assertEq(usdt.balanceOf(address(desk)), 200 ether);
        assertEq(desk.totalEscrow(), 200 ether);
        assertEq(usdt.balanceOf(owner), ownerBefore - 200 ether);
        assertEq(usdt.balanceOf(executor), executorBefore);
        assertEq(uint8(desk.getPolicy(id).status), uint8(AgentPolicyDesk.Status.Active));
    }

    function test_eventsCoverLifecycle() public {
        uint64 expiry = _expiry();

        vm.expectEmit(true, true, true, true, address(desk));
        emit PolicyCreated(1, owner, executor, MAX_PER_TRADE, VOLUME_TARGET, MAX_LOSS, expiry);
        vm.prank(owner);
        uint256 id = desk.createPolicy(executor, MAX_PER_TRADE, VOLUME_TARGET, MAX_LOSS, expiry);

        _approve(owner, 100 ether);
        vm.expectEmit(true, true, false, true, address(desk));
        emit Deposited(id, owner, 100 ether, 100 ether);
        vm.prank(owner);
        desk.deposit(id, 100 ether);

        vm.expectEmit(true, true, false, true, address(desk));
        emit Pulled(id, executor, 40 ether, 60 ether, 40 ether);
        vm.prank(executor);
        desk.pull(id, 40 ether);

        _approve(executor, 25 ether);
        vm.expectEmit(true, true, false, true, address(desk));
        emit Repaid(id, executor, 25 ether, 15 ether, 15 ether, 10 ether, 85 ether, false);
        vm.expectEmit(true, true, false, true, address(desk));
        emit VolumeRecorded(id, executor, 10 ether, 10 ether);
        vm.prank(executor);
        desk.repay(id, 25 ether, 10 ether);

        vm.expectEmit(true, true, false, true, address(desk));
        emit PolicyPaused(id, owner);
        vm.prank(owner);
        desk.pause(id);

        vm.expectEmit(true, true, false, true, address(desk));
        emit PolicyUnpaused(id, owner);
        vm.prank(owner);
        desk.unpause(id);

        vm.expectEmit(true, true, false, true, address(desk));
        emit PolicyClosed(id, owner, 85 ether, 0);
        vm.prank(owner);
        desk.close(id);
    }

    function test_revert_createWithoutAgentId() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.AgentIdRequired.selector, stranger));
        desk.createPolicy(executor, 1 ether, 1 ether, 1 ether, _expiry());
    }

    function test_revert_executorWithoutAgentId() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.AgentIdRequired.selector, stranger));
        desk.createPolicy(stranger, 1 ether, 1 ether, 1 ether, _expiry());
    }

    function test_createRejectsBadParams() public {
        vm.startPrank(owner);
        vm.expectRevert(AgentPolicyDesk.ZeroAddress.selector);
        desk.createPolicy(address(0), 1 ether, 1 ether, 1 ether, _expiry());
        vm.expectRevert(AgentPolicyDesk.MaxPerTradeZero.selector);
        desk.createPolicy(executor, 0, 1 ether, 1 ether, _expiry());
        vm.expectRevert(AgentPolicyDesk.VolumeTargetZero.selector);
        desk.createPolicy(executor, 1 ether, 0, 1 ether, _expiry());
        vm.expectRevert(AgentPolicyDesk.MaxLossZero.selector);
        desk.createPolicy(executor, 1 ether, 1 ether, 0, _expiry());
        vm.expectRevert(AgentPolicyDesk.ExpiryNotFuture.selector);
        desk.createPolicy(executor, 1 ether, 1 ether, 1 ether, uint64(block.timestamp));
        vm.stopPrank();
    }

    function test_getPolicyReturnsHandlesAndMissingIdReverts() public {
        uint256 id = _createDefault();
        assertEq(desk.getPolicy(id).ownerHandle, "880");
        assertEq(desk.getPolicy(id).executorHandle, "executor880");

        registry.revoke(owner);
        assertEq(desk.getPolicy(id).ownerHandle, "");

        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.PolicyNotFound.selector, 0));
        desk.getPolicy(0);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.PolicyNotFound.selector, 2));
        desk.getPolicy(2);
    }

    function test_revert_pullAboveMaxPerTrade() public {
        uint256 id = _createDefault();
        _deposit(id, 200 ether);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.ExceedsMaxPerTrade.selector, 100 ether + 1, 100 ether));
        desk.pull(id, 100 ether + 1);

        vm.prank(executor);
        desk.pull(id, 100 ether);
        assertEq(desk.getPolicy(id).policy.outstanding, 100 ether);
    }

    function test_revert_pullAboveEscrow() public {
        uint256 id = _createDefault();
        _deposit(id, 20 ether);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.ExceedsEscrow.selector, 21 ether, 20 ether));
        desk.pull(id, 21 ether);
    }

    function test_revert_secondPullWhileOutstanding() public {
        uint256 id = _createDefault();
        _deposit(id, 100 ether);
        vm.prank(executor);
        desk.pull(id, 10 ether);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.OutstandingExists.selector, id));
        desk.pull(id, 1 ether);
        assertEq(desk.getPolicy(id).policy.outstanding, 10 ether);
        assertEq(desk.getPolicy(id).policy.escrow, 90 ether);
    }

    function test_partialRepayRealizesLossAndAllowsAnotherPull() public {
        uint256 id = _createDefault();
        _deposit(id, 100 ether);
        vm.prank(executor);
        desk.pull(id, 40 ether);

        _approve(executor, 25 ether);
        vm.prank(executor);
        desk.repay(id, 25 ether, 10 ether);

        AgentPolicyDesk.Policy memory policy = desk.getPolicy(id).policy;
        assertEq(policy.outstanding, 0);
        assertEq(policy.realizedLoss, 15 ether);
        assertEq(policy.recordedVolume, 10 ether);
        assertEq(policy.escrow, 85 ether);
        assertEq(usdt.balanceOf(address(desk)), 85 ether);

        vm.prank(executor);
        desk.pull(id, 10 ether);
        assertEq(desk.getPolicy(id).policy.outstanding, 10 ether);
    }

    function test_repayZeroRealizesFullLoss() public {
        uint256 id = _createDefault();
        _deposit(id, 80 ether);
        vm.prank(executor);
        desk.pull(id, 30 ether);
        vm.prank(executor);
        desk.repay(id, 0, 0);
        assertEq(desk.getPolicy(id).policy.realizedLoss, 30 ether);
        assertEq(desk.getPolicy(id).policy.outstanding, 0);
        assertEq(desk.getPolicy(id).policy.escrow, 50 ether);
        assertEq(usdt.balanceOf(executor), START + 30 ether);
    }

    function test_revert_pullAfterMaxLoss() public {
        uint256 id = _createDefault();
        _deposit(id, 200 ether);

        vm.prank(executor);
        desk.pull(id, 49 ether);
        vm.prank(executor);
        desk.repay(id, 0, 0);
        assertEq(desk.getPolicy(id).policy.realizedLoss, 49 ether);

        vm.prank(executor);
        desk.pull(id, 10 ether);
        vm.prank(executor);
        desk.repay(id, 0, 0);
        assertEq(desk.getPolicy(id).policy.realizedLoss, 59 ether);
        assertEq(uint8(desk.getPolicy(id).status), uint8(AgentPolicyDesk.Status.LossLimit));

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.LossLimitReached.selector, id));
        desk.pull(id, 1 ether);
    }

    function test_revert_pullAfterExpiry() public {
        uint64 expiry = uint64(block.timestamp + 100);
        vm.prank(owner);
        uint256 id = desk.createPolicy(executor, MAX_PER_TRADE, VOLUME_TARGET, MAX_LOSS, expiry);
        _deposit(id, 100 ether);

        vm.warp(expiry - 1);
        vm.prank(executor);
        desk.pull(id, 10 ether);
        _approve(executor, 10 ether);
        vm.prank(executor);
        desk.repay(id, 10 ether, 0);

        vm.warp(expiry);
        assertEq(uint8(desk.getPolicy(id).status), uint8(AgentPolicyDesk.Status.Expired));
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.PolicyExpired.selector, id));
        desk.pull(id, 10 ether);
    }

    function test_revert_pullAfterClose() public {
        uint256 id = _createDefault();
        _deposit(id, 30 ether);
        vm.prank(owner);
        desk.close(id);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.PolicyIsClosed.selector, id));
        desk.pull(id, 1 ether);
    }

    function test_revert_pullAfterPause_thenUnpauseAllowsPull() public {
        uint256 id = _createDefault();
        _deposit(id, 30 ether);
        vm.prank(owner);
        desk.pause(id);
        assertEq(uint8(desk.getPolicy(id).status), uint8(AgentPolicyDesk.Status.Paused));

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.PolicyIsPaused.selector, id));
        desk.pull(id, 10 ether);

        vm.prank(owner);
        desk.unpause(id);
        vm.prank(executor);
        desk.pull(id, 10 ether);
        assertEq(desk.getPolicy(id).policy.outstanding, 10 ether);
    }

    function test_repayWhilePausedStillWorks() public {
        uint256 id = _createDefault();
        _deposit(id, 40 ether);
        vm.prank(executor);
        desk.pull(id, 15 ether);
        vm.prank(owner);
        desk.pause(id);

        _approve(executor, 15 ether);
        vm.prank(executor);
        desk.repay(id, 15 ether, 4 ether);
        assertEq(desk.getPolicy(id).policy.escrow, 40 ether);
        assertEq(desk.getPolicy(id).policy.outstanding, 0);
        assertTrue(desk.getPolicy(id).policy.paused);
    }

    function test_revert_onlyOwnerCanPauseAndClose() public {
        uint256 id = _createDefault();
        _deposit(id, 20 ether);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.NotOwner.selector, executor));
        desk.pause(id);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.NotOwner.selector, stranger));
        desk.pause(id);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.NotOwner.selector, executor));
        desk.close(id);

        vm.prank(owner);
        desk.pause(id);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.AlreadyPaused.selector, id));
        desk.pause(id);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.NotOwner.selector, executor));
        desk.unpause(id);
        vm.prank(owner);
        desk.unpause(id);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.NotPaused.selector, id));
        desk.unpause(id);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.NotOwner.selector, stranger));
        desk.deposit(id, 1 ether);

        vm.prank(owner);
        desk.close(id);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.PolicyIsClosed.selector, id));
        desk.pause(id);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.PolicyIsClosed.selector, id));
        desk.close(id);
    }

    function test_revert_onlyExecutorCanPullAndRepay() public {
        uint256 id = _createDefault();
        _deposit(id, 40 ether);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.NoOutstanding.selector, id));
        desk.repay(id, 0, 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.NotExecutor.selector, owner));
        desk.pull(id, 10 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.NotExecutor.selector, stranger));
        desk.pull(id, 10 ether);

        vm.prank(executor);
        desk.pull(id, 10 ether);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.NotExecutor.selector, owner));
        desk.repay(id, 10 ether, 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.NotExecutor.selector, stranger));
        desk.repay(id, 10 ether, 0);

        _approve(executor, 10 ether);
        vm.prank(executor);
        desk.repay(id, 10 ether, 0);
    }

    function test_closeReturnsRemainingEscrow() public {
        uint256 id = _createDefault();
        uint256 ownerBefore = usdt.balanceOf(owner);
        _deposit(id, 200 ether);

        vm.prank(executor);
        desk.pull(id, 40 ether);

        uint256 ownerMid = usdt.balanceOf(owner);
        vm.prank(owner);
        desk.close(id);

        assertEq(usdt.balanceOf(owner), ownerMid + 160 ether);
        assertEq(usdt.balanceOf(owner), ownerBefore - 40 ether);
        assertEq(usdt.balanceOf(executor), START + 40 ether);
        assertEq(usdt.balanceOf(address(desk)), 0);
        assertEq(desk.totalEscrow(), 0);
        assertEq(desk.getPolicy(id).policy.escrow, 0);
        assertEq(desk.getPolicy(id).policy.outstanding, 40 ether);
        assertEq(uint8(desk.getPolicy(id).status), uint8(AgentPolicyDesk.Status.Closed));
    }

    function test_closeWithNoPullRefundsAll() public {
        uint256 id = _createDefault();
        uint256 ownerBefore = usdt.balanceOf(owner);
        _deposit(id, 80 ether);
        vm.prank(owner);
        desk.close(id);
        assertEq(usdt.balanceOf(owner), ownerBefore);
        assertEq(usdt.balanceOf(address(desk)), 0);
        assertEq(desk.getPolicy(id).policy.outstanding, 0);
    }

    function test_repayForwardsToOwnerAfterClose() public {
        uint256 id = _createDefault();
        _deposit(id, 200 ether);
        vm.prank(executor);
        desk.pull(id, 40 ether);
        vm.prank(owner);
        desk.close(id);

        uint256 ownerAfterClose = usdt.balanceOf(owner);
        _approve(executor, 25 ether);
        vm.expectEmit(true, true, false, true, address(desk));
        emit Repaid(id, executor, 25 ether, 15 ether, 15 ether, 0, 0, true);
        vm.prank(executor);
        desk.repay(id, 25 ether, 0);

        assertEq(usdt.balanceOf(owner), ownerAfterClose + 25 ether);
        assertEq(usdt.balanceOf(address(desk)), 0);
        assertEq(desk.totalEscrow(), 0);
        assertEq(desk.getPolicy(id).policy.outstanding, 0);
        assertEq(desk.getPolicy(id).policy.realizedLoss, 15 ether);
        assertEq(usdt.balanceOf(executor), START + 15 ether);
    }

    function test_approvalMustBeExactAndLeavesNoStandingAllowance() public {
        uint256 id = _createDefault();

        vm.prank(owner);
        usdt.approve(address(desk), type(uint256).max);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(AgentPolicyDesk.ApprovalMustBeExact.selector, type(uint256).max, 10 ether)
        );
        desk.deposit(id, 10 ether);

        vm.prank(owner);
        usdt.approve(address(desk), 11 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.ApprovalMustBeExact.selector, 11 ether, 10 ether));
        desk.deposit(id, 10 ether);

        vm.prank(owner);
        usdt.approve(address(desk), 9 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.ApprovalMustBeExact.selector, 9 ether, 10 ether));
        desk.deposit(id, 10 ether);
        assertEq(usdt.balanceOf(address(desk)), 0);
        assertEq(desk.getPolicy(id).policy.escrow, 0);

        _approve(owner, 10 ether);
        vm.prank(owner);
        desk.deposit(id, 10 ether);
        assertEq(usdt.allowance(owner, address(desk)), 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.ApprovalMustBeExact.selector, 0, 1 ether));
        desk.deposit(id, 1 ether);
    }

    function test_repayRejectsUnlimitedApproval() public {
        uint256 id = _createDefault();
        _deposit(id, 40 ether);
        vm.prank(executor);
        desk.pull(id, 40 ether);
        vm.prank(executor);
        usdt.approve(address(desk), type(uint256).max);
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(AgentPolicyDesk.ApprovalMustBeExact.selector, type(uint256).max, 40 ether)
        );
        desk.repay(id, 40 ether, 0);
        assertEq(desk.getPolicy(id).policy.outstanding, 40 ether);
        assertEq(usdt.balanceOf(address(desk)), 0);
    }

    function test_repayAboveOutstandingReverts() public {
        uint256 id = _createDefault();
        _deposit(id, 40 ether);
        vm.prank(executor);
        desk.pull(id, 10 ether);
        _approve(executor, 11 ether);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.ExceedsOutstanding.selector, 11 ether, 10 ether));
        desk.repay(id, 11 ether, 0);
        assertEq(desk.getPolicy(id).policy.outstanding, 10 ether);
    }

    function test_volumeTargetBlocksPull() public {
        uint256 id = _createDefault();
        _deposit(id, 200 ether);

        vm.prank(executor);
        desk.pull(id, 10 ether);
        _approve(executor, 10 ether);
        vm.prank(executor);
        desk.repay(id, 10 ether, VOLUME_TARGET - 1);
        assertEq(uint8(desk.getPolicy(id).status), uint8(AgentPolicyDesk.Status.Active));

        vm.prank(executor);
        desk.pull(id, 10 ether);
        _approve(executor, 10 ether);
        vm.prank(executor);
        desk.repay(id, 10 ether, 1);
        assertEq(desk.getPolicy(id).policy.recordedVolume, VOLUME_TARGET);
        assertEq(uint8(desk.getPolicy(id).status), uint8(AgentPolicyDesk.Status.Completed));

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.PolicyCompleted.selector, id));
        desk.pull(id, 10 ether);
    }

    function test_depositWhilePausedAndClosedWhenTerminal() public {
        uint256 pausedId = _createDefault();
        vm.prank(owner);
        desk.pause(pausedId);
        _deposit(pausedId, 5 ether);
        assertEq(desk.getPolicy(pausedId).policy.escrow, 5 ether);

        uint64 expiry = uint64(block.timestamp + 50);
        vm.prank(owner);
        uint256 expiredId = desk.createPolicy(executor, MAX_PER_TRADE, VOLUME_TARGET, MAX_LOSS, expiry);
        vm.warp(expiry);
        _approve(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.DepositsClosed.selector, expiredId));
        desk.deposit(expiredId, 1 ether);

        vm.warp(block.timestamp + 1);
        uint256 lossId = _createDefault();
        _deposit(lossId, 50 ether);
        vm.prank(executor);
        desk.pull(lossId, 50 ether);
        vm.prank(executor);
        desk.repay(lossId, 0, 0);
        _approve(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.DepositsClosed.selector, lossId));
        desk.deposit(lossId, 1 ether);

        uint256 doneId = _createDefault();
        _deposit(doneId, 10 ether);
        vm.prank(executor);
        desk.pull(doneId, 10 ether);
        _approve(executor, 10 ether);
        vm.prank(executor);
        desk.repay(doneId, 10 ether, VOLUME_TARGET);
        _approve(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.DepositsClosed.selector, doneId));
        desk.deposit(doneId, 1 ether);

        vm.prank(owner);
        desk.close(pausedId);
        _approve(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.DepositsClosed.selector, pausedId));
        desk.deposit(pausedId, 1 ether);
    }

    function test_policiesAreIsolated() public {
        uint256 first = _createDefault();
        vm.prank(owner);
        uint256 second = desk.createPolicy(executor, MAX_PER_TRADE, VOLUME_TARGET, MAX_LOSS, _expiry());
        _deposit(first, 100 ether);
        _deposit(second, 10 ether);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.ExceedsEscrow.selector, 11 ether, 10 ether));
        desk.pull(second, 11 ether);

        vm.prank(executor);
        desk.pull(second, 10 ether);
        assertEq(desk.getPolicy(first).policy.escrow, 100 ether);
        assertEq(desk.getPolicy(second).policy.escrow, 0);
        assertEq(desk.totalEscrow(), 100 ether);
        assertEq(usdt.balanceOf(address(desk)), 100 ether);
    }

    function test_sameAccountCanBeOwnerAndExecutor() public {
        vm.prank(owner);
        uint256 id = desk.createPolicy(owner, MAX_PER_TRADE, VOLUME_TARGET, MAX_LOSS, _expiry());
        _deposit(id, 20 ether);
        vm.prank(owner);
        desk.pull(id, 10 ether);
        _approve(owner, 10 ether);
        vm.prank(owner);
        desk.repay(id, 10 ether, 3 ether);
        assertEq(desk.ownerPolicyIds(owner).length, 1);
        assertEq(desk.executorPolicyIds(owner)[0], id);
        assertEq(desk.getPolicy(id).policy.recordedVolume, 3 ether);
        assertEq(desk.getPolicy(id).ownerHandle, "880");
        assertEq(desk.getPolicy(id).executorHandle, "880");
    }

    function test_existingPolicySurvivesRegistryRevoke() public {
        uint256 id = _createDefault();
        _deposit(id, 20 ether);
        registry.revoke(owner);
        registry.revoke(executor);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.AgentIdRequired.selector, owner));
        desk.createPolicy(executor, 1 ether, 1 ether, 1 ether, _expiry());

        vm.prank(executor);
        desk.pull(id, 10 ether);
        _approve(executor, 10 ether);
        vm.prank(executor);
        desk.repay(id, 10 ether, 1 ether);
        vm.prank(owner);
        desk.close(id);
        assertEq(desk.getPolicy(id).policy.escrow, 0);
        assertEq(usdt.balanceOf(address(desk)), 0);
    }

    function test_directDonationIsNotEscrowAndCloseDoesNotSweepIt() public {
        uint256 id = _createDefault();
        uint256 ownerBefore = usdt.balanceOf(owner);
        _deposit(id, 50 ether);
        vm.prank(owner);
        usdt.transfer(address(desk), 7 ether);

        assertEq(desk.totalEscrow(), 50 ether);
        assertEq(usdt.balanceOf(address(desk)), 57 ether);

        vm.prank(owner);
        desk.close(id);
        assertEq(usdt.balanceOf(owner), ownerBefore - 7 ether);
        assertEq(usdt.balanceOf(address(desk)), 7 ether);
        assertEq(desk.totalEscrow(), 0);
    }

    function test_statusPriorityClosedBeatsOtherFlags() public {
        uint256 id = _createDefault();
        _deposit(id, 10 ether);
        vm.prank(executor);
        desk.pull(id, 10 ether);
        _approve(executor, 10 ether);
        vm.prank(executor);
        desk.repay(id, 10 ether, VOLUME_TARGET);
        assertEq(uint8(desk.getPolicy(id).status), uint8(AgentPolicyDesk.Status.Completed));

        vm.prank(owner);
        desk.pause(id);
        assertEq(uint8(desk.getPolicy(id).status), uint8(AgentPolicyDesk.Status.Completed));

        vm.prank(owner);
        desk.close(id);
        assertEq(uint8(desk.getPolicy(id).status), uint8(AgentPolicyDesk.Status.Closed));
    }

    function test_receiveRejectsNative() public {
        vm.deal(address(this), 2 ether);
        (bool ok,) = address(desk).call{value: 1 ether}("");
        assertFalse(ok);
        (ok,) = address(desk).call{value: 1 ether}(hex"1234");
        assertFalse(ok);
        assertEq(address(desk).balance, 0);
    }

    function test_constructorRejectsZeroAndEoa() public {
        vm.expectRevert(AgentPolicyDesk.ZeroAddress.selector);
        new AgentPolicyDesk(address(0), address(usdt));
        vm.expectRevert(AgentPolicyDesk.ZeroAddress.selector);
        new AgentPolicyDesk(address(registry), address(0));
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.NotAContract.selector, stranger));
        new AgentPolicyDesk(stranger, address(usdt));
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.NotAContract.selector, stranger));
        new AgentPolicyDesk(address(registry), stranger);
    }

    function test_balanceOnlyAgentCanCreateWithEmptyHandle() public {
        registry.setAgent(stranger, "");
        vm.prank(stranger);
        uint256 id = desk.createPolicy(executor, 1 ether, 1 ether, 1 ether, _expiry());
        assertEq(desk.getPolicy(id).ownerHandle, "");
        assertEq(desk.getPolicy(id).policy.owner, stranger);
    }

    function testFuzz_repayConservesTokens(uint96 rawDeposit, uint96 rawPull, uint96 rawRepay) public {
        uint256 depositAmount = bound(rawDeposit, 1 ether, 1_000_000 ether);
        uint256 pullAmount = bound(rawPull, 1, depositAmount);
        uint256 repayAmount = bound(rawRepay, 0, pullAmount);

        vm.prank(owner);
        uint256 id = desk.createPolicy(
            executor, pullAmount, type(uint128).max, type(uint128).max, uint64(block.timestamp + 30 days)
        );
        _deposit(id, depositAmount);

        uint256 ownerBefore = usdt.balanceOf(owner);
        uint256 executorBefore = usdt.balanceOf(executor);

        vm.prank(executor);
        desk.pull(id, pullAmount);
        if (repayAmount > 0) _approve(executor, repayAmount);
        vm.prank(executor);
        desk.repay(id, repayAmount, 0);

        uint256 escrow = depositAmount - pullAmount + repayAmount;
        assertEq(desk.getPolicy(id).policy.escrow, escrow);
        assertEq(desk.getPolicy(id).policy.outstanding, 0);
        assertEq(desk.getPolicy(id).policy.realizedLoss, pullAmount - repayAmount);
        assertEq(usdt.balanceOf(address(desk)), escrow);
        assertEq(desk.totalEscrow(), escrow);
        assertEq(ownerBefore - usdt.balanceOf(owner), 0);
        assertEq(usdt.balanceOf(executor) - executorBefore, pullAmount - repayAmount);
    }

    function test_silentTokenDepositPullRepayAndClose() public {
        SilentUSDT silent = new SilentUSDT();
        MockAgentRegistry reg = new MockAgentRegistry();
        AgentPolicyDesk local = new AgentPolicyDesk(address(reg), address(silent));
        reg.setAgent(owner, "880");
        reg.setAgent(executor, "executor880");
        silent.mint(owner, 100 ether);
        silent.mint(executor, 100 ether);

        vm.prank(owner);
        uint256 id = local.createPolicy(executor, 40 ether, 100 ether, 50 ether, _expiry());
        vm.prank(owner);
        silent.approve(address(local), 80 ether);
        vm.prank(owner);
        local.deposit(id, 80 ether);
        vm.prank(executor);
        local.pull(id, 30 ether);
        vm.prank(executor);
        silent.approve(address(local), 30 ether);
        vm.prank(executor);
        local.repay(id, 30 ether, 5 ether);
        assertEq(silent.balanceOf(address(local)), 80 ether);
        assertEq(local.totalEscrow(), 80 ether);

        vm.prank(owner);
        local.close(id);
        assertEq(silent.balanceOf(owner), 100 ether);
        assertEq(silent.balanceOf(address(local)), 0);
    }

    function test_falseReturnDoesNotDeposit() public {
        FalseUSDT token = new FalseUSDT();
        MockAgentRegistry reg = new MockAgentRegistry();
        AgentPolicyDesk local = new AgentPolicyDesk(address(reg), address(token));
        reg.setAgent(owner, "880");
        reg.setAgent(executor, "executor880");
        token.mint(owner, 10 ether);
        vm.prank(owner);
        uint256 id = local.createPolicy(executor, 10 ether, 10 ether, 10 ether, _expiry());
        vm.prank(owner);
        token.approve(address(local), 10 ether);
        vm.prank(owner);
        vm.expectRevert(SafeToken.TransferFailed.selector);
        local.deposit(id, 10 ether);
        assertEq(token.balanceOf(owner), 10 ether);
        assertEq(local.getPolicy(id).policy.escrow, 0);
        assertEq(local.totalEscrow(), 0);
    }

    function test_feeOnTransferDepositReverts() public {
        FeeUSDT token = new FeeUSDT();
        MockAgentRegistry reg = new MockAgentRegistry();
        AgentPolicyDesk local = new AgentPolicyDesk(address(reg), address(token));
        reg.setAgent(owner, "880");
        reg.setAgent(executor, "executor880");
        token.mint(owner, 100 ether);
        vm.prank(owner);
        uint256 id = local.createPolicy(executor, 100 ether, 100 ether, 100 ether, _expiry());
        vm.prank(owner);
        token.approve(address(local), 100 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicyDesk.UnexpectedTransferAmount.selector, 100 ether, 90 ether));
        local.deposit(id, 100 ether);
        assertEq(token.balanceOf(owner), 100 ether);
        assertEq(local.totalEscrow(), 0);
    }

    function test_reentrancyOnRepayCannotPull() public {
        HookUSDT token = new HookUSDT();
        MockAgentRegistry reg = new MockAgentRegistry();
        AgentPolicyDesk local = new AgentPolicyDesk(address(reg), address(token));
        EvilExecutor evil = new EvilExecutor(local, token);
        reg.setAgent(owner, "880");
        reg.setAgent(address(evil), "evil");
        token.mint(owner, 100 ether);

        vm.prank(owner);
        uint256 id = local.createPolicy(address(evil), 40 ether, 1000 ether, 1000 ether, _expiry());
        vm.prank(owner);
        token.approve(address(local), 100 ether);
        vm.prank(owner);
        local.deposit(id, 100 ether);

        evil.pull(id, 40 ether);
        evil.approve(40 ether);
        evil.setAttack(id, 40 ether);
        token.arm(address(evil));
        evil.repay(id, 40 ether, 0);

        assertFalse(token.innerSucceeded());
        assertEq(local.getPolicy(id).policy.escrow, 100 ether);
        assertEq(local.getPolicy(id).policy.outstanding, 0);
        assertEq(local.getPolicy(id).policy.realizedLoss, 0);
        assertEq(token.balanceOf(address(local)), 100 ether);
        assertEq(local.totalEscrow(), 100 ether);
        assertEq(token.balanceOf(address(evil)), 0);
    }

    function _expiry() internal view returns (uint64) {
        return uint64(block.timestamp + 7 days);
    }

    function _createDefault() internal returns (uint256 id) {
        vm.prank(owner);
        id = desk.createPolicy(executor, MAX_PER_TRADE, VOLUME_TARGET, MAX_LOSS, _expiry());
    }

    function _approve(address account, uint256 amount) internal {
        vm.prank(account);
        usdt.approve(address(desk), amount);
    }

    function _deposit(uint256 id, uint256 amount) internal {
        _approve(owner, amount);
        vm.prank(owner);
        desk.deposit(id, amount);
    }
}
