// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import "./interfaces/IFIAT.sol";

import "./utils/Guarded.sol";
import "./utils/Math.sol";

/// @title Fixed Income Asset Token (FIAT)
/// @notice `FIAT` is the protocol's stable asset which can be redeemed for `Credit` via `Moneta`
contract FIAT is Guarded, IFIAT {
    /// ======== Custom Errors ======== ///

    error FIAT__transferFrom_insufficientBalance();
    error FIAT__transferFrom_insufficientAllowance();
    error FIAT__burn_insufficientBalance();
    error FIAT__burn_insufficientAllowance();
    error FIAT__permit_ownerIsZero();
    error FIAT__permit_invalidOwner();
    error FIAT__permit_deadline();

    /// ======== Storage ======== ///

    /// @notice Name of the token
    string public constant override name = "Fixed Income Asset Token";
    /// @notice Symbol of the token
    string public constant override symbol = "FIAT";
    /// @notice Version of the token contract. Used by `permit`.
    string public constant override version = "1";
    /// @notice Uses WAD precision
    uint8 public constant override decimals = 18;
    /// @notice Amount of tokens in existence [wad]
    uint256 public override totalSupply;

    /// @notice Amount of tokens owned by `Account`
    /// @dev Account => Balance [wad]
    mapping(address => uint256) public override balanceOf;
    /// @notice Remaining amount of tokens that `spender` will be allowed to spend on behalf of `owner`
    /// @dev Owner => Spender => Allowance [wad]
    mapping(address => mapping(address => uint256)) public override allowance;
    /// @notice Current nonce for `owner`. This value must be included whenever a signature is generated for `permit`.
    /// @dev Account => nonce
    mapping(address => uint256) public override nonces;

    /// @notice Domain Separator used in the encoding of the signature for `permit`, as defined by EIP712 and EIP2612
    bytes32 public immutable override DOMAIN_SEPARATOR;
    /// @notice Hash of the permit data structure. Used to verify the callers signature for `permit`,
    /// as defined by EIP2612.
    bytes32 public immutable override PERMIT_TYPEHASH;

    /// ======== Events ======== ///

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor() Guarded() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                address(this)
            )
        );
        PERMIT_TYPEHASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
    }

    /// ======== ERC20 ======== ///

    /// @notice Transfers `amount` tokens from the caller's account to `to`
    /// @dev Boolean value indicating whether the operation succeeded
    /// @param to Address of the recipient
    /// @param amount Amount of tokens to transfer [wad]
    function transfer(address to, uint256 amount) external override returns (bool) {
        return transferFrom(msg.sender, to, amount);
    }

    /// @notice Transfers `amount` tokens from `from` to `to` using the allowance mechanism
    /// `amount` is then deducted from the caller's allowance
    /// @dev Boolean value indicating whether the operation succeeded
    /// @param from Address of the sender
    /// @param to Address of the recipient
    /// @param amount Amount of tokens to transfer [wad]
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (from != msg.sender) {
            uint256 allowance_ = allowance[from][msg.sender];
            if (allowance_ != type(uint256).max) {
                if (allowance_ < amount) revert FIAT__transferFrom_insufficientAllowance();
                allowance[from][msg.sender] = sub(allowance_, amount);
            }
        }

        if (balanceOf[from] < amount) revert FIAT__transferFrom_insufficientBalance();
        balanceOf[from] = sub(balanceOf[from], amount);
        unchecked {
            // Cannot overflow because the sum of all user balances can't exceed the max uint256 value.
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);
        return true;
    }

    /// @notice Sets `amount` as the allowance of `spender` over the caller's tokens
    /// @param spender Address of the spender
    /// @param amount Amount of tokens the spender is allowed to spend
    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// ======== Minting and Burning ======== ///

    /// @notice Increases the totalSupply by `amount` and transfers the new tokens to `to`
    /// @dev Sender has to be allowed to call this method
    /// @param to Address to which tokens should be credited to
    /// @param amount Amount of tokens to be minted [wad]
    function mint(address to, uint256 amount) external override checkCaller {
        totalSupply = add(totalSupply, amount);
        // Cannot overflow because the sum of all user balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    /// @notice Decreases the totalSupply by `amount` and using the tokens from `from`
    /// @dev If `from` is not the caller, caller needs to have sufficient allowance from `from`,
    /// `amount` is then deducted from the caller's allowance
    /// @param from Address from which tokens should be burned from
    /// @param amount Amount of tokens to be burned [wad]
    function burn(address from, uint256 amount) external override {
        if (from != msg.sender) {
            uint256 allowance_ = allowance[from][msg.sender];
            if (allowance_ != type(uint256).max) {
                if (allowance_ < amount) revert FIAT__transferFrom_insufficientAllowance();
                allowance[from][msg.sender] = sub(allowance_, amount);
            }
        }

        uint256 balance = balanceOf[from];
        if (balance < amount) revert FIAT__burn_insufficientBalance();
        balanceOf[from] = sub(balance, amount);

        // Cannot underflow because a user's balance
        // will never be larger than the total supply.
        unchecked {
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    /// ======== EIP2612 ======== ///

    /// @notice Sets `value` as the allowance of `spender` over `owner`'s tokens, given `owner`'s signed approval
    /// @dev Check that the `owner` cannot is not zero, that `deadline` is greater than the current block.timestamp
    /// and that the signature uses the `owner`'s current nonce
    /// @param owner Address of the owner who sets allowance for `spender`
    /// @param spender Address of the spender for is given allowance to
    /// @param value Amount of tokens the `spender` is allowed to spend
    /// @param v From the secp256k1 signature
    /// @param r From the secp256k1 signature
    /// @param s From the secp256k1 signature
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        unchecked {
            bytes32 digest = keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR,
                    // owner's nonce which cannot realistically overflow
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
                )
            );

            if (owner == address(0)) revert FIAT__permit_ownerIsZero();
            if (owner != ecrecover(digest, v, r, s)) revert FIAT__permit_invalidOwner();
            if (block.timestamp > deadline) revert FIAT__permit_deadline();

            allowance[owner][spender] = value;
            emit Approval(owner, spender, value);
        }
    }
}
