// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AntiFraudGate } from "./AntiFraudGate.sol";

/**
 * FairLaunch - a primary sale that a farm cannot take.
 *
 * The owner deposits NFTs and prices them. Buyers pay the fixed price. Every buy
 * passes AntiFraudGate and a per-block global cap, so one script cannot sweep the
 * whole launch in a single block while real people are still reading the page.
 *
 * This contract does NOT enforce a post-mint transfer cooldown: that has to live
 * in the NFT itself (a transfer delay the token honours), because a sale contract
 * cannot stop the buyer from moving the token afterwards. Say so on the mint page
 * rather than implying the launch contract does it.
 */
contract FairLaunch is ReentrancyGuard {
    IERC721 public immutable nft;
    AntiFraudGate public immutable gate;
    address public owner;
    address public treasury;
    uint96 public feeBps;

    uint256 public price;
    uint256 public perBlockCap;      // 0 = unlimited

    bool public paused;

    mapping(uint256 => bool) public forSale;
    uint256 public soldCount;

    uint256 private _blockOf;
    uint256 private _inBlock;

    event Deposited(uint256 indexed tokenId);
    event Withdrawn(uint256 indexed tokenId);
    event Sold(uint256 indexed tokenId, address indexed buyer, uint256 price);
    event Paused(bool state);

    error NotOwner();
    error PausedOrSold();
    error NotForSale();
    error WrongPrice();
    error BlockCapReached();
    error FeeTooHigh();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _nft, address _gate, address _treasury, uint256 _price, uint96 _feeBps, uint256 _perBlockCap) {
        require(_feeBps <= 1000, "fee<=10%");
        nft = IERC721(_nft);
        gate = AntiFraudGate(_gate);
        owner = msg.sender;
        treasury = _treasury;
        price = _price;
        feeBps = _feeBps;
        perBlockCap = _perBlockCap;
    }

    // ------------------------------------------------------------------ owner
    /// Deposit a token the contract will sell. The owner must have approved this contract.
    function deposit(uint256 tokenId) external onlyOwner {
        nft.transferFrom(msg.sender, address(this), tokenId);
        forSale[tokenId] = true;
        emit Deposited(tokenId);
    }

    function depositBatch(uint256[] calldata tokenIds) external onlyOwner {
        for (uint256 i; i < tokenIds.length; ++i) {
            nft.transferFrom(msg.sender, address(this), tokenIds[i]);
            forSale[tokenIds[i]] = true;
            emit Deposited(tokenIds[i]);
        }
    }

    function withdraw(uint256 tokenId) external onlyOwner {
        forSale[tokenId] = false;
        nft.transferFrom(address(this), owner, tokenId);
        emit Withdrawn(tokenId);
    }

    function setPrice(uint256 p) external onlyOwner { price = p; }
    function setPerBlockCap(uint256 c) external onlyOwner { perBlockCap = c; }
    function setPaused(bool p) external onlyOwner { paused = p; emit Paused(p); }

    function setTreasury(address t) external onlyOwner { treasury = t; }
    function setFee(uint96 bps) external onlyOwner { if (bps > 1000) revert FeeTooHigh(); feeBps = bps; }

    // ------------------------------------------------------------------ buy
    function buy(uint256 tokenId, uint256 passDeadline, bytes calldata passSignature)
        external
        payable
        nonReentrant
    {
        if (paused) revert PausedOrSold();
        if (!forSale[tokenId]) revert NotForSale();
        if (msg.value != price) revert WrongPrice();

        // per-block global cap: one script cannot clear the launch in one block
        if (block.number != _blockOf) { _blockOf = block.number; _inBlock = 0; }
        if (perBlockCap != 0 && _inBlock >= perBlockCap) revert BlockCapReached();
        _inBlock += 1;

        // the gate: not a contract / automated wallet, not denied, under the caps
        gate.enforce(msg.sender, passDeadline, passSignature);

        forSale[tokenId] = false;
        soldCount += 1;

        uint256 fee = (price * feeBps) / 10_000;
        if (fee != 0) {
            (bool okFee,) = treasury.call{ value: fee }("");
            if (!okFee) fee = 0;
        }
        uint256 toOwner = price - fee;
        if (toOwner != 0) {
            (bool ok,) = owner.call{ value: toOwner }("");
            require(ok, "owner pay failed");
        }

        nft.transferFrom(address(this), msg.sender, tokenId);
        emit Sold(tokenId, msg.sender, price);
    }
}