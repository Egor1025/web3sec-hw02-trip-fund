// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TripFundCore} from "../src/TripFundCore.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {TestToken} from "./helpers/TestToken.sol";

contract TripFundUpgradeTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant FRIEND = address(0xF123);
    address internal constant ORGANIZER = address(0xCAFE);
    address internal constant ADMIN = address(0xAD);
    uint256 internal constant GOAL = 1_000 ether;
    uint256 internal deadline;
    TestToken internal token;
    address internal proxy;
    TripFundV1 internal v1;

    event Contributed(address indexed payer, address indexed beneficiary, uint256 amount);

    function setUp() public {
        vm.warp(1_800_000_000);
        deadline = block.timestamp + 7 days;
        token = new TestToken();
        token.mint(ALICE, 10_000 ether);
        token.mint(BOB, 10_000 ether);
        // OpenZeppelin проверяет V1 до развёртывания; проверки не отключены.
        proxy = Upgrades.deployTransparentProxy(
            "TripFundV1.sol:TripFundV1",
            ADMIN,
            abi.encodeCall(TripFundV1.initialize, (address(token), ORGANIZER, GOAL, deadline))
        );
        v1 = TripFundV1(proxy);
    }

    function _upgrade() internal returns (TripFundV2) {
        // @custom:oz-upgrades-from задаёт V1 для проверки совместимости storage.
        Upgrades.upgradeProxy(proxy, "TripFundV2.sol:TripFundV2", "", ADMIN);
        return TripFundV2(proxy);
    }

    function _pay(address payer, uint256 amount) internal {
        vm.startPrank(payer);
        token.approve(proxy, amount);
        v1.contribute(amount);
        vm.stopPrank();
    }

    function _payFor(TripFundV2 v2, address payer, address beneficiary, uint256 amount) internal {
        vm.startPrank(payer);
        token.approve(proxy, amount);
        v2.contributeFor(beneficiary, amount);
        vm.stopPrank();
    }

    function test_UpgradePreservesStateAndRefundsFriend() public {
        _pay(ALICE, 100 ether);
        _pay(BOB, 50 ether);
        vm.prank(BOB);
        token.transfer(proxy, 7 ether);
        address oldImplementation = Upgrades.getImplementationAddress(proxy);
        address oldAdmin = Upgrades.getAdminAddress(proxy);
        vm.warp(deadline - 10);
        TripFundV2 v2 = _upgrade();

        assertEq(address(v2), proxy);
        assertTrue(Upgrades.getImplementationAddress(proxy) != oldImplementation);
        assertEq(Upgrades.getAdminAddress(proxy), oldAdmin);
        assertEq(ProxyAdmin(oldAdmin).owner(), ADMIN);
        assertTrue(ADMIN != ORGANIZER);
        assertEq(address(v2.token()), address(token));
        assertEq(v2.organizer(), ORGANIZER);
        assertEq(v2.goal(), GOAL);
        assertEq(v2.deadline(), deadline);
        assertEq(v2.contributions(ALICE), 100 ether);
        assertEq(v2.contributions(BOB), 50 ether);
        assertEq(v2.totalRaised(), 150 ether);
        assertEq(token.balanceOf(proxy), 157 ether);
        assertFalse(v2.withdrawn());

        vm.prank(ALICE);
        token.approve(proxy, 200 ether);
        vm.expectEmit(true, true, false, true, proxy);
        emit Contributed(ALICE, FRIEND, 200 ether);
        vm.prank(ALICE);
        v2.contributeFor(FRIEND, 200 ether);
        _payFor(v2, BOB, FRIEND, 25 ether);
        _pay(BOB, 50 ether); // Обычный contribute после обновления.
        assertEq(v2.contributions(ALICE), 100 ether);
        assertEq(v2.contributions(BOB), 100 ether);
        assertEq(v2.contributions(FRIEND), 225 ether);
        assertEq(v2.totalRaised(), 425 ether);
        assertEq(token.balanceOf(ALICE), 9_700 ether);
        assertEq(token.balanceOf(BOB), 9_868 ether);
        assertEq(token.balanceOf(FRIEND), 0);

        vm.warp(deadline);
        vm.prank(FRIEND);
        v2.refund();
        assertEq(token.balanceOf(FRIEND), 225 ether);
        assertEq(v2.contributions(FRIEND), 0);
        vm.prank(ALICE);
        v2.refund();
        vm.prank(BOB);
        v2.refund();
        assertEq(token.balanceOf(ALICE), 9_800 ether);
        assertEq(token.balanceOf(BOB), 9_968 ether);
        assertEq(token.balanceOf(proxy), 7 ether);
        assertEq(v2.totalRaised(), 425 ether);
    }

    function test_OnlyProxyAdminOwnerCanUpgrade() public {
        address implementation = address(new TripFundV2());
        ProxyAdmin admin = ProxyAdmin(Upgrades.getAdminAddress(proxy));
        address original = Upgrades.getImplementationAddress(proxy);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ORGANIZER));
        vm.prank(ORGANIZER);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), implementation, "");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        vm.prank(ALICE);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), implementation, "");
        assertEq(Upgrades.getImplementationAddress(proxy), original);
        TripFundV2 v2 = _upgrade();
        _payFor(v2, ALICE, FRIEND, 1 ether);
        assertEq(v2.contributions(FRIEND), 1 ether);
    }

    function test_ProxyCannotBeInitializedAgainBeforeOrAfterUpgrade() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v1.initialize(address(token), ALICE, 1, deadline + 1);
        TripFundV2 v2 = _upgrade();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(ADMIN);
        v2.initialize(address(token), ALICE, 1, deadline + 1);
        assertEq(v2.organizer(), ORGANIZER);
        assertEq(v2.goal(), GOAL);
        assertEq(v2.deadline(), deadline);
    }

    function test_BothImplementationsCannotBeInitializedDirectly() public {
        TripFundV1 implementation1 = TripFundV1(Upgrades.getImplementationAddress(proxy));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation1.initialize(address(token), ALICE, GOAL, deadline);
        _upgrade();
        TripFundV2 implementation2 = TripFundV2(Upgrades.getImplementationAddress(proxy));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation2.initialize(address(token), ALICE, GOAL, deadline);
    }

    function test_ContributeForRejectsZeroBeneficiaryAndAmount() public {
        TripFundV2 v2 = _upgrade();
        vm.startPrank(ALICE);
        token.approve(proxy, 100 ether);
        vm.expectRevert(TripFundCore.ZeroAddress.selector);
        v2.contributeFor(address(0), 100 ether);
        vm.expectRevert(TripFundCore.ZeroAmount.selector);
        v2.contributeFor(FRIEND, 0);
        vm.stopPrank();
        assertEq(v2.totalRaised(), 0);
        assertEq(v2.contributions(FRIEND), 0);
        assertEq(token.balanceOf(proxy), 0);
        assertEq(token.balanceOf(ALICE), 10_000 ether);
        assertEq(token.allowance(ALICE, proxy), 100 ether);
    }

    function test_ContributeForUsesPayersAllowanceAndBalance() public {
        TripFundV2 v2 = _upgrade();
        // Разрешение получателя не заменяет разрешение плательщика.
        vm.prank(FRIEND);
        token.approve(proxy, 100 ether);
        vm.expectRevert();
        vm.prank(ALICE);
        v2.contributeFor(FRIEND, 100 ether);
        assertEq(v2.totalRaised(), 0);
        assertEq(v2.contributions(FRIEND), 0);
        assertEq(token.balanceOf(ALICE), 10_000 ether);
        _payFor(v2, ALICE, FRIEND, 100 ether);
        assertEq(token.balanceOf(ALICE), 9_900 ether);
        assertEq(token.balanceOf(FRIEND), 0);
        assertEq(v2.contributions(ALICE), 0);
        assertEq(v2.contributions(FRIEND), 100 ether);
        vm.warp(deadline);
        vm.expectRevert(TripFundCore.NoContribution.selector);
        vm.prank(ALICE);
        v2.refund();
        vm.prank(FRIEND);
        v2.refund();
        assertEq(token.balanceOf(FRIEND), 100 ether);
        assertEq(token.balanceOf(ALICE), 9_900 ether);
    }

    function test_ContributeForDeadlineBoundary() public {
        TripFundV2 v2 = _upgrade();
        vm.warp(deadline - 1);
        _payFor(v2, ALICE, FRIEND, 100 ether);
        vm.warp(deadline);
        vm.expectRevert(TripFundCore.FundingClosed.selector);
        vm.prank(ALICE);
        v2.contributeFor(FRIEND, 100 ether);
        assertEq(v2.totalRaised(), 100 ether);
        assertEq(v2.contributions(FRIEND), 100 ether);
        assertEq(token.balanceOf(proxy), 100 ether);
        assertEq(token.balanceOf(ALICE), 9_900 ether);
    }

    function test_ContributeForSelfAndExistingBeneficiaryAccumulate() public {
        _pay(ALICE, 50 ether);
        TripFundV2 v2 = _upgrade();
        _payFor(v2, ALICE, ALICE, 25 ether);
        _payFor(v2, BOB, ALICE, 75 ether);
        assertEq(v2.contributions(ALICE), 150 ether);
        assertEq(v2.contributions(BOB), 0);
        assertEq(v2.totalRaised(), 150 ether);
        vm.warp(deadline);
        vm.prank(ALICE);
        v2.refund();
        assertEq(token.balanceOf(ALICE), 10_075 ether);
        assertEq(token.balanceOf(BOB), 9_925 ether);
    }

    function test_ContributeForCanReachGoalAndPayOrganizer() public {
        _pay(ALICE, 200 ether);
        TripFundV2 v2 = _upgrade();
        _payFor(v2, BOB, FRIEND, 800 ether);
        vm.warp(deadline);
        vm.expectRevert(TripFundCore.GoalReached.selector);
        vm.prank(FRIEND);
        v2.refund();
        vm.prank(ORGANIZER);
        v2.withdraw();
        assertEq(token.balanceOf(ORGANIZER), GOAL);
        assertEq(v2.totalRaised(), GOAL);
        assertEq(token.balanceOf(proxy), 0);
    }
}
