// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";


interface IPoseidonTokenLocker {
    function totalLock() external view returns (uint256);

    function lockOf(address _account) external view returns (uint256);

    function released(address _account) external view returns (uint256);

    function canUnlockAmount(address _account) external view returns (uint256);

    function lock(address _account, uint256 _amount) external;

    function unlock() external;
}


contract PoseidonTokenLocker is IPoseidonTokenLocker {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    address public poseidon;

    uint256 public startReleaseBlock;
    uint256 public endReleaseBlock;

    uint256 private _totalLock;
    mapping(address => uint256) private _locks;
    mapping(address => uint256) private _released;

    event Lock(address indexed to, uint256 value, uint256 receivedValue);

    constructor(
        address _poseidon,
        uint256 _startReleaseBlock,
        uint256 _endReleaseBlock
    ) public {
        require(_endReleaseBlock > _startReleaseBlock, "endReleaseBlock < startReleaseBlock");
        poseidon = _poseidon;
        startReleaseBlock = _startReleaseBlock;
        endReleaseBlock = _endReleaseBlock;
    }

    function totalLock() external view override returns (uint256) {
        return _totalLock;
    }

    function lockOf(address _account) external view override returns (uint256) {
        return _locks[_account];
    }

    function released(address _account) external view override returns (uint256) {
        return _released[_account];
    }

    function lock(address _account, uint256 _amount) external override {
        require(_account != address(0), "no lock to address(0)");
        require(_amount > 0, "zero lock");

        uint256 balanceBefore = IBEP20(poseidon).balanceOf(address(this));
        IBEP20(poseidon).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 balanceAfter = IBEP20(poseidon).balanceOf(address(this));
        uint256 receivedAmount = balanceAfter.sub(balanceBefore);

        _locks[_account] = _locks[_account].add(receivedAmount);
        _totalLock = _totalLock.add(receivedAmount);

        emit Lock(_account, _amount, receivedAmount);
    }

    function canUnlockAmount(address _account) public view override returns (uint256) {
        uint256 blockNumber = block.number;
        if (blockNumber < startReleaseBlock) {
            return 0;
        } else if (blockNumber >= endReleaseBlock) {
            return _locks[_account].sub(_released[_account]);
        } else {
            uint256 _releasedBlock = blockNumber.sub(startReleaseBlock);
            uint256 _totalVestingBlock = endReleaseBlock.sub(startReleaseBlock);
            return _locks[_account].mul(_releasedBlock).div(_totalVestingBlock).sub(_released[_account]);
        }
    }

    function unlock() external override {
        address sender = msg.sender;
        require(block.number > startReleaseBlock, "still locked");
        require(_locks[sender] > _released[sender], "no locked");

        uint256 _amount = canUnlockAmount(sender);

        IBEP20(poseidon).safeTransfer(sender, _amount);
        _released[sender] = _released[sender].add(_amount);
        _totalLock = _totalLock.sub(_amount);
    }
}
