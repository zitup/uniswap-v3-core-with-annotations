// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import './LowGasSafeMath.sol';
import './SafeCast.sol';

import './TickMath.sol';
import './LiquidityMath.sol';

/// @title Tick
/// @notice Contains functions for managing tick processes and relevant calculations
library Tick {
    using LowGasSafeMath for int256;
    using SafeCast for int256;

    // info stored for each initialized individual tick
    struct Info {
        // the total position liquidity that references this tick
        // 当前 tick 的总仓位流动性总和，mint和burn流动性时会更新，分别增加和减少
        // 判断tick是否有流动性关联
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        // 当前 tick 的净流动性，考虑正负，mint和burn时会更新，表示当穿过这个tick时，应该增加或减少的流动性
        // mint和burn总共对应四种情况：
        // 1. mint - uppper tick, 减少流动性
        // 2. mint - lower tick, 添加流动性
        // 也就是说，mint时在这个区间添加的流动性，是添加在了lower tick上，减少在upper tick
        // 3. burn - upper tick, 添加流动性
        // 4. burn - lower tick, 减少流动性
        // burn和mint相反，需要移除流动性，减少在lower添加的流动性，增加在upper减少的流动性
        int128 liquidityNet;
        // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        // 下面三个变量不会被合约内部使用，而是帮助外部合约（如基于v3的流动性挖矿合约）更方便地获取合约信息。
        // the cumulative tick value on the other side of the tick
        // 跟踪 oracle 的 tickCumulative
        // 此tick另一侧的 tickCumulative
        int56 tickCumulativeOutside;
        // the seconds per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        // 跟踪 oracle 的 secondsPerLiquidityCumulative
        // 此tick另一侧（相对于当前tick）每单位流动性的秒数。仅具有相对意义，而非绝对意义——该值取决于tick的初始化时间
        uint160 secondsPerLiquidityOutsideX128;
        // the seconds spent on the other side of the tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        // tick 另一侧（相对于当前tick）花费的秒数
        // 仅具有相对意义，而非绝对意义——该值取决于tick的初始化时间
        uint32 secondsOutside;
        // true if the tick is initialized, i.e. the value is exactly equivalent to the expression liquidityGross != 0
        // these 8 bits are set to prevent fresh sstores when crossing newly initialized ticks
        // liquidationGross != 0 则为 true，表示已经初始化
        bool initialized;
    }

    /// @notice Derives max liquidity per tick from given tick spacing
    /// @dev Executed within the pool constructor
    /// @param tickSpacing The amount of required tick separation, realized in multiples of `tickSpacing`
    ///     e.g., a tickSpacing of 3 requires ticks to be initialized every 3rd tick i.e., ..., -6, -3, 0, 3, 6, ...
    /// @return The max liquidity per tick
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128) {
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        return type(uint128).max / numTicks;
    }

    /// @notice Retrieves fee growth data
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @param tickCurrent The current tick
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @return feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries
    /// @return feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries
    // 计算两个tick区间内部的每流动性累积手续费
    function getFeeGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        Info storage lower = self[tickLower];
        Info storage upper = self[tickUpper];

        // calculate fee growth below
        // 1. 计算tickLower的下方outside fee
        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (tickCurrent >= tickLower) {
            // 如果当前tick大于tickLower，那么直接使用tickLower的outside fee
            feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
        } else {
            // 如果当前tick小于tickLower，此时tickLower的outside是上方fee
            // 需要用global减去tickLower的outside得到tickLower下方的outside fee
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
        }

        // calculate fee growth above
        // 2. 计算tickUpper的outside fee
        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        if (tickCurrent < tickUpper) {
            // 如果当前tick小于tickUpper，那么直接使用tickUpper的outside fee
            feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
        } else {
            // 如果当前tick大于等于tickUpper，此时tickUpper的outside是下方fee
            // 需要用global减去tickUpper的outside得到tickUpper上方的outside fee
            feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
        }

        // 3. fee inside = global - lower outside - upper outside;
        feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
    }

    /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The tick that will be updated
    /// @param tickCurrent The current tick
    /// @param liquidityDelta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left)
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @param secondsPerLiquidityCumulativeX128 The all-time seconds per max(1, liquidity) of the pool
    /// @param tickCumulative The tick * time elapsed since the pool was first initialized
    /// @param time The current block timestamp cast to a uint32
    /// @param upper true for updating a position's upper tick, or false for updating a position's lower tick
    /// @param maxLiquidity The maximum liquidity allocation for a single tick
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa
    // mint/burn 更新tick信息
    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time,
        bool upper,
        uint128 maxLiquidity
    ) internal returns (bool flipped) {
        Tick.Info storage info = self[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        // 增加这个tick的总流动性
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);

        // 总流动性必须小于maxLiquidity
        require(liquidityGrossAfter <= maxLiquidity, 'LO');

        // 一个为true，一个为false时，需要flip tick
        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        // 只有被至少一个头寸作为边界端点的tick才需要𝑓𝑜(fee outside)。
        // 因此，出于效率考虑，𝑓𝑜不会被初始化（也因此，当tick被穿越时无需被更新），直到当使用该tick作为边界点创建头寸时(liquidityGrossBefore == 0)才会初始化。
        if (liquidityGrossBefore == 0) {
            // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
            // 当tick 𝑖的𝑓𝑜初始化时，它的初始值被设置成当前所有的手续费都由小于该tick时收取
            if (tick <= tickCurrent) {
                // fee growth
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
                // oracle 相关的每流动性持续时间，累计tick
                info.secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128;
                info.tickCumulativeOutside = tickCumulative;
                info.secondsOutside = time;
            }
            info.initialized = true;
        }

        // 更新两个流动性字段
        info.liquidityGross = liquidityGrossAfter;

        // when the lower (upper) tick is crossed left to right (right to left), liquidity must be added (removed)
        // liquidityNet 的值可以是正数(表示净流动性增加),也可以是负数(表示净流动性减少)，对应四种情况
        // 当流动性提供者添加流动性时:
        // 对于价格区间的下界 tick (lower),liquidityNet 增加 liquidityDelta,因为这个 tick 是流动性的起点。
        // 对于价格区间的上界 tick (upper),liquidityNet 减少 liquidityDelta,因为这个 tick 是流动性的终点。

        // 当流动性提供者移除流动性时,情况正好相反:
        // 对于价格区间的下界 tick (lower),liquidityNet 减少 liquidityDelta,因为从这个 tick 开始移除流动性。
        // 对于价格区间的上界 tick (upper),liquidityNet 增加 liquidityDelta,因为在这个 tick 处流动性的移除结束。
        // 这种处理方式确保了每个 tick 的 liquidityNet 正确反映了流动性的净变化。对于价格区间内的所有其他 tick,它们的 liquidityNet 保持不变,因为这些 tick 都被完整地覆盖在流动性区间内。
        info.liquidityNet = upper
            ? int256(info.liquidityNet).sub(liquidityDelta).toInt128()
            : int256(info.liquidityNet).add(liquidityDelta).toInt128();
    }

    /// @notice Clears tick data
    /// @param self The mapping containing all initialized tick information for initialized ticks
    /// @param tick The tick that will be cleared
    function clear(mapping(int24 => Tick.Info) storage self, int24 tick) internal {
        delete self[tick];
    }

    /// @notice Transitions to next tick as needed by price movement
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The destination tick of the transition
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @param secondsPerLiquidityCumulativeX128 The current seconds per liquidity
    /// @param tickCumulative The tick * time elapsed since the pool was first initialized
    /// @param time The current block.timestamp
    /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
    // 跨tick时，更新tick信息
    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time
    ) internal returns (int128 liquidityNet) {
        Tick.Info storage info = self[tick];
        // 全局减去上次的outside = 当前另一侧的 outside
        info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
        info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
        info.secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128 - info.secondsPerLiquidityOutsideX128;
        info.tickCumulativeOutside = tickCumulative - info.tickCumulativeOutside;
        info.secondsOutside = time - info.secondsOutside;
        // 返回净流动性
        liquidityNet = info.liquidityNet;
    }
}
