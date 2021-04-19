// SPDX-License-Identifier: MIT
pragma solidity >=0.6.5 <0.8.0;

import "./libraries/Upgradable.sol";
import "./Constant.sol";
import "./libraries/TransferHelper.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

//100000000 * 0.1= 10000000
//(100000000 - (100000000 * 0.1)) * 0.1 = 9000000
//(100000000 - (100000000 * 0.1) - (100000000 - (100000000 * 0.1)) * 0.1) * 0.1

// 10000000 - 1000000
// 9000000 - 900000
// 8100000 - 810000
// 7290000
// ming = 0.9t
// ming2 = 0.9ming
// ming(n) = 0.9 ming(n-1)
// 等比数列
// an = a1 * q^(n-1)
// n = 1 => 10000000 => 10000000
// n = 2 => 10000000 * 0.9^(2-1) => 9000000
// n = 3 => 10000000 * 0.9^(3-1) => 8100000
// n = 4 => 10000000 * 0.9^(4-1) => 7290000
// n = 5 => 10000000 * 0.9^(5-1) => 6561000
// n = 6 => 10000000 * 0.9^(6-1) => 5904900

// 每个区块释放
// n = 1 => (10000000 * 0.9^(1-1) ) / 28800 => 347.22222222222222222222222222222
// n = 2 => (10000000 * 0.9^(2-1)) / 28800 => 312.5
// n = 3 => (10000000 * 0.9^(3-1)) / 28800 => 281.25
// n = 4 => (10000000 * 0.9^(4-1)) / 28800 => 253.125
// n = 5 => (10000000 * 0.9^(5-1)) / 28800 => 227.8125
// n = 6 => (10000000 * 0.9^(6-1)) / 28800 => 205.03125
// n = 6 => (10000000 * 0.9^(7-1)) / 28800 => 205.03125

contract ETToken is UpgradableProduct, ERC20 {
    using SafeMath for uint256;
    using TransferHelper for address;

    event UpdatePoolAddress(uint256 indexed poolId, address indexed pool);

    uint256 public immutable TotalMintAmount; // 发行总量
    uint256 public immutable MintStartBlock; //

    // pool id
    uint256 public constant LP_POOL_ID = 1;
    uint256 public constant PLEDGE_POOL_ID = 2;
    uint256 public constant INVITE_POOL_ID = 3;
    uint256 public constant NODE_POOL_ID = 4;
    uint256 public constant TEAM_POOL_ID = 5;

    // pool distribution
    mapping(uint256 => uint256) public poolTotalReward;
    mapping(uint256 => uint256) public poolLastBlock;
    mapping(uint256 => uint256) public poolLastStartBlock;
    mapping(uint256 => uint256) public poolLastReleaseReward;

    // pool config
    mapping(uint256 => address) public pollAddress;
    mapping(address => uint256) public addressPoll;
    mapping(uint256 => uint256) public poolProportion;

    constructor() public ERC20("ET TOKEN", "ET") {
        MintStartBlock = block.number;
        TotalMintAmount = 100000000 * 10**uint256(decimals());

        // pool proportion
        poolProportion[LP_POOL_ID] = 55;
        poolProportion[PLEDGE_POOL_ID] = 10;
        poolProportion[INVITE_POOL_ID] = 20;
        poolProportion[NODE_POOL_ID] = 5;
        poolProportion[TEAM_POOL_ID] = 10;
    }

    function updatePoolAddress(uint256 poolId, address pool)
        external
        virtual
        requireImpl
    {
        require(poolProportion[poolId] > 0, "Pool does not exist");
        pollAddress[poolId] = pool;
        addressPoll[pool] = poolId;
        emit UpdatePoolAddress(poolId, pool);
    }

    function getPoolLastBlock(uint256 poolId)
        internal
        view
        virtual
        returns (uint256)
    {
        uint256 lastBlock = poolLastBlock[poolId];

        if (lastBlock == 0) {
            lastBlock = MintStartBlock;
        }
        return lastBlock;
    }

    function getPoolLastStratBlock(uint256 poolId)
        internal
        view
        virtual
        returns (uint256)
    {
        uint256 lastBlock = poolLastStartBlock[poolId];

        if (lastBlock == 0) {
            lastBlock = MintStartBlock;
        }
        return lastBlock;
    }

    function calculateMint(uint256 blockNumber, uint256 poolId)
        public
        view
        virtual
        returns (
            uint256 _lastStartBlock,
            uint256 _releaseAmount,
            uint256 _reward
        )
    {
        uint256 proportion = poolProportion[poolId];
        require(proportion > 0, "Pool does not exist");
        if (blockNumber == 0) {
            blockNumber = block.number;
        }
        uint256 lastBlock = getPoolLastBlock(poolId);
        if (blockNumber <= lastBlock) {
            return (_lastStartBlock, _releaseAmount, _reward);
        }

        _lastStartBlock = getPoolLastStratBlock(poolId);
        bool updateBlockCount = blockNumber.sub(_lastStartBlock) > Constant.DAY_BLOCK_COUNT;
        uint256 rel =
            updateBlockCount
                ? uint256(poolTotalReward[poolId]).sub(
                    uint256(poolLastReleaseReward[poolId]).mul(proportion).div(
                        100
                    )
                )
                : 0;
        uint256 releaseAmount = poolLastReleaseReward[poolId];
        uint256 subBlockCount = blockNumber.sub(_lastStartBlock);
        uint256 blockCount = blockNumber.sub(lastBlock);
        uint256 reward = 0;
        if (updateBlockCount) {
            uint256 day = subBlockCount.div(Constant.DAY_BLOCK_COUNT);
            for (uint256 i = 0; i < day; i++) {
                uint256 release = 0;
                if (TotalMintAmount > releaseAmount) {
                    release = TotalMintAmount.sub(releaseAmount).div(1000);
                }
                reward = reward.add(release);
                releaseAmount = releaseAmount.add(release);
                _lastStartBlock = _lastStartBlock.add(Constant.DAY_BLOCK_COUNT);
            }
            blockCount = blockNumber.sub(_lastStartBlock);
        }

        uint256 add =
            TotalMintAmount.sub(releaseAmount).div(1000).mul(blockCount).div(
                Constant.DAY_BLOCK_COUNT
            );
        // 加上当日区块的释放
        reward = reward.add(add).mul(proportion).div(100).sub(rel);
        return (_lastStartBlock, releaseAmount, reward);
    }

    // 根据规则增发指定的池子
    function mint(uint256 blockNumber) external virtual {
        uint256 pid = addressPoll[msg.sender];
        require(pid > 0, "Pool does not exist");

        //允许提前超发
        //require(blockNumber <= block.number, "Illegal block number");

        (uint256 _lastStartBlock, uint256 _releaseAmount, uint256 _reward) =
            calculateMint(blockNumber, pid);
        if (_reward > 0) {
            if (_lastStartBlock > 0) {
                poolLastStartBlock[pid] = _lastStartBlock;
                poolLastReleaseReward[pid] = _releaseAmount;
            }

            _mint(msg.sender, _reward);
            poolLastBlock[pid] = blockNumber;
            poolTotalReward[pid] = poolTotalReward[pid].add(_reward);
        }
    }
}
