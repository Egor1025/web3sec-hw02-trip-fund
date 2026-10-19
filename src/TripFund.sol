// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TripFundCore} from "./TripFundCore.sol";

/// @notice Основная часть: параметры задаются один раз в конструкторе.
contract TripFund is TripFundCore {
    constructor(address token_, address organizer_, uint256 goal_, uint256 deadline_) initializer {
        __TripFundCore_init(token_, organizer_, goal_, deadline_);
    }
}
