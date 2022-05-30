pragma solidity 0.7.6;

import "../dependencies/openzeppelin/contracts/IERC20.sol";
import "../dependencies/openzeppelin/contracts/SafeERC20.sol";
import "../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../interfaces/IMultiFeeDistribution.sol";

contract ICOLock {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IMultiFeeDistribution public immutable minter;
    uint256 public immutable maxMintableTokens;
    address public immutable owner;
    uint256 public totalMint;
    mapping(address => uint256) public userLockedAmount;

    constructor(
        IMultiFeeDistribution _minter,
        uint256 _maxMintable
    ) { 
        minter = _minter;
        maxMintableTokens = _maxMintable;
        owner = msg.sender;
    }

    function deposit(address[] memory _receivers, uint256[] memory _amounts) external {
        require(msg.sender == owner, "Only owner!");
        require(_receivers.length == _amounts.length, "Invalid input!");
        uint256 total;
        for (uint256 i = 0; i < _receivers.length; i++) {
            totalMint = totalMint.add(_amounts[i]);
            require(maxMintableTokens.sub(totalMint) >= 0, "Over limit!");
            userLockedAmount[_receivers[i]] =  _amounts[i];
            total = total.add(_amounts[i]);
            minter.mintLock(_receivers[i], _amounts[i]);
        }
        emit MintLocked(total, _receivers.length);
    }

    /* ========== EVENTS ========== */

    event MintLocked(uint256 amount, uint256 length);
}
