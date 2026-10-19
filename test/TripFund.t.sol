// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TripFundCore} from "../src/TripFundCore.sol";
import {TripFund} from "../src/TripFund.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {FalseReturningToken} from "./helpers/TestToken.sol";

/// @notice Один набор правил проверяется для TripFund, V1-прокси и V2-прокси.
abstract contract TripFundBehavior is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ORGANIZER = address(0xCAFE);
    address internal constant ADMIN = address(0xAD);
    uint256 internal constant INITIAL = 10_000 ether;
    uint256 internal constant GOAL = 1_000 ether;

    FalseReturningToken internal token;
    TripFundCore internal fund;
    uint256 internal deadline;
    address internal implementation;

    function _prepareImplementation() internal virtual {}

    event Contributed(address indexed payer, address indexed beneficiary, uint256 amount);
    event Refunded(address indexed contributor, uint256 amount);
    event Withdrawn(address indexed organizer, uint256 amount);

    function _deploy(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        virtual
        returns (TripFundCore);

    function setUp() public {
        vm.warp(1_800_000_000);
        deadline = block.timestamp + 7 days;
        token = new FalseReturningToken();
        token.mint(ALICE, INITIAL);
        token.mint(BOB, INITIAL);
        _prepareImplementation();
        fund = _deploy(address(token), ORGANIZER, GOAL, deadline);
    }

    function _contribute(address payer, uint256 amount) internal {
        vm.startPrank(payer);
        token.approve(address(fund), amount);
        fund.contribute(amount);
        vm.stopPrank();
    }

    function _assertEmpty() internal view {
        assertEq(fund.totalRaised(), 0);
        assertEq(fund.contributions(ALICE), 0);
        assertEq(fund.contributions(BOB), 0);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(token.balanceOf(ALICE), INITIAL);
        assertEq(token.balanceOf(BOB), INITIAL);
        assertFalse(fund.withdrawn());
    }

    function test_Parameters() public view {
        assertEq(address(fund.token()), address(token));
        assertEq(fund.organizer(), ORGANIZER);
        assertEq(fund.goal(), GOAL);
        assertEq(fund.deadline(), deadline);
        _assertEmpty();
    }

    function test_RejectZeroToken() public {
        vm.expectRevert(TripFundCore.ZeroAddress.selector);
        _deploy(address(0), ORGANIZER, GOAL, deadline);
    }

    function test_RejectZeroOrganizer() public {
        vm.expectRevert(TripFundCore.ZeroAddress.selector);
        _deploy(address(token), address(0), GOAL, deadline);
    }

    function test_RejectZeroGoal() public {
        vm.expectRevert(TripFundCore.ZeroGoal.selector);
        _deploy(address(token), ORGANIZER, 0, deadline);
    }

    function test_RejectDeadlineNow() public {
        vm.expectRevert(TripFundCore.InvalidDeadline.selector);
        _deploy(address(token), ORGANIZER, GOAL, block.timestamp);
    }

    function test_RejectDeadlineInPast() public {
        vm.expectRevert(TripFundCore.InvalidDeadline.selector);
        _deploy(address(token), ORGANIZER, GOAL, block.timestamp - 1);
    }

    function test_TwoContributorsAndRepeatedContribution() public {
        _contribute(ALICE, 200 ether);
        _contribute(BOB, 300 ether);
        vm.prank(ALICE);
        token.approve(address(fund), 100 ether);
        vm.expectEmit(true, true, false, true, address(fund));
        emit Contributed(ALICE, ALICE, 100 ether);
        vm.prank(ALICE);
        fund.contribute(100 ether);

        assertEq(fund.contributions(ALICE), 300 ether);
        assertEq(fund.contributions(BOB), 300 ether);
        assertEq(fund.totalRaised(), 600 ether);
        assertEq(token.balanceOf(address(fund)), 600 ether);
        assertEq(token.balanceOf(ALICE), INITIAL - 300 ether);
        assertEq(token.balanceOf(BOB), INITIAL - 300 ether);
    }

    function test_ZeroContributionRollsBack() public {
        vm.expectRevert(TripFundCore.ZeroAmount.selector);
        vm.prank(ALICE);
        fund.contribute(0);
        _assertEmpty();
    }

    function test_InsufficientAllowanceRollsBack() public {
        vm.prank(ALICE);
        token.approve(address(fund), 49 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(fund), 49 ether, 50 ether
            )
        );
        vm.prank(ALICE);
        fund.contribute(50 ether);
        _assertEmpty();
        assertEq(token.allowance(ALICE, address(fund)), 49 ether);
    }

    function test_InsufficientBalanceRollsBack() public {
        uint256 amount = INITIAL + 1;
        vm.prank(ALICE);
        token.approve(address(fund), amount);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, INITIAL, amount)
        );
        vm.prank(ALICE);
        fund.contribute(amount);
        _assertEmpty();
        assertEq(token.allowance(ALICE, address(fund)), amount);
    }

    function test_DeadlineBoundary() public {
        vm.warp(deadline - 1);
        _contribute(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(address(fund), 100 ether);
        vm.warp(deadline);
        vm.expectRevert(TripFundCore.FundingClosed.selector);
        vm.prank(ALICE);
        fund.contribute(100 ether);
        vm.warp(deadline + 1);
        vm.expectRevert(TripFundCore.FundingClosed.selector);
        vm.prank(ALICE);
        fund.contribute(100 ether);

        assertEq(fund.totalRaised(), 100 ether);
        assertEq(fund.contributions(ALICE), 100 ether);
        assertEq(token.balanceOf(ALICE), INITIAL - 100 ether);
        assertEq(token.balanceOf(address(fund)), 100 ether);
        assertEq(token.allowance(ALICE, address(fund)), 100 ether);
    }

    function test_NoEarlyPayoutBelowGoal() public {
        _contribute(ALICE, 100 ether);
        _assertNoEarlyPayout();
    }

    function test_NoEarlyPayoutEvenWhenGoalReached() public {
        _contribute(ALICE, GOAL);
        _assertNoEarlyPayout();
    }

    function _assertNoEarlyPayout() internal {
        vm.warp(deadline - 1);
        vm.expectRevert(TripFundCore.FundingStillOpen.selector);
        vm.prank(ORGANIZER);
        fund.withdraw();
        vm.expectRevert(TripFundCore.FundingStillOpen.selector);
        vm.prank(ALICE);
        fund.refund();
        assertEq(token.balanceOf(ORGANIZER), 0);
        assertEq(token.balanceOf(address(fund)), fund.totalRaised());
        assertEq(fund.contributions(ALICE), fund.totalRaised());
        assertFalse(fund.withdrawn());
    }

    function test_WithdrawAtExactGoal() public {
        _assertSuccessfulWithdrawal(GOAL);
    }

    function test_WithdrawAboveGoal() public {
        _assertSuccessfulWithdrawal(GOAL + 123 ether);
    }

    function _assertSuccessfulWithdrawal(uint256 amount) internal {
        _contribute(ALICE, amount);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(fund));
        emit Withdrawn(ORGANIZER, amount);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertTrue(fund.withdrawn());
        assertEq(fund.totalRaised(), amount);
        assertEq(fund.contributions(ALICE), amount);
        assertEq(token.balanceOf(ORGANIZER), amount);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(token.balanceOf(ALICE), INITIAL - amount);
    }

    function test_OnlyOrganizerCanWithdraw() public {
        _contribute(ALICE, GOAL);
        vm.warp(deadline);
        vm.expectRevert(TripFundCore.OnlyOrganizer.selector);
        vm.prank(BOB);
        fund.withdraw();
        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(address(fund)), GOAL);
        assertEq(token.balanceOf(BOB), INITIAL);
    }

    function test_NoSecondWithdrawal() public {
        _assertSuccessfulWithdrawal(GOAL);
        vm.expectRevert(TripFundCore.AlreadyWithdrawn.selector);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(token.balanceOf(ORGANIZER), GOAL);
        assertEq(fund.totalRaised(), GOAL);
    }

    function test_NoRefundWhenSuccessful() public {
        _contribute(ALICE, GOAL);
        vm.warp(deadline);
        vm.expectRevert(TripFundCore.GoalReached.selector);
        vm.prank(ALICE);
        fund.refund();
        assertEq(fund.contributions(ALICE), GOAL);
        vm.prank(ORGANIZER);
        fund.withdraw();
        vm.expectRevert(TripFundCore.GoalReached.selector);
        vm.prank(ALICE);
        fund.refund();
    }

    function test_NoWithdrawalWhenFailed() public {
        _contribute(ALICE, GOAL - 1);
        vm.warp(deadline);
        vm.expectRevert(TripFundCore.GoalNotReached.selector);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(address(fund)), GOAL - 1);
        assertEq(token.balanceOf(ORGANIZER), 0);
    }

    function test_IndependentFullRefunds() public {
        _contribute(ALICE, 200 ether);
        _contribute(BOB, 300 ether);
        _contribute(ALICE, 100 ether);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(fund));
        emit Refunded(BOB, 300 ether);
        vm.prank(BOB);
        fund.refund();
        assertEq(fund.contributions(BOB), 0);
        assertEq(fund.contributions(ALICE), 300 ether);
        assertEq(token.balanceOf(BOB), INITIAL);
        assertEq(token.balanceOf(ALICE), INITIAL - 300 ether);
        assertEq(token.balanceOf(address(fund)), 300 ether);
        assertEq(fund.totalRaised(), 600 ether);
        vm.prank(ALICE);
        fund.refund();
        assertEq(fund.contributions(ALICE), 0);
        assertEq(token.balanceOf(ALICE), INITIAL);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), 600 ether);
    }

    function test_NoRefundWithoutContribution() public {
        vm.warp(deadline);
        vm.expectRevert(TripFundCore.NoContribution.selector);
        vm.prank(BOB);
        fund.refund();
        _assertEmpty();
    }

    function test_NoSecondRefund() public {
        _contribute(ALICE, 100 ether);
        vm.warp(deadline);
        vm.prank(ALICE);
        fund.refund();
        vm.expectRevert(TripFundCore.NoContribution.selector);
        vm.prank(ALICE);
        fund.refund();
        assertEq(token.balanceOf(ALICE), INITIAL);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), 100 ether);
    }

    function test_DirectTransferRemainsAfterWithdrawal() public {
        _contribute(ALICE, GOAL);
        vm.prank(BOB);
        token.transfer(address(fund), 42 ether);
        assertEq(fund.totalRaised(), GOAL);
        assertEq(fund.contributions(BOB), 0);
        vm.warp(deadline);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(token.balanceOf(ORGANIZER), GOAL);
        assertEq(token.balanceOf(address(fund)), 42 ether);
        assertEq(token.balanceOf(BOB), INITIAL - 42 ether);
    }

    function test_DirectTransferCannotMakeFundSuccessfulAndRemainsAfterRefunds() public {
        _contribute(ALICE, 100 ether);
        _contribute(BOB, 200 ether);
        vm.prank(BOB);
        token.transfer(address(fund), GOAL);
        assertEq(fund.totalRaised(), 300 ether);
        assertEq(fund.contributions(BOB), 200 ether);
        vm.warp(deadline);
        vm.prank(ALICE);
        fund.refund();
        vm.prank(BOB);
        fund.refund();
        assertEq(token.balanceOf(address(fund)), GOAL);
        assertEq(token.balanceOf(ALICE), INITIAL);
        assertEq(token.balanceOf(BOB), INITIAL - GOAL);
        assertEq(fund.totalRaised(), 300 ether);
    }

    function test_FalseTransferFromRollsBackEverything() public {
        token.setFailures(false, true);
        vm.prank(ALICE);
        token.approve(address(fund), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(ALICE);
        fund.contribute(100 ether);
        _assertEmpty();
        assertEq(token.allowance(ALICE, address(fund)), 100 ether);
    }

    function test_FailedWithdrawalRollsBackAndCanBeRetried() public {
        _contribute(ALICE, GOAL);
        token.setFailures(true, false);
        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(address(fund)), GOAL);
        assertEq(token.balanceOf(ORGANIZER), 0);
        assertEq(fund.totalRaised(), GOAL);
        assertEq(fund.contributions(ALICE), GOAL);
        token.setFailures(false, false);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertTrue(fund.withdrawn());
        assertEq(token.balanceOf(ORGANIZER), GOAL);
    }

    function test_FailedRefundRollsBackAndCanBeRetried() public {
        _contribute(ALICE, 100 ether);
        token.setFailures(true, false);
        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(ALICE);
        fund.refund();
        assertEq(fund.contributions(ALICE), 100 ether);
        assertEq(fund.totalRaised(), 100 ether);
        assertEq(token.balanceOf(address(fund)), 100 ether);
        assertEq(token.balanceOf(ALICE), INITIAL - 100 ether);
        token.setFailures(false, false);
        vm.prank(ALICE);
        fund.refund();
        assertEq(fund.contributions(ALICE), 0);
        assertEq(token.balanceOf(ALICE), INITIAL);
    }

    function testFuzz_RefundConservesBalances(uint256 a, uint256 b, uint256 donation) public {
        a = bound(a, 1, GOAL / 3);
        b = bound(b, 1, GOAL / 3);
        donation = bound(donation, 0, GOAL);
        _contribute(ALICE, a);
        _contribute(BOB, b);
        vm.prank(BOB);
        token.transfer(address(fund), donation);
        vm.warp(deadline);
        vm.prank(ALICE);
        fund.refund();
        vm.prank(BOB);
        fund.refund();
        assertEq(fund.totalRaised(), a + b);
        assertEq(fund.contributions(ALICE), 0);
        assertEq(fund.contributions(BOB), 0);
        assertEq(token.balanceOf(ALICE), INITIAL);
        assertEq(token.balanceOf(BOB), INITIAL - donation);
        assertEq(token.balanceOf(address(fund)), donation);
        assertEq(token.balanceOf(ORGANIZER), 0);
    }

    function testFuzz_WithdrawalConservesBalances(uint256 amount, uint256 donation) public {
        amount = bound(amount, GOAL, INITIAL);
        donation = bound(donation, 0, INITIAL);
        _contribute(ALICE, amount);
        vm.prank(BOB);
        token.transfer(address(fund), donation);
        vm.warp(deadline);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(fund.totalRaised(), amount);
        assertEq(token.balanceOf(ORGANIZER), amount);
        assertEq(token.balanceOf(address(fund)), donation);
        assertEq(token.balanceOf(ALICE), INITIAL - amount);
        assertEq(token.balanceOf(BOB), INITIAL - donation);
        assertTrue(fund.withdrawn());
    }
}

contract TripFundTest is TripFundBehavior {
    function _deploy(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        override
        returns (TripFundCore)
    {
        return new TripFund(token_, organizer_, goal_, deadline_);
    }
}

contract TripFundV1BehaviorTest is TripFundBehavior {
    function _prepareImplementation() internal override {
        implementation = address(new TripFundV1());
    }

    function _deploy(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        override
        returns (TripFundCore)
    {
        return TripFundCore(
            address(
                new TransparentUpgradeableProxy(
                    implementation,
                    ADMIN,
                    abi.encodeCall(TripFundV1.initialize, (token_, organizer_, goal_, deadline_))
                )
            )
        );
    }
}

contract TripFundV2BehaviorTest is TripFundBehavior {
    function _prepareImplementation() internal override {
        implementation = address(new TripFundV2());
    }

    function _deploy(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        override
        returns (TripFundCore)
    {
        return TripFundCore(
            address(
                new TransparentUpgradeableProxy(
                    implementation,
                    ADMIN,
                    abi.encodeCall(TripFundV1.initialize, (token_, organizer_, goal_, deadline_))
                )
            )
        );
    }
}
