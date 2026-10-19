// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TripFundCore} from "./TripFundCore.sol";

/// @notice Бонусная V1: используется через TransparentUpgradeableProxy.
contract TripFundV1 is TripFundCore {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        public
        initializer
    {
        __TripFundCore_init(token_, organizer_, goal_, deadline_);
    }
}
