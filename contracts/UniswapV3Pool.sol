// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3Pool.sol';

import './NoDelegateCall.sol';

import './libraries/LowGasSafeMath.sol';
import './libraries/SafeCast.sol';
import './libraries/Tick.sol';
import './libraries/TickBitmap.sol';
import './libraries/Position.sol';
import './libraries/Oracle.sol';

import './libraries/FullMath.sol';
import './libraries/FixedPoint128.sol';
import './libraries/TransferHelper.sol';
import './libraries/TickMath.sol';
import './libraries/LiquidityMath.sol';
import './libraries/SqrtPriceMath.sol';
import './libraries/SwapMath.sol';

import './interfaces/IUniswapV3PoolDeployer.sol';
import './interfaces/IUniswapV3Factory.sol';
import './interfaces/IERC20Minimal.sol';
import './interfaces/callback/IUniswapV3MintCallback.sol';
import './interfaces/callback/IUniswapV3SwapCallback.sol';
import './interfaces/callback/IUniswapV3FlashCallback.sol';

contract UniswapV3Pool is IUniswapV3Pool, NoDelegateCall {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];

    /// @inheritdoc IUniswapV3PoolImmutables
    /// 工厂地址，用于 onlyFactoryOwner ，只允许 factory owner 设置和收集协议费
    address public immutable override factory;
    /// @inheritdoc IUniswapV3PoolImmutables
    /// 池子的 token0 地址
    address public immutable override token0;
    /// @inheritdoc IUniswapV3PoolImmutables
    /// 池子的 token1 地址
    address public immutable override token1;
    /// @inheritdoc IUniswapV3PoolImmutables
    /// 池子的 fee (100, 500, 3000, 10000)，每单位是百万分之一
    uint24 public immutable override fee;

    /// @inheritdoc IUniswapV3PoolImmutables
    /// fee 对应的 tick 间距，{100: 1, 500: 10, 3000: 60, 10000: 200}，间距越大，滑点越大
    /// 传入合约的 tick 都必须是可以整除 tickSpacing 的
    int24 public immutable override tickSpacing;

    /// @inheritdoc IUniswapV3PoolImmutables
    /// 每个tick可以承载的最大流动性，等于 type(uint128).max / numTicks，避免总和溢出 uint128
    uint128 public immutable override maxLiquidityPerTick;

    struct Slot0 {
        // the current price
        // 当前两个 token 价格的平方根，由64位整数和96小数组成
        // sqrt(P) = sqrt(y/x)
        // 合约使用 sqrt(P) 而不是 P 有两个原因：
        // 1. 计算比较方便，因为一个时刻只有其中一个值会变化。当在一个tick内交易时，只有价格（即sqrt(𝑃)）发生变化；
        // 当穿越一个tick或者铸造/销毁流动性时，只有流动性（即𝐿）发生变化。这避免了在记录虚拟余额时可能遇到的舍入误差问题。
        // 2. ​sqrt(P) 与 L 之间有一个关系：L = delta Y / delta sqrt(P)，为了使用这个公式，避免当计算交易时进行任何开根号运算。
        // 这个公式可以理解为，流动性也可以被看作token1的（无论是真实还是虚拟的）数量变化与价格sqrt(𝑃)变化的比例
        // 推导：
        // 前提：L^2 = xy，P = y / x
        // y = L * L / x
        // y = L * L / (y / P)
        // y = L * L * (P / y)
        // y * y = L * L * P
        // y = L * sqrt(P)

        // 假设 𝑡0 和 𝑡1 时刻，对应的 𝑦0 和 𝑦1 分别为：
        // y0 = L * sqrt(P0)
        // y1 = L * sqrt(P1)
        // 因此，y1 - y0 = L * (sqrt(P1) - sqrt(P0))
        // L = (y1 - y0) / (sqrt(P1) - sqrt(P0)) = delta Y / delta sqrt(P)
        uint160 sqrtPriceX96;
        // the current tick
        // 低于当前价格的最接近的tick
        // tick i 的 sqrt(P) = 1.0001 ** (i / 2)
        // sqrt(P) 对应的 tick i 等于以sqrt(1.0001)为底，sqrt(P)的对数。i = log(sqrt(1.0001))sqrt(P)
        // 存疑：这里存储的tick是否除以了tickSpacing，猜测应该不会，否则对应不上当前价格
        int24 tick;
        // the most-recently updated index of the observations array
        // 观测数组最新的观测索引，即最后一次写入的观测点索引
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        // 预言机数组当前长度
        // 这个值Oracle.write中更新，可以每次增加1，也可以突变增大
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        // 观测数组能够扩展到的下一个基数的大小，通过 increaseObservationCardinalityNext 增加
        // 观测数据存储在一个定长的数组里，当一个新的观测被存储并且 observationCardinalityNext 超过 observationCardinality 的时候就会扩展。
        // 如果一个数组不能被扩展（下一个基数与现在的基数相同），旧的观测就会被覆盖
        // 数组扩展需要外部调用 increaseObservationCardinalityNext 函数，这是uniswap分散gas消耗的方式
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        // 协议手续费，表示交易者支付手续费的部分比例将分给协议，0, 1/4, 1/5, 1/6, 1/7, 1/8, 1/9 或者 1/10
        // 使用8位存储，高四位是token1的手续费，低四位是token0的手续费
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }
    /// @inheritdoc IUniswapV3PoolState
    /// 池子的第一个插槽存储的全局变量，包括sqrtPrice, tick, oracle variables, feeProtocal, unlocked
    Slot0 public override slot0;

    /// @inheritdoc IUniswapV3PoolState
    /// 表示该合约到现在为止，每一份虚拟流动性（𝐿）获取的 token0 的手续费，使用无符号定点数（128x128格式）表示
    uint256 public override feeGrowthGlobal0X128;
    /// @inheritdoc IUniswapV3PoolState
    /// 表示该合约到现在为止，每一份虚拟流动性（𝐿）获取的 token1 的手续费，使用无符号定点数（128x128格式）表示
    uint256 public override feeGrowthGlobal1X128;

    // accumulated protocol fees in token0/token1 units
    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }
    /// @inheritdoc IUniswapV3PoolState
    /// 以每种代币表示的累计未被领取的协议手续费，以无符号uint128类型表示。
    /// 通过调用 collectProtocol 方法领取
    ProtocolFees public override protocolFees;

    /// @inheritdoc IUniswapV3PoolState
    /// 资金池当前在范围内的可用流动性
    /// L = sqrt(xy)
    uint128 public override liquidity;

    /// @inheritdoc IUniswapV3PoolState
    /// 一个 tick 对应的信息（注释查看Tick文件），tick 范围 [-887272, 887272]
    mapping(int24 => Tick.Info) public override ticks;
    /// @inheritdoc IUniswapV3PoolState
    /// 为了更高效寻找下一个已初始化的tick，合约使用一个位图tickBitmap记录已初始化的tick。
    /// 如果tick已被初始化，位图中对应于该tick序号的位置设置为1，否则为0。
    /// int24 compressed = tick / tickSpacing;
    /// wordPos = int16(tick >> 8); tick在第几个字
    /// bitPos = uint8(tick % 256); tick在这个字的第几位
    mapping(int16 => uint256) public override tickBitmap;
    /// @inheritdoc IUniswapV3PoolState
    /// 仓位信息（注释查看Position文件）。key 为 keccak256(abi.encodePacked(owner, tickLower, tickUpper))
    mapping(bytes32 => Position.Info) public override positions;
    /// @inheritdoc IUniswapV3PoolState
    /// 预言机数据观测数组，最多 65535 位，超过时会重新开始，旧数据被覆盖
    Oracle.Observation[65535] public override observations;

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    /// 避免重入的修饰器
    modifier lock() {
        require(slot0.unlocked, 'LOK');
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    /// @dev Prevents calling a function from anyone except the address returned by IUniswapV3Factory#owner()
    /// 只允许factory owner 设置 protocol fee 和收集 protocol fee
    modifier onlyFactoryOwner() {
        require(msg.sender == IUniswapV3Factory(factory).owner());
        _;
    }

    constructor() {
        int24 _tickSpacing;
        // factory 合约创建 pool 合约时，暂时存储了这些必要参数，用完即删，详见 factory.createPool - UniswapV3PoolDeployer.deploy
        (factory, token0, token1, fee, _tickSpacing) = IUniswapV3PoolDeployer(msg.sender).parameters();
        tickSpacing = _tickSpacing;

        // 每个tick可以承载的最大流动性，等于 type(uint128).max / numTicks，避免总和溢出 uint128
        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }

    /// @dev Common checks for valid tick inputs.
    /// 对tick的基本校验
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, 'TLU');
        require(tickLower >= TickMath.MIN_TICK, 'TLM');
        require(tickUpper <= TickMath.MAX_TICK, 'TUM');
    }

    /// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32. This method is overridden in tests.
    /// 区块时间，uint32表示
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @dev Get the pool's balance of token0
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    /// 返回池子token0的余额
    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) = token0.staticcall(
            abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this))
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @dev Get the pool's balance of token1
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    /// 返回池子token0的余额
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) = token1.staticcall(
            abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this))
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    /// @notice 返回一个tick范围内的数据快照，包括范围内累计的tick、每流动性秒数和tick范围内的秒数
    /// @dev 快照只能与在头寸存在的期间内拍摄的其他快照进行比较。
    /// 即，如果在拍摄第一个快照和拍摄第二个快照之间的整个期间内没有持有头寸，则无法比较快照。
    /// @return tickCumulativeInside 范围内的的tick累加器快照
    /// @return secondsPerLiquidityInsideX128 范围内的每流动性的秒数
    /// @return secondsInside 范围内经历的秒数
    function snapshotCumulativesInside(
        int24 tickLower,
        int24 tickUpper
    )
        external
        view
        override
        noDelegateCall
        returns (int56 tickCumulativeInside, uint160 secondsPerLiquidityInsideX128, uint32 secondsInside)
    {
        checkTicks(tickLower, tickUpper);

        int56 tickCumulativeLower;
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;

        // 获取 tickLower 和 tickUpper 的 tick 信息
        {
            Tick.Info storage lower = ticks[tickLower];
            Tick.Info storage upper = ticks[tickUpper];
            bool initializedLower;
            (tickCumulativeLower, secondsPerLiquidityOutsideLowerX128, secondsOutsideLower, initializedLower) = (
                lower.tickCumulativeOutside,
                lower.secondsPerLiquidityOutsideX128,
                lower.secondsOutside,
                lower.initialized
            );
            require(initializedLower);

            bool initializedUpper;
            (tickCumulativeUpper, secondsPerLiquidityOutsideUpperX128, secondsOutsideUpper, initializedUpper) = (
                upper.tickCumulativeOutside,
                upper.secondsPerLiquidityOutsideX128,
                upper.secondsOutside,
                upper.initialized
            );
            require(initializedUpper);
        }

        Slot0 memory _slot0 = slot0;

        // 根据tick位置不同，减法参数不同，理解比较简单
        // tickUpper > tickLower > tick
        if (_slot0.tick < tickLower) {
            return (
                tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityOutsideLowerX128 - secondsPerLiquidityOutsideUpperX128,
                secondsOutsideLower - secondsOutsideUpper
            );
        } else if (_slot0.tick < tickUpper) {
            // tickUpper > tick > tickLower
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                time,
                0,
                _slot0.tick,
                _slot0.observationIndex,
                liquidity,
                _slot0.observationCardinality
            );
            return (
                tickCumulative - tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityCumulativeX128 -
                    secondsPerLiquidityOutsideLowerX128 -
                    secondsPerLiquidityOutsideUpperX128,
                time - secondsOutsideLower - secondsOutsideUpper
            );
        } else {
            // tick > tickUpper > tickLower
            return (
                tickCumulativeUpper - tickCumulativeLower,
                secondsPerLiquidityOutsideUpperX128 - secondsPerLiquidityOutsideLowerX128,
                secondsOutsideUpper - secondsOutsideLower
            );
        }
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    /// 读取预言机，获取多少秒之前累计的tick和每个范围内流动性值的累计秒数
    /// 通过累计tick算出price
    /// @dev 要获取时间加权平均刻度或范围内流动性，必须使用两个值调用此函数，一个值代表
    /// 期间的开始，另一个值代表期间的结束。例如，要获取最后一小时的时间加权平均刻度，
    /// 必须使用 secondsAgos = [3600, 0] 调用它。
    function observe(
        uint32[] calldata secondsAgos
    )
        external
        view
        override
        noDelegateCall
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return
            // 详情查看 Oracle 文件
            observations.observe(
                _blockTimestamp(),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// 增加观测数组的长度，
    // observationCardinalityNext由用户传入，可以比observationCardinality大很多
    function increaseObservationCardinalityNext(
        uint16 observationCardinalityNext
    ) external override lock noDelegateCall {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew = observations.grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );
        slot0.observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev not locked because it initializes unlocked
    /// 创建完合约，需要初始化，任何人都可以调用，但是只能调用一次
    /// 初始化 sqrtPriceX96, tick, oracle info, feeProtocl, unlocked
    function initialize(uint160 sqrtPriceX96) external override {
        require(slot0.sqrtPriceX96 == 0, 'AI');

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        // 初始化观测数组0索引
        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true
        });

        emit Initialize(sqrtPriceX96, tick);
    }

    struct ModifyPositionParams {
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        // 改变的liquidity数量，可正可负
        int128 liquidityDelta;
    }

    /// @dev Effect some changes to a position
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return position a storage pointer referencing the position with the given owner and tick range
    /// @return amount0 the amount of token0 owed to the pool, negative if the pool should pay the recipient
    /// @return amount1 the amount of token1 owed to the pool, negative if the pool should pay the recipient
    /// 用于 mint/burn 更新tick和仓位信息
    function _modifyPosition(
        ModifyPositionParams memory params
    ) private noDelegateCall returns (Position.Info storage position, int256 amount0, int256 amount1) {
        checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _slot0 = slot0; // SLOAD for gas optimization

        // 更新tick和仓位信息
        position = _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            _slot0.tick
        );

        if (params.liquidityDelta != 0) {
            // tickLower > 当前 tick，tick区间在当前tick上方，只需要提供token0
            // delta x 的计算公式详见https://hackmd.io/d4GTJiyrQFigUp80IFb-gQ 6.16
            if (_slot0.tick < params.tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ token0 (it's becoming more valuable) so user must provide it
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // current tick is inside the passed range
                // 当前tick在tick区间之间
                uint128 liquidityBefore = liquidity; // SLOAD for gas optimization

                // write an oracle entry
                // 写入一个预言机的观测数据，更新全局预言机信息，详见函数注释
                (slot0.observationIndex, slot0.observationCardinality) = observations.write(
                    _slot0.observationIndex,
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );

                // 当前tick到tickUpper，计算amount0
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                // tickLower到当前tick，计算amount1
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    _slot0.sqrtPriceX96,
                    params.liquidityDelta
                );

                // 更新全局状态在范围内的流动性
                liquidity = LiquidityMath.addDelta(liquidityBefore, params.liquidityDelta);
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ token1 (it's becoming more valuable) so user must provide it
                // tickUpper < 当前 tick，tick区间在当前tick下方，只需要提供token1
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    /// @dev Gets and updates a position with the given liquidity delta
    /// @param owner the owner of the position
    /// @param tickLower the lower tick of the position's tick range
    /// @param tickUpper the upper tick of the position's tick range
    /// @param tick the current tick, passed to avoid sloads
    /// 更新tick和仓位信息
    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {
        // 获取对应的仓位
        position = positions.get(owner, tickLower, tickUpper);

        // 每单位流动性表示的token0手续费
        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128; // SLOAD for gas optimization
        // 每单位流动性表示的token1手续费
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128; // SLOAD for gas optimization

        // if we need to update the ticks, do it
        bool flippedLower;
        bool flippedUpper;
        // 如果流动性有变化
        if (liquidityDelta != 0) {
            uint32 time = _blockTimestamp();
            // 获取当前的累计价格和累计每流动性持续时间
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                time,
                0,
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );

            // 更新tick信息，两个fee字段，两个预言机字段，两个流动性字段，详见函数注释
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false,
                maxLiquidityPerTick
            );
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true,
                maxLiquidityPerTick
            );

            // 翻转tick，传入tick必须是可以整除tick间距的
            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        // 获取tick范围内的fee growth
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = ticks.getFeeGrowthInside(
            tickLower,
            tickUpper,
            tick,
            _feeGrowthGlobal0X128,
            _feeGrowthGlobal1X128
        );

        // 更新仓位信息，流动性、两个fee growth insde、两个token owned（假如有收益），详见函数注释
        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        // clear any tick data that is no longer needed
        if (liquidityDelta < 0) {
            // burn时，如果需要翻转tick，说明没有流动性，删除tiks[tick]
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    // 添加流动性
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        // 添加的流动性数量
        uint128 amount,
        bytes calldata data
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        require(amount > 0);
        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(amount).toInt128()
            })
        );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        // 调用合约转账
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        if (amount0 > 0) require(balance0Before.add(amount0) <= balance0(), 'M0');
        if (amount1 > 0) require(balance1Before.add(amount1) <= balance1(), 'M1');

        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        // we don't need to checkTicks here, because invalid positions will never have non-zero tokensOwed{0,1}
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    // 移除流动性
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        // 更新tick和仓位信息
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: msg.sender,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(amount).toInt128()
            })
        );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            // 把需要退还的token加到owned上，通过collect领取
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    struct SwapCache {
        // the protocol fee for the input token
        uint8 feeProtocol;
        // liquidity at the beginning of the swap
        // 缓存初始流动性
        uint128 liquidityStart;
        // the timestamp of the current block
        uint32 blockTimestamp;
        // the current value of the tick accumulator, computed only if we cross an initialized tick
        int56 tickCumulative;
        // the current value of seconds per liquidity accumulator, computed only if we cross an initialized tick
        uint160 secondsPerLiquidityCumulativeX128;
        // whether we've computed and cached the above two accumulators
        bool computedLatestObservation;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the global fee growth of the input token
        // 输入token的全局fee增量
        uint256 feeGrowthGlobalX128;
        // amount of input token paid as protocol fee
        // 输入token支付的协议费
        uint128 protocolFee;
        // the current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    /// @inheritdoc IUniswapV3PoolActions
    // 交换token
    // 根据zeroForOne和exactInput，可以有四种swap组合：
    // 1. true true	输入固定数量token0，输出最大数量token1
    // 2. true false 输入最小数量token0，输出固定数量token1
    // 3. false	true 输入固定数量token1，输出最大数量token0
    // 4. false	false 输入最小数量token1，输出固定数量token0
    function swap(
        address recipient,
        bool zeroForOne,
        // 指定的代币数量，如果为正，表示希望输入的代币数量；如果为负，则表示希望输出的代币数量
        int256 amountSpecified,
        // 能够承受的价格上限（或下限），格式为Q64.96；
        // 如果从token0到token1，则表示swap过程中的价格下限；
        // 如果从token1到token0，则表示价格上限；如果价格超过该值，则swap失败
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override noDelegateCall returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, 'AS');

        Slot0 memory slot0Start = slot0;

        require(slot0Start.unlocked, 'LOK');
        // 如果zeroForOne，价格会变小，那么价格限制必须小于当前价格，而且大于最小价格
        // 否则，价格会变大，价格限制必须大于当前价格，而且小于最大价格
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            'SPL'
        );

        slot0.unlocked = false;

        // 1. 初始化swap状态
        // swap缓存
        SwapCache memory cache = SwapCache({
            liquidityStart: liquidity,
            blockTimestamp: _blockTimestamp(),
            // 0换1使用token0手续费
            feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4),
            secondsPerLiquidityCumulativeX128: 0,
            tickCumulative: 0,
            computedLatestObservation: false
        });

        // 是否是精确输入
        bool exactInput = amountSpecified > 0;

        // swap状态
        SwapState memory state = SwapState({
            // 精确输入或输出的代币剩余的数量
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0Start.sqrtPriceX96,
            tick: slot0Start.tick,
            // 0换1更新token0的全局fee
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            protocolFee: 0,
            liquidity: cache.liquidityStart
        });

        // 2. 循环交换，直到剩余数量等于0或价格等于限制价格
        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        // 只要我们没有用完所有输入/输出，并且没有达到价格限制，就继续交换
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            // 2.1 分步交换
            StepComputations memory step;

            // 每一步的初始价格等于上一个step之后的价格
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            // 根据当前tick，寻找最近的已初始化的tick，或者本组第一个tick
            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                tickSpacing,
                zeroForOne
            );

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            // 确保tick不超出界限
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            // 计算tickNext对应的价格
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            // 完成一步交换
            // 交换后的价格, 消耗的输入代币数量, 得到的输出代币数量, 这一步的手续费数量 = 完成一步交换(初始价格, 目标价格, 可用流动性, 剩余代币，手续费)
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                // 0换1：sqrtPriceLimitX96为价格下限，使用min(sqrtPriceNextX96, sqrtPriceLimitX96)
                // 1换0：sqrtPriceLimitX96为价格上限，使用max(sqrtPriceNextX96, sqrtPriceLimitX96)
                // 保证目标价格不能超出限制
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            // 更新剩余代币和已兑换代币数量
            // 注意：这里amountSpecifiedRemaining和amountIn可能表示token0，也可能表示token1，具体取决于zeroForOne的值，但是它俩是匹配的，要么都为token0，要么都为token1，结合4中swap类型，就容易理解了。下面循环swap完成之后，会根据zeroForOne和exactInput值，得到正确对应的amount0和amount1
            if (exactInput) {
                // 如果是精确输入，amountSpecifiedRemaining为正值，需要减去amountIn和feeAmount，减少剩余代币数量
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                // amountCalculated默认为0，减去正值，得到负数相加，增加已兑换代币数量
                // 这里amountCalculated表示输出token数量
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                // 如果是精确输出，amountSpecifiedRemaining为负值，需要加上amountOut，减少剩余代币数量
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                // amountCalculated 加上正值，增加输入代币数量
                // 这里amountCalculated表示输入token数量
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            // 更新协议手续费
            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol;
                step.feeAmount -= delta;
                state.protocolFee += uint128(delta);
            }

            // update global fee tracker
            // 更新全局fee数量 (feeAmount / liquidity)
            if (state.liquidity > 0)
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);

            // shift tick if we reached the next price
            // 如果交换后价格等于下一个tick的价格，说明跨了tick，需要更新tick outside信息，更新范围内流动性和tick
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                // 如果tick已经初始化，跨tick更新tick信息、更新范围内流动性
                if (step.initialized) {
                    // check for the placeholder value, which we replace with the actual value the first time the swap
                    // crosses an initialized tick
                    // 循环中只需要获取一次观测数据
                    if (!cache.computedLatestObservation) {
                        // 获取预言机累计tick，累计每流动性持续时长
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                            cache.blockTimestamp,
                            0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    // 调用cross，更新tick outside信息，获取净流动性
                    int128 liquidityNet = ticks.cross(
                        step.tickNext,
                        (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                        (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128),
                        cache.secondsPerLiquidityCumulativeX128,
                        cache.tickCumulative,
                        cache.blockTimestamp
                    );
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    // tick的流动性存在下界，穿过下界增加，穿过上界减少

                    // 当zeroForOne为true，价格向下移动
                    // 交易会穿越价格区间的下界 tick 和上界 tick:

                    // 穿越下界 tick (lower):
                    // 当价格向下穿越下界 tick 时,意味着流动性区间的下边界被交易"消耗"了。
                    // 因此,在下界 tick 处,流动性应该减少。

                    // 穿越上界 tick (upper):
                    // 当价格向下穿越上界 tick 时,意味着交易进入了一个新的流动性区间。
                    // 因此,在上界 tick 处,新的流动性被"激活",流动性应该增加。
                    // 所以 zeroForOne 为 true 时, 取反 liquidityDelta:

                    // 取反 liquidityDelta ,确保了当价格下降时:
                    // 下界 tick 的流动性减少 (liquidityDelta 变为负数)
                    // 上界 tick 的流动性增加 (liquidityDelta 变为正数)
                    if (zeroForOne) liquidityNet = -liquidityNet;
                    // 更新范围内流动性
                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }

                // 移动当前tick到下一个tick
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                // 没跨tick，但是也需要使用交换后的价格计算最新的tick值
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // 3. 更新全局价格，tick和预言机信息
        // update tick and write an oracle entry if the tick change
        // 如果交换后的tick与交换前的tick不同
        if (state.tick != slot0Start.tick) {
            // 记录一次（预言机）观测点数据，因为跨了tick
            (uint16 observationIndex, uint16 observationCardinality) = observations.write(
                slot0Start.observationIndex,
                cache.blockTimestamp,
                slot0Start.tick,
                cache.liquidityStart,
                slot0Start.observationCardinality,
                slot0Start.observationCardinalityNext
            );
            // 更新全局状态：价格、tick、预言机信息
            // 注意此时sqrtPriceX96与tick并不一定对应，sqrtPriceX96才能准确反映当前价格
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            // otherwise just update the price
            // 如果交换前后tick值相同，则只需要修改价格
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // 4. 更新流动性
        // update liquidity if it changed
        // 如果全局流动性发生改变，则更新liquidity
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        // update fee growth global and, if necessary, protocol fees
        // overflow is acceptable, protocol has to withdraw before it hits type(uint128).max fees
        // 4. 更新累计手续费和协议手续费
        if (zeroForOne) {
            // 0换1，收取token0作为手续费，更新feeGrowthGlobal 0
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
        } else {
            // 1换0，收取token1作为手续费，更新feeGrowthGlobal 1
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        }

        // 5. 计算本次交换需要的amount0和amount1，让amount和token匹配
        // 根据zeroForOne和exactInput，可以有四种swap组合：
        // 1. true true	输入固定数量token0，输出最大数量token1
        // 2. true false 输入最小数量token0，输出固定数量token1
        // 3. false	true 输入固定数量token1，输出最大数量token0
        // 4. false	false 输入最小数量token1，输出固定数量token0

        // 都为true表示，0换1且精确输入
        // 都为false表示，1换0且精确输出
        // 这时候，amountSpecified 表示的都是token0，所以用amountSpecified - state.amountSpecifiedRemaining表示amount0
        // state.amountCalculated表示的都是token1，所以用它表示amount1
        // 不相等，一个true 一个false
        // 这时候，amountSpecified 表示的都是token1，和上面正好相反
        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        // do the transfers and collect payment
        // 6. 转移token
        if (zeroForOne) {
            // 输出token转给recipient
            if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            // 输入token通过callback转到pool
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');
        } else {
            // 输出token转给recipient
            if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            // 输入token通过callback转到pool
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
        }

        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        // 解除重入锁
        slot0.unlocked = true;
    }

    /// @inheritdoc IUniswapV3PoolActions
    // 闪电贷
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override lock noDelegateCall {
        uint128 _liquidity = liquidity;
        require(_liquidity > 0, 'L');

        // 计算手续费
        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);
        uint256 balance0Before = balance0();
        uint256 balance1Before = balance1();

        // 转移token给recipient
        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

        // 调用调用者的callback，需要把token还回来
        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        uint256 balance0After = balance0();
        uint256 balance1After = balance1();

        require(balance0Before.add(fee0) <= balance0After, 'F0');
        require(balance1Before.add(fee1) <= balance1After, 'F1');

        // sub is safe because we know balanceAfter is gt balanceBefore by at least fee
        // 池子实际得到的手续费
        uint256 paid0 = balance0After - balance0Before;
        uint256 paid1 = balance1After - balance1Before;

        if (paid0 > 0) {
            uint8 feeProtocol0 = slot0.feeProtocol % 16;
            uint256 fees0 = feeProtocol0 == 0 ? 0 : paid0 / feeProtocol0;
            if (uint128(fees0) > 0) protocolFees.token0 += uint128(fees0);
            // 累计全局手续费
            feeGrowthGlobal0X128 += FullMath.mulDiv(paid0 - fees0, FixedPoint128.Q128, _liquidity);
        }
        if (paid1 > 0) {
            uint8 feeProtocol1 = slot0.feeProtocol >> 4;
            uint256 fees1 = feeProtocol1 == 0 ? 0 : paid1 / feeProtocol1;
            if (uint128(fees1) > 0) protocolFees.token1 += uint128(fees1);
            // 累计全局手续费
            feeGrowthGlobal1X128 += FullMath.mulDiv(paid1 - fees1, FixedPoint128.Q128, _liquidity);
        }

        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external override lock onlyFactoryOwner {
        require(
            (feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol0 <= 10)) &&
                (feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10))
        );
        uint8 feeProtocolOld = slot0.feeProtocol;
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);
        emit SetFeeProtocol(feeProtocolOld % 16, feeProtocolOld >> 4, feeProtocol0, feeProtocol1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function collectProtocol(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock onlyFactoryOwner returns (uint128 amount0, uint128 amount1) {
        amount0 = amount0Requested > protocolFees.token0 ? protocolFees.token0 : amount0Requested;
        amount1 = amount1Requested > protocolFees.token1 ? protocolFees.token1 : amount1Requested;

        if (amount0 > 0) {
            if (amount0 == protocolFees.token0) amount0--; // ensure that the slot is not cleared, for gas savings
            protocolFees.token0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            if (amount1 == protocolFees.token1) amount1--; // ensure that the slot is not cleared, for gas savings
            protocolFees.token1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
}
