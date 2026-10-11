// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC2981 } from "@openzeppelin/contracts/token/common/ERC2981.sol";
import { AntiFraudGate } from "../src/AntiFraudGate.sol";
import { GoodsMarket } from "../src/GoodsMarket.sol";

contract MockNFT is ERC721, ERC2981 {
    constructor() ERC721("Mock", "MOCK") {
        _setDefaultRoyalty(address(0xBEEF), 500); // 5%
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function supportsInterface(bytes4 i) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(i);
    }
}

contract BuyerContract {
    function go(GoodsMarket m, uint256 id) external payable {
        m.buy{ value: msg.value }(id, 0, "");
    }

    receive() external payable {}
}

contract GoodsMarketTest is Test {
    MockNFT nft;
    AntiFraudGate gate;
    GoodsMarket market;
    address treasury = address(0xFEE);
    address seller = address(0x5E11E5);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        nft = new MockNFT();
        gate = new AntiFraudGate(address(this));
        market = new GoodsMarket(address(nft), address(gate), treasury, 200); // 2%
        nft.mint(seller, 1);
    }

    function _list(uint256 price) internal returns (uint256 id) {
        vm.prank(seller);
        nft.setApprovalForAll(address(market), true);
        vm.prank(seller);
        id = market.list(1, price);
    }

    function testBuyPaysSellerFeeAndRoyalty() public {
        uint256 id = _list(1 ether);
        vm.deal(alice, 1 ether);
        uint256 sellerBefore = seller.balance;
        vm.prank(alice, alice);
        market.buy{ value: 1 ether }(id, 0, "");
        assertEq(nft.ownerOf(1), alice);
        assertEq(treasury.balance, 0.02 ether);              // 2% fee
        assertEq(address(0xBEEF).balance, 0.05 ether);       // 5% royalty
        assertEq(seller.balance - sellerBefore, 0.93 ether); // remainder
    }

    function testGateBlocksContractBuyer() public {
        uint256 id = _list(1 ether);
        BuyerContract bc = new BuyerContract();
        vm.deal(address(bc), 1 ether);
        vm.expectRevert(); // SelfTrade: buyer has code
        bc.go{ value: 1 ether }(market, id);
    }

    function testSellerCannotBuyOwnListing() public {
        uint256 id = _list(1 ether);
        vm.deal(seller, 1 ether);
        vm.prank(seller, seller);
        vm.expectRevert(GoodsMarket.SelfTrade.selector);
        market.buy{ value: 1 ether }(id, 0, "");
    }

    function testPerWalletCapEnforced() public {
        gate.setRule(1, 0, false, true, address(0));
        nft.mint(seller, 2);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(market), true);
        uint256 id1 = market.list(1, 1 ether);
        uint256 id2 = market.list(2, 1 ether);
        vm.stopPrank();

        vm.deal(alice, 2 ether);
        vm.prank(alice, alice);
        market.buy{ value: 1 ether }(id1, 0, "");
        vm.prank(alice, alice);
        vm.expectRevert(AntiFraudGate.OverCap.selector);
        market.buy{ value: 1 ether }(id2, 0, "");
    }

    function testDenyListBlocks() public {
        gate.setDenied(alice, true);
        uint256 id = _list(1 ether);
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(AntiFraudGate.IsDenied.selector);
        market.buy{ value: 1 ether }(id, 0, "");
    }

    function testSignedPassRequired() public {
        (address signer, uint256 pk) = makeAddrAndKey("passer");
        gate.setRule(0, 0, true, true, signer);
        uint256 id = _list(1 ether);
        vm.deal(alice, 1 ether);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                gate.domainSeparator(),
                keccak256(abi.encode(gate.PASS_TYPEHASH(), alice, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(alice, alice);
        market.buy{ value: 1 ether }(id, deadline, sig);
        assertEq(nft.ownerOf(1), alice);

        // a pass can't be reused
        nft.mint(seller, 3);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(market), true);
        uint256 id3 = market.list(3, 1 ether);
        vm.stopPrank();
        vm.deal(alice, 1 ether); // she spent her balance on the first buy
        vm.prank(alice, alice);
        vm.expectRevert(AntiFraudGate.PassUsedAlready.selector);
        market.buy{ value: 1 ether }(id3, deadline, sig);
    }

    function testConfigLocks() public {
        gate.lock();
        vm.expectRevert(AntiFraudGate.Locked.selector);
        gate.setRule(5, 0, false, true, address(0));
    }

    function testCancelReturnsNFT() public {
        uint256 id = _list(1 ether);
        vm.prank(seller);
        market.cancel(id);
        assertEq(nft.ownerOf(1), seller);
    }
}
