// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * AntiFraudGate - one reusable gate for launches and marketplaces on Robinhood Chain.
 *
 * It refuses the shapes farm wallets use, not the people who use wallets:
 *
 *   - contracts and EIP-7702 delegated wallets (automated / batched minters)
 *   - an owner-managed deny list (fraud, sanctions, a farm wallet with evidence)
 *   - more than `maxPerWallet` actions per wallet
 *   - two actions inside `cooldown` seconds
 *   - optionally, an action without an EIP-712 "signed pass" from a human check
 *
 * It does NOT geo-block. A country rule is defeated by a VPN and turns away
 * genuine collectors; the honest control is a deny list plus a signed pass that
 * costs a farm one human check per wallet.
 *
 * Settings are public, and lock when the sale opens so they cannot be changed
 * mid-launch.
 */
contract AntiFraudGate {
    // ------------------------------------------------------------------ config
    address public owner;
    bool public locked;                 // once true, config is frozen
    uint256 public maxPerWallet;        // 0 = no cap
    uint256 public cooldown;            // seconds between actions, 0 = off
    bool public requireSignedPass;      // EIP-712 pass required
    bool public blockContracts = true;  // reject contracts + EIP-7702 wallets
    address public passSigner;          // key allowed to sign passes

    mapping(address => bool) public denied;
    mapping(address => uint256) public count;      // actions per wallet
    mapping(address => uint256) public lastAction; // timestamp
    mapping(address => bool) public usedPass;      // a pass is single-use (nonce = wallet)

    bytes32 public constant PASS_TYPEHASH =
        keccak256("MintPass(address wallet,uint256 deadline)");

    event Denied(address indexed who, bool state);
    event ConfigLocked();
    event PassUsed(address indexed wallet, uint256 deadline);

    error NotOwner();
    error Locked();
    error IsContract();
    error Delegated();
    error IsDenied();
    error OverCap();
    error CoolingDown();
    error PassRequired();
    error PassUsedAlready();
    error PassExpired();
    error BadPass();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner) {
        owner = _owner;
        passSigner = _owner;
    }

    // ------------------------------------------------------------------ admin
    function setRule(
        uint256 _maxPerWallet,
        uint256 _cooldown,
        bool _requireSignedPass,
        bool _blockContracts,
        address _passSigner
    ) external onlyOwner {
        if (locked) revert Locked();
        maxPerWallet = _maxPerWallet;
        cooldown = _cooldown;
        requireSignedPass = _requireSignedPass;
        blockContracts = _blockContracts;
        if (_passSigner != address(0)) passSigner = _passSigner;
    }

    function setDenied(address who, bool state) public onlyOwner {
        denied[who] = state;
        emit Denied(who, state);
    }

    function setDeniedBatch(address[] calldata who, bool state) external onlyOwner {
        for (uint256 i; i < who.length; ++i) setDenied(who[i], state);
    }

    /// Freeze the rules. Irreversible on purpose: no changing the rules mid-launch.
    function lock() external onlyOwner {
        locked = true;
        emit ConfigLocked();
    }

    // ------------------------------------------------------------------ checks
    /// Convenience view for UIs and other contracts.
    function isAllowed(address who) public view returns (bool) {
        if (denied[who]) return false;
        if (blockContracts && who.code.length != 0) return false;
        if (maxPerWallet != 0 && count[who] >= maxPerWallet) return false;
        if (cooldown != 0 && lastAction[who] != 0 && block.timestamp < lastAction[who] + cooldown) {
            return false;
        }
        return true;
    }

    /**
     * Enforce the gate for `wallet`, optionally validating a signed pass.
     * Call this from your mint/buy path, then it records the action.
     *
     * `passSignature` is empty when no pass is required.
     */
    function enforce(address wallet, uint256 passDeadline, bytes calldata passSignature) public {
        if (denied[wallet]) revert IsDenied();
        if (blockContracts) {
            if (wallet.code.length != 0) {
                if (wallet.code.length >= 3 && _is7702(wallet)) revert Delegated();
                revert IsContract();
            }
        }
        if (maxPerWallet != 0 && count[wallet] >= maxPerWallet) revert OverCap();
        if (cooldown != 0 && lastAction[wallet] != 0 && block.timestamp < lastAction[wallet] + cooldown) {
            revert CoolingDown();
        }
        if (requireSignedPass) {
            if (passSignature.length == 0) revert PassRequired();
            if (usedPass[wallet]) revert PassUsedAlready();
            if (block.timestamp > passDeadline) revert PassExpired();
            bytes32 digest = keccak256(
                abi.encodePacked("\x19\x01", _domain(), keccak256(abi.encode(PASS_TYPEHASH, wallet, passDeadline)))
            );
            if (_recover(digest, passSignature) != passSigner) revert BadPass();
            usedPass[wallet] = true;
            emit PassUsed(wallet, passDeadline);
        }
        count[wallet] += 1;
        lastAction[wallet] = block.timestamp;
    }

    // ------------------------------------------------------------------ eip-712
    function domainSeparator() external view returns (bytes32) {
        return _domain();
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AntiFraudGate"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function _is7702(address who) internal view returns (bool) {
        // EIP-7702 delegated EOAs carry the 0xef0100 designator as their code.
        bytes memory code = who.code;
        return code.length >= 3 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00;
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        // reject malleable high-s values
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        return ecrecover(digest, v, r, s);
    }
}
