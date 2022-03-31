// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import "../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../dependencies/openzeppelin/contracts/IERC20.sol";
import "../dependencies/openzeppelin/contracts/Ownable.sol";

interface IUniswapLPToken {
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);
}

interface IMultiFeeDistribution {
    function lockedBalances(address user) view external returns (uint256);
    function lockedSupply() external view returns (uint256);
}

contract ProtocolOwnedDEXLiquidity is Ownable {

    using SafeMath for uint256;

    IUniswapLPToken constant public lpToken = IUniswapLPToken(0x21EFFCCB384fC8996D8b1df5D9Ba1f9732efaa18);
    IERC20 constant public sFTM = IERC20(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    IMultiFeeDistribution constant public treasury = IMultiFeeDistribution(0x7c32f68811C7de69fB3C26E0ED47b823fBDcF795);

    struct UserRecord {
        uint256 nextClaimTime;
        uint256 claimCount;
        uint256 totalBoughtFTM;
    }

    mapping (address => UserRecord) public userData;

    uint public totalSoldFTM;
    uint public minBuyAmount;
    uint public minSuperPODLLock;
    uint public buyCooldown;
    uint public superPODLCooldown;
    uint public lockedBalanceMultiplier;

    event SoldFTM(
        address indexed buyer,
        uint256 amount
    );
    event AaaaaaahAndImSuperPODLiiiiing(
        address indexed podler,
        uint256 amount
    );

    constructor(
        uint256 _lockMultiplier,
        uint256 _minBuy,
        uint256 _minLock,
        uint256 _cooldown,
        uint256 _podlCooldown
    ) Ownable() {
        setParams(_lockMultiplier, _minBuy, _minLock, _cooldown, _podlCooldown);
    }

    /**
     * @notice Checks if the msg.sender is a contract or a proxy
     */
    modifier notContract() {
        require(!_isContract(msg.sender), "contract not allowed");
        require(msg.sender == tx.origin, "proxy contract not allowed");
        _;
    }

    function setParams(
        uint256 _lockMultiplier,
        uint256 _minBuy,
        uint256 _minLock,
        uint256 _cooldown,
        uint256 _podlCooldown
    ) public onlyOwner {
        require(_minBuy >= 1e17); // minimum buy is 0.1 lp
        lockedBalanceMultiplier = _lockMultiplier;
        minBuyAmount = _minBuy;
        minSuperPODLLock = _minLock;
        buyCooldown = _cooldown;
        superPODLCooldown = _podlCooldown;
    }

    function protocolOwnedReserves() public view returns (uint256 wftm, uint256 sculp) {
        (uint reserve0, uint reserve1,) = lpToken.getReserves();
        uint balance = lpToken.balanceOf(address(this));
        uint totalSupply = lpToken.totalSupply();
        return (reserve0.mul(balance).div(totalSupply), reserve1.mul(balance).div(totalSupply));
    }

    function availableFTM() public view returns (uint256) {
        return sFTM.balanceOf(address(this)) / 2;
    }

    function availableForUser(address _user) public view returns (uint256) {
        UserRecord storage u = userData[_user];
        if (u.nextClaimTime > block.timestamp) return 0;
        uint available = availableFTM();
        uint userLocked = treasury.lockedBalances(_user);
        uint totalLocked = treasury.lockedSupply();
        uint amount = available.mul(lockedBalanceMultiplier).mul(userLocked).div(totalLocked);
        if (amount > available) {
            return available;
        }
        return amount;
    }

    function lpTokensPerOneFTM() public view returns (uint256) {
        uint totalSupply = lpToken.totalSupply();
        (uint reserve0,,) = lpToken.getReserves();
        return totalSupply.mul(1e18).mul(45).div(reserve0).div(100);
    }

    function _buy(uint _amount, uint _cooldownTime) internal {
        require(_amount >= minBuyAmount, "Below min buy amount");

        UserRecord storage u = userData[msg.sender];
        require(block.timestamp >= u.nextClaimTime, "Claimed too recently");
        u.nextClaimTime = block.timestamp.add(_cooldownTime);
        u.claimCount = u.claimCount.add(1);
        u.totalBoughtFTM = u.totalBoughtFTM.add(_amount);
        totalSoldFTM = totalSoldFTM.add(_amount);

        uint lpAmount = _amount.mul(lpTokensPerOneFTM()).div(1e18);
        lpToken.transferFrom(msg.sender, address(this), lpAmount);
        sFTM.transfer(msg.sender, _amount);
        sFTM.transfer(address(treasury), _amount);

        emit SoldFTM(msg.sender, _amount);
    }

    function buyFTM(uint256 _amount) public notContract {
        require(_amount <= availableForUser(msg.sender), "Amount exceeds user limit");
        _buy(_amount, buyCooldown);
    }

    function superPODL(uint256 _amount) public notContract {
        require(treasury.lockedBalances(msg.sender) >= minSuperPODLLock, "Need to lock SCULP!");
        _buy(_amount, superPODLCooldown);
        emit AaaaaaahAndImSuperPODLiiiiing(msg.sender, _amount);
    }

    /**
     * @notice Checks if address is a contract
     * @dev It prevents contract from being targetted
     */
    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}
