// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice Общие правила сбора для самостоятельного контракта и прокси.
abstract contract TripFundCore is Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IERC20 public token;
    address public organizer;
    uint256 public goal;
    uint256 public deadline;
    mapping(address => uint256) public contributions;
    uint256 public totalRaised;
    bool public withdrawn;

    error ZeroAddress();
    error ZeroGoal();
    error InvalidDeadline();
    error ZeroAmount();
    error FundingClosed();
    error FundingStillOpen();
    error GoalNotReached();
    error GoalReached();
    error OnlyOrganizer();
    error AlreadyWithdrawn();
    error NoContribution();

    event Contributed(address indexed payer, address indexed beneficiary, uint256 amount);
    event Refunded(address indexed contributor, uint256 amount);
    event Withdrawn(address indexed organizer, uint256 amount);

    function __TripFundCore_init(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        onlyInitializing
    {
        if (token_ == address(0) || organizer_ == address(0)) revert ZeroAddress();
        if (goal_ == 0) revert ZeroGoal();
        if (deadline_ <= block.timestamp) revert InvalidDeadline();

        token = IERC20(token_);
        organizer = organizer_;
        goal = goal_;
        deadline = deadline_;
    }

    function contribute(uint256 amount) external nonReentrant {
        _contribute(msg.sender, msg.sender, amount);
    }

    function withdraw() external nonReentrant {
        if (block.timestamp < deadline) revert FundingStillOpen();
        if (totalRaised < goal) revert GoalNotReached();
        if (msg.sender != organizer) revert OnlyOrganizer();
        if (withdrawn) revert AlreadyWithdrawn();

        withdrawn = true;
        token.safeTransfer(organizer, totalRaised);
        emit Withdrawn(organizer, totalRaised);
    }

    function refund() external nonReentrant {
        if (block.timestamp < deadline) revert FundingStillOpen();
        if (totalRaised >= goal) revert GoalReached();
        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NoContribution();

        contributions[msg.sender] = 0;
        token.safeTransfer(msg.sender, amount);
        emit Refunded(msg.sender, amount);
    }

    function _contribute(address payer, address beneficiary, uint256 amount) internal {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp >= deadline) revert FundingClosed();

        contributions[beneficiary] += amount;
        totalRaised += amount;
        token.safeTransferFrom(payer, address(this), amount);
        emit Contributed(payer, beneficiary, amount);
    }
}
