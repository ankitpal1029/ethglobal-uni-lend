// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title Token
 * @notice An ERC20 token with blacklist control and crosschain bridging features.
 */
contract MockERC20 is ERC20, Ownable2Step {
    /**
     * @notice An error thrown when the caller is not authorized to perform an action.
     */
    error Unauthorized();

    /**
     * @notice Emitted when a user's blacklist status changes.
     * @param user The user's address.
     * @param value True if blacklisted, false otherwise.
     */
    event BlacklistUpdated(address indexed user, bool value);

    /**
     * @notice Address of the SuperchainTokenBridge predeploy.
     */
    address internal constant SUPERCHAIN_TOKEN_BRIDGE = 0x4200000000000000000000000000000000000028;

    /**
     * @notice Tracks blacklisted addresses.
     */
    mapping(address => bool) private _blacklist;

    /**
     * @notice Creates a new ERC20 token.
     * @param name The name of the token.
     * @param symbol The symbol of the token.
     * @param initialSupply Initial token supply minted to the deployer.
     */
    constructor(string memory name, string memory symbol, uint256 initialSupply)
        ERC20(name, symbol)
        Ownable(msg.sender)
    {
        _mint(msg.sender, initialSupply);
    }

    /**
     * @notice Returns the number of decimals used by the token (18).
     */
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /**
     * @notice Updates the blacklist status for a user.
     * @param user The user's address.
     * @param value True to blacklist the user, false to remove them from blacklist.
     */
    function blacklistUpdate(address user, bool value) external virtual onlyOwner {
        _blacklist[user] = value;
        emit BlacklistUpdated(user, value);
    }

    /**
     * @notice Checks if a user is blacklisted.
     * @param user The user's address.
     * @return True if blacklisted, false otherwise.
     */
    function isBlackListed(address user) public view returns (bool) {
        return _blacklist[user];
    }
    /**
     * @dev Overriding `_update` to insert custom logic for all transfers,
     *      including minting (from == address(0)) and burning (to == address(0)).
     */

    function _update(address from, address to, uint256 amount) internal virtual override {
        require(!isBlackListed(to) && !isBlackListed(from), "Token transfer refused. Receiver is on blacklist");
        super._update(from, to, amount);
    }
}
