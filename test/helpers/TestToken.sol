// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Только локальный тестовый токен: без комиссии и rebasing.
contract TestToken is ERC20 {
    constructor() ERC20("Trip Token", "TRIP") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Возвращает false после перевода, чтобы проверить полный откат SafeERC20.
contract FalseReturningToken is TestToken {
    bool public failTransfer;
    bool public failTransferFrom;

    function setFailures(bool transfer_, bool transferFrom_) external {
        failTransfer = transfer_;
        failTransferFrom = transferFrom_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        return !failTransfer;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        return !failTransferFrom;
    }
}
