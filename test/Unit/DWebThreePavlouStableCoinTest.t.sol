//SPDX-License-Identifier:MIT

import { DWebThreePavlouStableCoin } from "../../src/DWebThreePavlouStableCoin.sol";
import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

pragma solidity ^0.8.18;

contract DwebThreePavlouStableCoinTest is Test {
    DWebThreePavlouStableCoin dsc;

    event MinterSet(address indexed oldMinter, address indexed newMinter);

    function setUp() public {
        dsc = new DWebThreePavlouStableCoin(msg.sender);
    }

    function testMustMintMoreThanZero() public {
        vm.prank(dsc.owner());
        vm.expectRevert(DWebThreePavlouStableCoin.DWebThreePavlouSC__MustBeMoreThanZero.selector);
        dsc.mint(address(this), 0);
    }

    function testMustMintToAnExistingAddress() public {
        vm.prank(dsc.owner());
        vm.expectRevert(DWebThreePavlouStableCoin.DWebThreePavlouSC__NotZeroAddress.selector);
        dsc.mint(address(0), 0);
    }

    function testCantBurnMoreThanYouHave() public {
        vm.startPrank(dsc.owner());
        dsc.mint(address(this), 100);
        vm.expectRevert(DWebThreePavlouStableCoin.DWebThreePavlouSC__BurnAmountExceedsBalance.selector);
        dsc.burn(101);
        vm.stopPrank();
    }

    function testCantBurnZeroAmount() public {
        vm.startPrank(dsc.owner());
        dsc.mint(address(this), 100);
        vm.expectRevert(DWebThreePavlouStableCoin.DWebThreePavlouSC__MustBeMoreThanZero.selector);
        dsc.burn(0);
        vm.stopPrank();
    }

    function testBlocksBurnFromFunction() public {
        vm.startPrank(dsc.owner());
        dsc.mint(address(this), 100);
        vm.stopPrank();

        address attacker = address(1);
        vm.prank(attacker);
        vm.expectRevert(DWebThreePavlouStableCoin.DWebThreePavlouSC__BlockFunction.selector);
        dsc.burnFrom(address(1), 100);
    }

    function testCantMintToZeroAddress() public {
        vm.startPrank(dsc.owner());
        vm.expectRevert(DWebThreePavlouStableCoin.DWebThreePavlouSC__NotZeroAddress.selector);
        dsc.mint(address(0), 100);
        vm.stopPrank();
    }

    function testOwnerCanSetMinterEmitsEventAndUpdatesState() public {
        address newMinter = address(123);

        vm.prank(dsc.owner());
        vm.expectEmit(true, true, false, true, address(dsc));
        emit MinterSet(address(0), newMinter);

        vm.prank(dsc.owner());
        dsc.setMinter(newMinter);

        assertEq(dsc.minter(), newMinter);
    }

    function testNonOwnerCannotSetMinter() public {
        address attacker = address(1);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        dsc.setMinter(address(123));
    }

    function testMinterCanMint() public {
        address minter = address(123);
        address to = address(456);

        // owner sets minter
        vm.prank(dsc.owner());
        dsc.setMinter(minter);

        // minter mints
        vm.prank(minter);
        dsc.mint(to, 100);

        assertEq(dsc.balanceOf(to), 100);
    }
}
