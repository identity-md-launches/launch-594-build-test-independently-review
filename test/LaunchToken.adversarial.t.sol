// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";

contract LaunchTokenAdversarialTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    LaunchToken internal token;
    address internal holder = address(0xA11CE);
    address internal spender = address(0xB0B);
    address internal recipient = address(0xCAFE);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(holder);
        token = new LaunchToken();
    }

    function test_zeroOneAndFullSupplyTransfers() public {
        vm.prank(recipient);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(recipient, holder, 0);
        assertTrue(token.transfer(holder, 0));

        vm.prank(holder);
        assertTrue(token.transfer(recipient, 1));
        assertEq(token.balanceOf(recipient), 1);
        assertEq(token.balanceOf(holder), SUPPLY - 1);
        vm.prank(holder);
        assertTrue(token.transfer(recipient, SUPPLY - 1));
        assertEq(token.balanceOf(recipient), SUPPLY);
        assertEq(token.balanceOf(holder), 0);
        vm.prank(recipient);
        assertTrue(token.transfer(holder, SUPPLY));
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_fullBalanceSelfTransferCannotCreateOrDestroyTokens() public {
        vm.prank(holder);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(holder, holder, SUPPLY);
        assertTrue(token.transfer(holder, SUPPLY));
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_delegatedSelfTransferConsumesAllowanceWithoutMovingBalance() public {
        vm.prank(holder);
        token.approve(spender, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, holder, SUPPLY));
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(holder), SUPPLY);
        vm.prank(spender);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(holder, recipient, 1);
    }

    function test_approvalReplacesRatherThanAddsAndCanBeRevoked() public {
        vm.startPrank(holder);
        token.approve(spender, type(uint256).max);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(holder, spender, 1);
        assertTrue(token.approve(spender, 1));
        assertEq(token.allowance(holder, spender), 1);
        assertTrue(token.approve(spender, 0));
        vm.stopPrank();
        vm.prank(spender);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(holder, recipient, 1);
        assertEq(token.balanceOf(holder), SUPPLY);
    }

    function test_maxUintTransferRevertsWithoutStateChange() public {
        vm.prank(holder);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transfer(recipient, type(uint256).max);
        vm.prank(holder);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transferFrom(holder, recipient, type(uint256).max);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.allowance(holder, spender), type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroAmountStillRejectsZeroRecipientAndZeroSpender() public {
        vm.prank(holder);
        vm.expectRevert(LaunchToken.TransferToZeroAddress.selector);
        token.transfer(address(0), 0);
        vm.prank(spender);
        vm.expectRevert(LaunchToken.TransferToZeroAddress.selector);
        token.transferFrom(holder, address(0), 0);
        vm.prank(holder);
        vm.expectRevert(LaunchToken.ApproveToZeroAddress.selector);
        token.approve(address(0), 0);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_zeroDelegatedTransferNeedsNoPositiveAllowance() public {
        vm.prank(spender);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(holder, recipient, 0);
        assertTrue(token.transferFrom(holder, recipient, 0));
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_failedDelegatedTransferRollsBackFiniteAllowance(uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, 1, SUPPLY);
        vm.prank(holder);
        token.approve(spender, amount);
        vm.prank(spender);
        vm.expectRevert(LaunchToken.TransferToZeroAddress.selector);
        token.transferFrom(holder, address(0), amount);
        assertEq(token.allowance(holder, spender), amount);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);

        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, amount));
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(holder), SUPPLY - amount);
        assertEq(token.balanceOf(recipient), amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_otherSpenderCannotUseAnApproval(uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, 1, SUPPLY);
        vm.prank(holder);
        token.approve(spender, amount);
        vm.prank(recipient);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(holder, recipient, amount);
        assertEq(token.allowance(holder, spender), amount);
        assertEq(token.allowance(holder, recipient), 0);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }
}
