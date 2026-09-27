// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Momentum} from "../src/Momentum.sol";

contract MomentumTest is Test {
    Momentum internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.prank(deployer);
        token = new Momentum();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Momentum");
        assertEq(token.symbol(), "MOMO");
        assertEq(token.decimals(), 18);
    }

    function test_mintsTheWholeFixedSupplyToTheDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 ether);
        assertEq(token.balanceOf(deployer), 1_000_000_000 ether);
    }

    function test_transferMovesExactlyTheAmount() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 123 ether));
        assertEq(token.balanceOf(alice), 123 ether);
        assertEq(token.balanceOf(deployer), 1_000_000_000 ether - 123 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_transferRevertsOverBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(deployer, 1);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, alice, 1);
    }

    function test_noMintPathExists() public {
        string[4] memory sigs = ["mint(address,uint256)", "mint(uint256)", "transferOwnership(address)", "owner()"];
        for (uint256 i = 0; i < sigs.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], deployer, 1 ether));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, token.balanceOf(deployer));
        vm.prank(deployer);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(deployer), token.totalSupply());
    }
}
