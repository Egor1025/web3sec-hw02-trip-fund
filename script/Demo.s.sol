// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {TestToken} from "../test/helpers/TestToken.sol";

/// @notice Локальный пример approve –> contribute –> upgrade –> contributeFor.
contract Demo is Script {
    function run() external {
        TestToken token = new TestToken();
        address payer = makeAddr("payer");
        address friend = makeAddr("friend");
        address organizer = makeAddr("organizer");
        address admin = makeAddr("admin");
        address proxy = Upgrades.deployTransparentProxy(
            "TripFundV1.sol:TripFundV1",
            admin,
            abi.encodeCall(
                TripFundV1.initialize, (address(token), organizer, 1_000 ether, block.timestamp + 7 days)
            )
        );

        token.mint(payer, 1_000 ether);
        vm.startPrank(payer);
        token.approve(proxy, 300 ether);
        TripFundV1(proxy).contribute(100 ether);
        vm.stopPrank();

        vm.startPrank(admin);
        Upgrades.upgradeProxy(proxy, "TripFundV2.sol:TripFundV2", "");
        vm.stopPrank();
        vm.prank(payer);
        TripFundV2(proxy).contributeFor(friend, 200 ether);

        console2.log(unicode"Прокси TripFund:", proxy);
        console2.log(unicode"Токен:", address(token));
        console2.log(unicode"Всего собрано:", TripFundV2(proxy).totalRaised());
        console2.log(unicode"Вклад за друга:", TripFundV2(proxy).contributions(friend));
    }
}
