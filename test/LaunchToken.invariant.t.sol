// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// @dev All balances stay within this closed set. Ghost state changes only after a
/// successful public operation; failed operations must leave it unchanged.
contract LaunchTokenHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    LaunchToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(LaunchToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        expectedBalance[actors_[0]] = SUPPLY;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool unlimited) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = unlimited ? type(uint256).max : bound(amountSeed, 0, SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function spend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 permitted = expectedAllowance[owner][spender];
        uint256 available = expectedBalance[owner];
        uint256 amount = bound(amountSeed, 0, permitted < available ? permitted : available);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (permitted != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        _move(owner, to, amount);
    }

    function overspendBalance(uint256 fromSeed, uint256 toSeed, uint256 excessSeed) public {
        address from = _actor(fromSeed);
        uint256 amount = expectedBalance[from] + bound(excessSeed, 1, SUPPLY);
        vm.prank(from);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transfer(_actor(toSeed), amount);
    }

    function revokeAndTrySpend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, 0));
        expectedAllowance[owner][spender] = 0;
        vm.prank(spender);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(owner, _actor(toSeed), 1);
    }

    function spendMoreThanBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = expectedBalance[owner] + 1;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;

        // transferFrom updates its allowance before checking the balance. The
        // later revert must roll back that update as well as both balances.
        vm.prank(spender);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transferFrom(owner, _actor(toSeed), amount);
    }

    function transferToZero(uint256 ownerSeed, uint256 amountSeed) public {
        address owner = _actor(ownerSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[owner]);
        vm.prank(owner);
        vm.expectRevert(LaunchToken.TransferToZeroAddress.selector);
        token.transfer(address(0), amount);
    }

    function spendToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[owner]);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
        vm.prank(spender);
        vm.expectRevert(LaunchToken.TransferToZeroAddress.selector);
        token.transferFrom(owner, address(0), amount);
    }

    function approveZero(uint256 ownerSeed, uint256 amount) public {
        vm.prank(_actor(ownerSeed));
        vm.expectRevert(LaunchToken.ApproveToZeroAddress.selector);
        token.approve(address(0), amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    LaunchToken internal token;
    LaunchTokenHandler internal handler;

    function setUp() public {
        address[4] memory actors = [address(0xA11CE), address(0xB0B), address(0xCAFE), address(0xD00D)];
        vm.prank(actors[0]);
        token = new LaunchToken();
        handler = new LaunchTokenHandler(token, actors);
        for (uint256 i = 1; i < actors.length; ++i) {
            handler.transfer(0, i, SUPPLY / actors.length);
        }

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.spend.selector;
        selectors[3] = handler.overspendBalance.selector;
        selectors[4] = handler.revokeAndTrySpend.selector;
        selectors[5] = handler.spendMoreThanBalance.selector;
        selectors[6] = handler.transferToZero.selector;
        selectors[7] = handler.spendToZero.selector;
        selectors[8] = handler.approveZero.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_fixedSupplyAndExactBalances() public view {
        uint256 held;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor), "balance differs from successful transfers");
            held += balance;
        }
        assertEq(held, SUPPLY, "tokens escaped conservation");
        assertEq(token.totalSupply(), SUPPLY, "supply changed after deployment");
        assertEq(token.balanceOf(address(0)), 0, "tokens were burned");
    }

    function invariant_allowancesMatchApprovalsAndSuccessfulSpends() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            assertEq(token.allowance(owner, address(0)), 0, "zero address obtained an allowance");
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "allowance changed without approval or successful spend"
                );
            }
        }
    }
}
