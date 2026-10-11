// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AntiFraudGate } from "./AntiFraudGate.sol";

/**
 * GoodsMarket - a small, honest fixed-price marketplace for Robinhood Chain.
 *
 * Why a second marketplace when Seaport already exists: Seaport handles matching
 * and settlement beautifully, but it has no opinion about who may buy. Launches
 * get farmed and floors get wash-traded because the buyer side is open. This
 * contract is the buyer-side control we wanted, kept simple enough to audit.
 *
 * Rules:
 *   - Seller escrows the NFT in this contract (no half-signed listings).
 *   - Every buy passes AntiFraudGate: no contract/automated buyers, deny list,
 *     per-wallet cap, cooldown.
 *   - ERC-2981 royalties are paid automatically when the NFT declares them.
 *   - A marketplace fee goes to the treasury.
 *   - The seller can never buy their own listing (it is escrowed, and the
 *     seller address is checked explicitly), and a buyer cannot buy the same
 *     token twice.
 */
contract GoodsMarket is ReentrancyGuard {
    struct Listing {
        address seller;
        address nft;
        uint256 tokenId;
        uint256 price;
        bool active;
    }

    IERC721 public immutable collection; // one market per collection keeps it simple
    AntiFraudGate public immutable gate;
    address public treasury;
    uint96 public feeBps; // marketplace fee, basis points

    uint256 public nextListingId = 1;
    mapping(uint256 => Listing) public listings;

    event Listed(uint256 indexed id, address indexed seller, uint256 tokenId, uint256 price);
    event Cancelled(uint256 indexed id);
    event Sold(uint256 indexed id, address indexed buyer, uint256 price, uint256 fee, uint256 royalty);

    error NotOwner();
    error BadPrice();
    error NotSeller();
    error Inactive();
    error SelfTrade();
    error FeeTooHigh();

    constructor(address _collection, address _gate, address _treasury, uint96 _feeBps) {
        require(_feeBps <= 1000, "fee<=10%");
        collection = IERC721(_collection);
        gate = AntiFraudGate(_gate);
        treasury = _treasury;
        feeBps = _feeBps;
    }

    /// Seller lists a token. The NFT is escrowed here so no listing can be pulled.
    function list(uint256 tokenId, uint256 price) external returns (uint256 id) {
        if (price == 0) revert BadPrice();
        collection.transferFrom(msg.sender, address(this), tokenId);
        id = nextListingId++;
        listings[id] = Listing(msg.sender, address(collection), tokenId, price, true);
        emit Listed(id, msg.sender, tokenId, price);
    }

    function cancel(uint256 id) external {
        Listing storage L = listings[id];
        if (!L.active) revert Inactive();
        if (msg.sender != L.seller) revert NotSeller();
        L.active = false;
        collection.transferFrom(address(this), L.seller, L.tokenId);
        emit Cancelled(id);
    }

    /**
     * Buy a listing. `passDeadline`/`passSignature` are forward to the gate and
     * may be empty when the gate does not require a signed pass.
     */
    function buy(uint256 id, uint256 passDeadline, bytes calldata passSignature) external payable nonReentrant {
        Listing storage L = listings[id];
        if (!L.active) revert Inactive();
        if (msg.value != L.price) revert BadPrice();
        if (msg.sender == L.seller) revert SelfTrade();
        // a contract can never be the buyer, even if the gate is reconfigured
        if (msg.sender.code.length != 0 || msg.sender != tx.origin) revert SelfTrade();

        gate.enforce(msg.sender, passDeadline, passSignature);

        L.active = false;

        uint256 fee = (L.price * feeBps) / 10_000;
        uint256 royalty = _royalty(L.tokenId, L.price);

        // pay royalty first (a failing receiver must not trap the sale)
        if (royalty != 0 && royalty <= L.price - fee) {
            (address receiver,) = IERC2981(L.nft).royaltyInfo(L.tokenId, L.price);
            if (receiver != address(0)) {
                (bool ok,) = receiver.call{ value: royalty }("");
                if (!ok) royalty = 0; // skip rather than revert the whole sale
            }
        } else {
            royalty = 0;
        }

        if (fee != 0) {
            (bool okFee,) = treasury.call{ value: fee }("");
            if (!okFee) fee = 0;
        }

        uint256 toSeller = L.price - fee - royalty;
        (bool okSeller,) = L.seller.call{ value: toSeller }("");
        require(okSeller, "seller pay failed");

        collection.transferFrom(address(this), msg.sender, L.tokenId);
        emit Sold(id, msg.sender, L.price, fee, royalty);
    }

    function _royalty(uint256 tokenId, uint256 price) internal view returns (uint256) {
        try IERC2981(address(collection)).royaltyInfo(tokenId, price) returns (address, uint256 amt) {
            return amt > price ? 0 : amt;
        } catch {
            return 0;
        }
    }

    // ------------------------------------------------------------------ admin
    function setFee(uint96 bps) external {
        if (msg.sender != treasury) revert NotOwner();
        if (bps > 1000) revert FeeTooHigh();
        feeBps = bps;
    }

    function setTreasury(address t) external {
        if (msg.sender != treasury) revert NotOwner();
        treasury = t;
    }
}
