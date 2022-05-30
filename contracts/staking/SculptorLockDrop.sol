pragma solidity 0.7.6;

import "../dependencies/openzeppelin/contracts/IERC20.sol";
import "../dependencies/openzeppelin/contracts/SafeERC20.sol";
import "../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../interfaces/IMultiFeeDistribution.sol";
import "../dependencies/openzeppelin/contracts/Ownable.sol";
import "../dependencies/openzeppelin/contracts/ReentrancyGuard.sol";

import "../interfaces/ILendingPool.sol";

contract SculptorLockDrop is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 shares;
        uint256 unlockTime;
        uint256 rewardPaid;
    }

    struct LockInfo {
        uint256 multiplier;
        uint256 duration;
        uint256 totalBalances;
    }

    address public immutable rewardToken;
    address public immutable stakedToken;
    address public immutable lendingPool;

    uint256 public startTime;
    bool public lockedStatus;
    LockInfo[] public lockInfo;
    // userAddress => lockIndex => info
    mapping(address => mapping(uint256 => UserInfo)) public userInfo;

    uint256 public totalRewardPaid;
    uint256 public maxRewardSupply;
    uint256 public sharesTotal;

    mapping(address => bool) private userRewardPaid;
    mapping(address => uint256) private userBalances;

    constructor(
        address _stakedToken,
        address _rewardToken,
        address _lendingPool,
        uint256[] memory _duration,
        uint256[] memory _multiplier
    ) {
        require(_duration.length == _multiplier.length);
        rewardToken = _rewardToken;
        stakedToken = _stakedToken;
        lendingPool = _lendingPool;
        for (uint i; i < _duration.length; i++) {
            lockInfo.push(LockInfo({
                multiplier: _multiplier[i],
                duration: _duration[i],
                totalBalances: 0
            }));
        }
    }

    /* ========== VIEW FUNCTION ========== */

    function lockInfoLength() public view returns (uint256)  {
        uint256 length = lockInfo.length;
        return length;
    }

    function totalSupply() public view returns (uint256)  {
        return IERC20(stakedToken).balanceOf(address(this));
    }

    function sharesToBalances(uint256 amount) external view returns (uint256) {
        if (sharesTotal == 0) {
            return 0;
        }
        uint256 balances = amount.mul(totalSupply()).div(sharesTotal);
        return balances;
    }

    function availableLockToken(address _user) public view returns (uint256)  {
        (, ,uint256 avl, , ,) = ILendingPool(lendingPool).getUserAccountData(_user);
        return avl;
    }

    /* ========== SETTING ========== */

    function start() external onlyOwner {
        require(startTime == 0);
        startTime = block.timestamp;
    }

    function end() external onlyOwner {
        lockedStatus = true;
    }

    function startRewardPaid(uint256 _amount) external onlyOwner {
        require(startTime > 0, "Not started yet.");
        require(maxRewardSupply == 0);
        require(lockedStatus, "Start reward after end deposited.");
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), _amount);
        maxRewardSupply = _amount;
    }

    function calculateRewardPaid(address _user) external view returns (uint256) {
        uint256 reward = _userRewardWeight(_user);
        return reward;
    }

    function totalSupplyWeight() external view returns (uint256) {
        uint256 total = _totalSupplyWeight();
        return total;
    }

    /* ========== MUTATIVE FUNCTION ========== */

    function deposit(uint256 _amount, uint256 _lockIndex) external nonReentrant {
        LockInfo storage lock = lockInfo[_lockIndex];
        require(_amount > 0, "Cannot be zero.");
        require(startTime > 0, "Not starting yet.");
        require(!lockedStatus, "Already ended period.");
        require(lock.duration > 0, "Invalid lock index.");
        uint256 unlockTime = block.timestamp.add(lock.duration);
        // update balance and unlockTime
        UserInfo storage user = userInfo[msg.sender][_lockIndex];
        if(user.unlockTime == 0) {
            user.unlockTime = unlockTime;
        }
        // calculate user shares
        uint256 sharesAdded = _amount;
        if (totalSupply() > 0) {
            sharesAdded = _amount
                .mul(sharesTotal)
                .div(totalSupply());
        }
        sharesTotal = sharesTotal.add(sharesAdded);
        user.shares = user.shares.add(sharesAdded);
        userBalances[msg.sender] = userBalances[msg.sender].add(sharesAdded);
        lock.totalBalances = lock.totalBalances.add(sharesAdded);
        IERC20(stakedToken).safeTransferFrom(msg.sender, address(this), _amount);

        emit Deposited(msg.sender, _amount, _lockIndex);
    }

    function getReward() external nonReentrant {
        require(!userRewardPaid[msg.sender], "User already got reward.");
        require(startTime > 0, "Not started yet!");
        require(lockedStatus, "Must ended lock period.");

        uint256 totalRemainReward = IERC20(rewardToken).balanceOf(address(this));
        require(totalRemainReward > 0, "No reward!");
        uint256 reward = _userRewardWeight(msg.sender);
        if(reward > 0){
            userRewardPaid[msg.sender] = true;
            totalRewardPaid = totalRewardPaid.add(reward);
            IERC20(rewardToken).safeTransfer(msg.sender, reward);
        }

        emit RewardPaid(msg.sender, reward);
    }

    function withdraw(uint256 index) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender][index];
        LockInfo storage lock = lockInfo[index];
        uint256 withdrawShares = user.shares;
        require(user.unlockTime <= block.timestamp, "Cant unlock!");
        require(withdrawShares > 0, "No token for unlock!");
        user.shares = 0;
        user.unlockTime = 0;
        uint256 amountRemove = withdrawShares.mul(totalSupply()).div(sharesTotal);
        // shared removed //
        if (withdrawShares > sharesTotal) {
            withdrawShares = sharesTotal;
        }
        sharesTotal = sharesTotal.sub(withdrawShares);
        lock.totalBalances = lock.totalBalances.sub(withdrawShares);
        require(userBalances[msg.sender] >= withdrawShares, "Not enough token!");
        userBalances[msg.sender] = userBalances[msg.sender].sub(withdrawShares);
        require(totalSupply() >= amountRemove, "Not enough token!");
        IERC20(stakedToken).safeTransfer(msg.sender, amountRemove);
        emit Withdrawn(msg.sender, amountRemove, index);
    }

    function withdrawAll() external nonReentrant {
        uint256 withdrawShares;
        for (uint i; i < lockInfo.length; i++) {
            UserInfo storage user = userInfo[msg.sender][i];
            LockInfo storage lock = lockInfo[i];
            if(user.unlockTime <= block.timestamp) {
                lock.totalBalances = lock.totalBalances.sub(user.shares);
                withdrawShares = withdrawShares.add(user.shares);
                user.shares = 0;
                user.unlockTime = 0;
            }
        }
        // shared removed //
        if (withdrawShares > sharesTotal) {
            withdrawShares = sharesTotal;
        }
        // transfer withdraw amount
        uint256 withdrawAmount = withdrawShares.mul(totalSupply()).div(sharesTotal);
        sharesTotal = sharesTotal.sub(withdrawShares);
        require(userBalances[msg.sender] >= withdrawShares, "Not enough token!");
        userBalances[msg.sender] = userBalances[msg.sender].sub(withdrawShares);
        require(totalSupply() >= withdrawAmount, "Not enough token!");
        IERC20(stakedToken).safeTransfer(msg.sender, withdrawAmount);
        emit WithdrawnAll(msg.sender, withdrawAmount);
    }

    /* ========== INTERNAL FUNCTION ========== */

    function _totalSupplyWeight() internal view returns (uint256) {
        uint256 total;
        for (uint i; i < lockInfo.length; i++) {
            LockInfo storage lock = lockInfo[i];
            uint256 weight = lock.totalBalances.mul(lock.multiplier);
            total = total.add(weight);
        }
        return total;
    }

    function _userRewardWeight(address _user) internal view returns (uint256) {
        uint256 totalPending;
        uint256 totalSupplyWeight = _totalSupplyWeight();
        if(totalSupplyWeight == 0) return 0;
        for (uint i; i < lockInfo.length; i++) {
            UserInfo storage user = userInfo[_user][i];
            uint256 weightBalance = user.shares.mul(lockInfo[i].multiplier);
            uint256 pending = weightBalance.mul(maxRewardSupply).div(totalSupplyWeight);
            totalPending = totalPending.add(pending);
        }
        return totalPending;
    }


    /* ========== EVENTS ========== */

    event Deposited(address indexed user, uint256 amount, uint256 index);
    event RewardPaid(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 index);
    event WithdrawnAll(address indexed user, uint256 amount);

}
