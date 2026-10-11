// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { AntiFraudGate } from "../src/AntiFraudGate.sol";
import { FairLaunch } from "../src/FairLaunch.sol";

contract Nft is ERC721 {
    constructor() ERC721("N", "N") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

contract FairLaunchTest is Test {
    receive() external payable {}
    Nft nft;
    AntiFraudGate gate;
    FairLaunch launch;
    address treasury = address(0xFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        nft = new Nft();
        gate = new AntiFraudGate(address(this));
        launch = new FairLaunch(address(nft), address(gate), treasury, 0.1 ether, 200, 2); // cap 2 per block
        for (uint256 i = 1; i <= 5; ++i) nft.mint(address(this), i);
        nft.setApprovalForAll(address(launch), true);
        uint256[] memory ids = new uint256[](5);
        for (uint256 i; i < 5; ++i) ids[i] = i + 1;
        launch.depositBatch(ids);
    }

    function testBuyPaysOwnerAndTreasury() public {
        vm.deal(alice, 1 ether);
        uint256 ownerBefore = address(this).balance;
        vm.prank(alice, alice);
        launch.buy{ value: 0.1 ether }(1, 0, "");
        assertEq(nft.ownerOf(1), alice);
        assertEq(treasury.balance, 0.002 ether);                 // 2%
        assertEq(address(this).balance - ownerBefore, 0.098 ether);
    }

    function testWrongPriceReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(FairLaunch.WrongPrice.selector);
        launch.buy{ value: 0.09 ether }(1, 0, "");
    }

    function testPerBlockCapBlocksTheSweep() public {
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.prank(alice, alice);
        launch.buy{ value: 0.1 ether }(1, 0, "");
        vm.prank(bob, bob);
        launch.buy{ value: 0.1 ether }(2, 0, "");
        // third buy in the same block is refused
        vm.prank(alice, alice);
        vm.expectRevert(FairLaunch.BlockCapReached.selector);
        launch.buy{ value: 0.1 ether }(3, 0, "");
        // next block it works again
        vm.roll(block.number + 1);
        vm.prank(alice, alice);
        launch.buy{ value: 0.1 ether }(3, 0, "");
        assertEq(nft.ownerOf(3), alice);
    }

    function testGateBlocksContractBuyer() public {
        // 0xC0DE is an EOA with no code, so exercise the deny list instead
        gate.setDenied(address(0xC0DE), true);
        vm.deal(address(0xC0DE), 1 ether);
        vm.prank(address(0xC0DE), address(0xC0DE));
        vm.expectRevert(AntiFraudGate.IsDenied.selector);
        launch.buy{ value: 0.1 ether }(1, 0, "");
    }

    function testPauseStopsSales() public {
        launch.setPaused(true);
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(FairLaunch.PausedOrSold.selector);
        launch.buy{ value: 0.1 ether }(1, 0, "");
    }

    function testWithdrawReturnsUnsold() public {
        launch.withdraw(4);
        assertEq(nft.ownerOf(4), address(this));
    }
}