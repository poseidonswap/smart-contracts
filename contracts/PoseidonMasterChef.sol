// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./PoseidonToken.sol";
import "./PoseidonTokenLocker.sol";

// PoseidonMasterChef is the master of Poseidon.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once Poseidon is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract PoseidonMasterChef is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Bonus muliplier for early poseidon makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    uint256 public constant ONE_HUNDRED = 10000; // 100%
    // Initial emission rate: 1 token per block.
    uint256 public constant INITIAL_EMISSION_RATE = 1 ether;
    // Minimum emission rate: 0.1 token per block.
    uint256 public constant MINIMUM_EMISSION_RATE = 100 finney;
    // Reduce emission every 9,600 blocks ~ 8 hours.
    uint256 public constant EMISSION_REDUCTION_PERIOD_BLOCKS = 9600;
    // Emission reduction rate per period in basis points: 3%.
    uint256 public constant EMISSION_REDUCTION_RATE_PER_PERIOD = 300;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of Poseidon
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accPosPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accPosPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. Poseidon to distribute per block.
        uint256 lastRewardBlock;  // Last block number that Poseidon distribution occurs.
        uint256 accPosPerShare;   // Accumulated Poseidon per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
        uint16 lockPercentage;    // Percentage of reward will be locked
    }

    // The Poseidon TOKEN!
    PoseidonToken public poseidon;
    // The locker
    PoseidonTokenLocker public locker;
    // Dev address.
    address public devaddr;
    // Poseidon tokens created per block.
    uint256 public poseidonPerBlock;
    // Deposit Fee address
    address public feeAddress;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when Poseidon mining starts.
    uint256 public startBlock;
    uint256 public lastReductionPeriodIndex = 0;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        PoseidonToken _poseidon,
        PoseidonTokenLocker _locker,
        address _devaddr,
        address _feeAddress,
        uint256 _poseidonPerBlock,
        uint256 _startBlock
    ) public {
        poseidon = _poseidon;
        locker = _locker;
        devaddr = _devaddr;
        feeAddress = _feeAddress;
        poseidonPerBlock = _poseidonPerBlock;
        startBlock = _startBlock;

        _poseidon.approve(address(_locker), uint256(-1));
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, uint16 _lockPercentage, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= ONE_HUNDRED, "add: invalid deposit fee basis points");
        require(_lockPercentage <= ONE_HUNDRED, "add: invalid lock percentage");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accPosPerShare: 0,
            depositFeeBP: _depositFeeBP,
            lockPercentage: _lockPercentage
        }));
    }

    // Update the given pool's Poseidon allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, uint16 _lockPercentage, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= ONE_HUNDRED, "set: invalid deposit fee basis points");
        require(_lockPercentage <= ONE_HUNDRED, "add: invalid lock percentage");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].lockPercentage = _lockPercentage;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending Poseidon on frontend.
    function pendingPoseidon(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accPosPerShare = pool.accPosPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 poseidonReward = multiplier.mul(poseidonPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accPosPerShare = accPosPerShare.add(poseidonReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accPosPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 poseidonReward = multiplier.mul(poseidonPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        poseidon.mint(devaddr, poseidonReward.div(10));
        poseidon.mint(address(this), poseidonReward);
        pool.accPosPerShare = pool.accPosPerShare.add(poseidonReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to PoseidonMasterChef for Poseidon allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accPosPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safePoseidonTransfer(msg.sender, pending, _pid);
            }
        }
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if(pool.depositFeeBP > 0){
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            }else{
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accPosPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from PoseidonMasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accPosPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safePoseidonTransfer(msg.sender, pending, _pid);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accPosPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function safePoseidonTransfer(address _to, uint256 _amount, uint256 _pid) internal {
        uint256 lockedPercentage = uint256(poolInfo[_pid].lockPercentage);
        uint256 claimableAmount = _amount.mul(ONE_HUNDRED.sub(lockedPercentage)).div(ONE_HUNDRED);
        uint256 lockedAmount = _amount.sub(claimableAmount);
        poseidon.transfer(_to, claimableAmount);
        locker.lock(_to, lockedAmount);
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    function setFeeAddress(address _feeAddress) public{
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
    }

    // Auto reduce emission rate
    function updateEmissionRate() public {
        require(block.number > startBlock, "updateEmissionRate: Can only be called after mining starts");
        require(poseidonPerBlock > MINIMUM_EMISSION_RATE, "updateEmissionRate: Emission rate has reached the minimum threshold");

        uint256 currentIndex = block.number.sub(startBlock).div(EMISSION_REDUCTION_PERIOD_BLOCKS);
        if (currentIndex <= lastReductionPeriodIndex) {
            return;
        }

        uint256 newEmissionRate = poseidonPerBlock;
        for (uint256 index = lastReductionPeriodIndex; index < currentIndex; ++index) {
            newEmissionRate = newEmissionRate.mul(ONE_HUNDRED - EMISSION_REDUCTION_RATE_PER_PERIOD).div(ONE_HUNDRED);
        }

        newEmissionRate = newEmissionRate < MINIMUM_EMISSION_RATE ? MINIMUM_EMISSION_RATE : newEmissionRate;
        if (newEmissionRate >= poseidonPerBlock) {
            return;
        }

        massUpdatePools();
        lastReductionPeriodIndex = currentIndex;
        poseidonPerBlock = newEmissionRate;
    }
}