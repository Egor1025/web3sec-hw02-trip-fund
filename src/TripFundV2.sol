// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TripFundV1} from "./TripFundV1.sol";

/// @notice V2 добавляет оплату за другого участника без изменения хранилища.
/// @custom:oz-upgrades-from TripFundV1
contract TripFundV2 is TripFundV1 {
    function contributeFor(address beneficiary, uint256 amount) external nonReentrant {
        _contribute(msg.sender, beneficiary, amount);
    }
}
