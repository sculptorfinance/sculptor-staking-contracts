pragma solidity 0.7.6;

import "../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../interfaces/IMultiFeeDistribution.sol";

contract TokenVesting {
    using SafeMath for uint256;

    uint256 public startTime;
    uint256 public immutable duration;
    uint256 public immutable lockDuration;
    uint256 public immutable maxMintableTokens;
    uint256 public mintedTokens;
    IMultiFeeDistribution public immutable minter;
    address public immutable owner;

    struct Vest {
        uint256 total;
        uint256 claimed;
    }

    mapping(address => Vest) public vests;

    constructor(
        IMultiFeeDistribution _minter,
        uint256 _maxMintable,
        address[] memory _receivers,
        uint256[] memory _amounts,
        uint256 _duration,
        uint256 _lockDuration
    ) {
        require(_receivers.length == _amounts.length);
        minter = _minter;
        uint256 mintable;
        for (uint256 i = 0; i < _receivers.length; i++) {
            require(vests[_receivers[i]].total == 0);
            mintable = mintable.add(_amounts[i]);
            vests[_receivers[i]].total = _amounts[i];
        }
        require(mintable == _maxMintable);
        maxMintableTokens = mintable;
        duration = _duration;
        lockDuration = _lockDuration;
        owner = msg.sender;
    }

    function start() external {
        require(msg.sender == owner);
        require(startTime == 0);
        startTime = block.timestamp.add(lockDuration);
    }

    function claimable(address _claimer) external view returns (uint256) {
        if (startTime == 0 || startTime > block.timestamp) return 0;
        Vest storage v = vests[_claimer];
        uint256 elapsedTime = block.timestamp.sub(startTime);
        if (elapsedTime > duration) elapsedTime = duration;
        uint256 claimable = v.total.mul(elapsedTime).div(duration);
        return claimable.sub(v.claimed);
    }

    function claim(address _receiver) external {
        require(startTime != 0, "Not started yet!");
        require(startTime <= block.timestamp, "Still locked!");
        Vest storage v = vests[msg.sender];
        uint256 elapsedTime = block.timestamp.sub(startTime);
        if (elapsedTime > duration) elapsedTime = duration;
        uint256 claimable = v.total.mul(elapsedTime).div(duration);
        if (claimable > v.claimed) {
            uint256 amount = claimable.sub(v.claimed);
            mintedTokens = mintedTokens.add(amount);
            require(mintedTokens <= maxMintableTokens);
            v.claimed = claimable;
            if(amount > 0){
              minter.mint(_receiver, amount, false);
            }
        }
    }
}
