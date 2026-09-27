// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Momentum (MOMO)
/// @notice Fixed-supply ERC-20: 1,000,000,000 MOMO with 18 decimals, minted once to the deployer.
/// @dev No constructor arguments, no mint path after construction, no owner, no admin, no pause.
contract Momentum is ERC20 {
    /// @notice The entire supply, in base units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Momentum", "MOMO") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
