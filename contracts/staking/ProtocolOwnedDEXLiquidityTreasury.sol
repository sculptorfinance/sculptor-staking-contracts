// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

import "../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../dependencies/openzeppelin/contracts/IERC20.sol";
import "../dependencies/openzeppelin/contracts/Ownable.sol";
import "../interfaces/IChefIncentivesController.sol";
import "../interfaces/IChainlinkAggregator.sol";
import "../interfaces/IExampleOracleSimple.sol";

import "../misc/libraries/Math.sol";

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
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IMultiFeeDistribution {
    struct LockedBalance {
        uint256 amount;
        uint256 unlockTime;
    }
    function lockedBalances(address user) view external returns (
        uint256 total,
        uint256 unlockable,
        uint256 locked,
        LockedBalance[] memory lockData
    );
    function lockedSupply() external view returns (uint256);
}

contract ProtocolOwnedDEXLiquidityTreasury is Ownable {
    using SafeMath for uint256;

    IChainlinkAggregator constant public chainlinkBNB = IChainlinkAggregator(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE);
    IUniswapLPToken constant public lpToken = IUniswapLPToken(0xca6C8AbF738083b8Fa94708dC84E67E0140668c3);
    IERC20 public constant sBNB = IERC20(0x5A9397ef9e7bf71aaCb252D6269f3970C406cd77);
    address public constant sculptor = 0xD33821A398A27170baF8B580ef2093c35a7a500E;
    IMultiFeeDistribution constant public treasury = IMultiFeeDistribution(0xf7720bbC7512835B1429e69427f596b00e92CF70);
    address constant public burn = 0x1b927c7FB03da8274e2fADA7536a4F34E4D52c61; // burn lp
    IExampleOracleSimple public oracle = IExampleOracleSimple(0xaBcD5677aDfEBA8e1b28235E040d061Da32eBDF2);

    struct UserRecord {
        uint256 nextClaimTime;
        uint256 claimCount;
        uint256 totalBoughtBNB;
    }

    mapping (address => UserRecord) public userData;

    uint public totalSoldBNB;
    uint public minBuyAmount;
    uint public minSuperPODLLock;
    uint public buyCooldown;
    uint public superPODLCooldown;
    uint public lockedBalanceMultiplier;

    uint256 public bnbPerSculpt;
    address public admin;

    event SoldBNB(
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
        IChefIncentivesController chef = IChefIncentivesController(0xd59032FD054D85C35AcF656562d85f38a773EB9E);
        chef.setClaimReceiver(address(this), address(treasury));
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

    /**
     * @notice Checks if the msg.sender is the admin address
     */
    modifier onlyAdmin() {
        require(msg.sender == admin, "admin: wut?");
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

    function protocolOwnedReserves() public view returns (uint256 wbnb, uint256 sculpt) {
        (uint reserve0, uint reserve1,) = lpToken.getReserves();
        uint balance = lpToken.balanceOf(burn);
        uint totalSupply = lpToken.totalSupply();
        return (reserve0.mul(balance).div(totalSupply), reserve1.mul(balance).div(totalSupply));
    }

    function availableBNB() public view returns (uint256) {
        return sBNB.balanceOf(address(this)) / 2;
    }

    function availableForUser(address _user) public view returns (uint256) {
        UserRecord storage u = userData[_user];
        if (u.nextClaimTime > block.timestamp) return 0;
        uint available = availableBNB();
        (uint userLocked, , ,) = treasury.lockedBalances(_user);
        uint totalLocked = treasury.lockedSupply();
        uint amount = available.mul(lockedBalanceMultiplier).mul(userLocked).div(totalLocked);
        if (amount > available) {
            return available;
        }
        return amount;
    }

    function update() external onlyAdmin {
        // update oracle
        oracle.update();
        // 1 sculpt per bnb
        bnbPerSculpt = oracle.consult(sculptor, 1e18);
    }

    function lpTokensPerOneBNB() public view returns (uint256) {
        uint256 value = fairPriceLp().mul(1e18).div(_chainlinkPrice());
        return value;
    }

    function fairPriceLp() public view returns (uint256) {
        uint totalSupply = lpToken.totalSupply();
        (uint256 Res0, uint256 Res1,) = lpToken.getReserves();
        (uint256 sculptReserve, uint256 bnbReserve) = lpToken.token0() == sculptor ? (Res0, Res1) : (Res1, Res0); 
        // sculpt price by bnbPerSculpt * bnbPrice in usd
        uint256 p0 = bnbPerSculpt.mul(_chainlinkPrice()).div(1e18);
        // bnb price in usd
        uint256 p1 =  _chainlinkPrice();

        uint256 value0 = p0.mul(sculptReserve); // sculptor value
        uint256 value1 = p1.mul(bnbReserve); // bnb value

        uint256 x = Math.sqrt(value0*value1).div(totalSupply);
        return (2 * x) ;

    }

    function _chainlinkPrice() internal view returns (uint256) {
        int256 ans = chainlinkBNB.latestAnswer();
        uint256 price = uint256(ans).mul(1e10);
        return price;
    }

    function _buy(uint _amount, uint _cooldownTime) internal {
        UserRecord storage u = userData[msg.sender];

        require(_amount >= minBuyAmount, "Below min buy amount");
        require(block.timestamp >= u.nextClaimTime, "Claimed too recently");

        u.nextClaimTime = block.timestamp.add(_cooldownTime);
        u.claimCount = u.claimCount.add(1);
        u.totalBoughtBNB = u.totalBoughtBNB.add(_amount);
        totalSoldBNB = totalSoldBNB.add(_amount);

        uint lpAmount = _amount.mul(lpTokensPerOneBNB()).div(1e18);
        lpToken.transferFrom(msg.sender, burn, lpAmount);
        sBNB.transfer(msg.sender, _amount);
        sBNB.transfer(address(treasury), _amount);

        emit SoldBNB(msg.sender, _amount);
    }

    function buyBNB(uint256 _amount) public notContract {
        require(_amount <= availableForUser(msg.sender), "Amount exceeds user limit");
        _buy(_amount, buyCooldown);
    }

    function superPODL(uint256 _amount) public notContract {
        (uint userLocked, , ,) = treasury.lockedBalances(msg.sender);
        require(userLocked >= minSuperPODLLock, "Need to lock SCULPT!");
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

     /**
     * @notice Sets admin address
     * @dev Only callable by the contract owner.
     */
    function setAdmin(address _admin) external onlyOwner {
        require(_admin != address(0), "Cannot be zero address");
        admin = _admin;
        emit AdminSet(_admin);
    }

    event AdminSet(address admin);
    // event UpdatedPrice(uint256 twap, uint256 cumulate, uint256 diffTime, uint256 oldPrice);
}
