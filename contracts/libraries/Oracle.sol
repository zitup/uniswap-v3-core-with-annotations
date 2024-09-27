// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

/// @title Oracle
/// @notice Provides price and liquidity data useful for a wide variety of system designs
/// @dev Instances of stored oracle data, "observations", are collected in the oracle array
/// Every pool is initialized with an oracle array length of 1. Anyone can pay the SSTOREs to increase the
/// maximum length of the oracle array. New slots will be added when the array is fully populated.
/// Observations are overwritten when the full length of the oracle array is populated.
/// The most recent observation is available, independent of the length of the oracle array, by passing 0 to observe()
library Oracle {
    struct Observation {
        // the block timestamp of the observation
        // 这个观测的时间戳
        uint32 blockTimestamp;
        // the tick accumulator, i.e. tick * time elapsed since the pool was first initialized
        // 时间加权的累计 tick。观测的价格以tick的形式存储，好处是，tick是sqrtPrice的对数，可以使用相同精度表示更大的数据，且保证价格的精度差为0.01%（对数的底是1.0001，两个相邻 tick 之间的差距为 0.01% ）
        // uniswap v3 使用几何平均数来计算平均价格。
        // t1 到 t2 的几何平均价格为 Pt1 * ... * Pt2 的 t2 - t1 次根
        // 换算成tick表示，加上对数底，就是 tick的累积和之差 除以 时间差
        // 详细可以看这里：https://hackmd.io/d4GTJiyrQFigUp80IFb-gQ#52-Geometric-Mean-Price-Oracle-%E5%87%A0%E4%BD%95%E5%B9%B3%E5%9D%87%E6%95%B0%E4%BB%B7%E6%A0%BC%E9%A2%84%E8%A8%80%E6%9C%BA
        // 另外，v2 维护了两个token的累积价格，因为算数平均的结果不是互为倒数，v3只用维护一个，几何平均的结果互为倒数。
        int56 tickCumulative;
        // the seconds per liquidity, i.e. seconds elapsed / max(1, liquidity) since the pool was first initialized
        // 累计每流动性持续时间（秒数）
        // 通过每秒加权的流动性倒数 seconds elapsed / max(1, liquidity) 累计
        // 这个计数可以被外部流动性挖矿合约使用，以便公平地分配奖励。
        // 为了扩展这个公式，实现仅当流动性在头寸区间时才能获得奖励，Uniswap v3在每次tick被穿越时会保存一个基于该值计算后的检查点
        // 链上合约可以使用该累计数，以使他们的预言机更健壮（比如用于评估哪个手续费等级的池子更适合被作为预言机数据源）。
        uint160 secondsPerLiquidityCumulativeX128;
        // whether or not the observation is initialized
        bool initialized;
    }

    /// @notice Transforms a previous observation into a new observation, given the passage of time and the current tick and liquidity values
    /// @dev blockTimestamp _must_ be chronologically equal to or greater than last.blockTimestamp, safe for 0 or 1 overflows
    /// @param last The specified observation to be transformed
    /// @param blockTimestamp The timestamp of the new observation
    /// @param tick The active tick at the time of the new observation
    /// @param liquidity The total in-range liquidity at the time of the new observation
    /// @return Observation The newly populated observation
    // 基于上一个观测点，返回临时观测点对象，但是不写入观测点
    function transform(
        Observation memory last,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity
    ) private pure returns (Observation memory) {
        // 上一个观测点数据到到当前块的时间差
        uint32 delta = blockTimestamp - last.blockTimestamp;
        return
            Observation({
                blockTimestamp: blockTimestamp,
                tickCumulative: last.tickCumulative + int56(tick) * delta,
                secondsPerLiquidityCumulativeX128: last.secondsPerLiquidityCumulativeX128 +
                    ((uint160(delta) << 128) / (liquidity > 0 ? liquidity : 1)),
                initialized: true
            });
    }

    /// @notice Initialize the oracle array by writing the first slot. Called once for the lifecycle of the observations array
    /// @param self The stored oracle array
    /// @param time The time of the oracle initialization, via block.timestamp truncated to uint32
    /// @return cardinality The number of populated elements in the oracle array
    /// @return cardinalityNext The new length of the oracle array, independent of population
    // 初始化观测数组，位置 0 设为默认值
    function initialize(
        Observation[65535] storage self,
        uint32 time
    ) internal returns (uint16 cardinality, uint16 cardinalityNext) {
        self[0] = Observation({
            blockTimestamp: time,
            tickCumulative: 0,
            secondsPerLiquidityCumulativeX128: 0,
            initialized: true
        });
        return (1, 1);
    }

    /// @notice Writes an oracle observation to the array
    /// @dev Writable at most once per block. Index represents the most recently written element. cardinality and index must be tracked externally.
    /// If the index is at the end of the allowable array length (according to cardinality), and the next cardinality
    /// is greater than the current one, cardinality may be increased. This restriction is created to preserve ordering.
    /// @param self The stored oracle array
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param blockTimestamp The timestamp of the new observation
    /// @param tick The active tick at the time of the new observation
    /// @param liquidity The total in-range liquidity at the time of the new observation
    /// @param cardinality The number of populated elements in the oracle array
    /// @param cardinalityNext The new length of the oracle array, independent of population
    /// @return indexUpdated The new index of the most recently written element in the oracle array
    /// @return cardinalityUpdated The new cardinality of the oracle array
    // 向观测数组写入一个观测数据
    // 每个块最多写入一个
    function write(
        Observation[65535] storage self,
        uint16 index,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        Observation memory last = self[index];

        // early return if we've already written an observation this block
        // 如果已经写入，直接返回索引和数量
        if (last.blockTimestamp == blockTimestamp) return (index, cardinality);

        // if the conditions are right, we can bump the cardinality
        // 如果cardinalityNext > cardinality，则表示预言机数组被扩容过；
        // 如果index == (cardinality - 1)即上一次写入的位置是最后一个观测点，则本次需要继续写入扩容后的空间
        // 因此cardinalityUpdated使用扩容后的数组长度cardinalityNext；
        if (cardinalityNext > cardinality && index == (cardinality - 1)) {
            cardinalityUpdated = cardinalityNext;
        } else {
            // 否则继续使用旧的数组长度cardinality，因为还未写满
            cardinalityUpdated = cardinality;
        }

        // 更新本次写入观测点数组的索引indexUpdated，% cardinalityUpdated是为了计算循环写的索引
        indexUpdated = (index + 1) % cardinalityUpdated;
        // 调用transform方法计算最新的观测点数据，并写入观测点数组的indexUpdated位置
        self[indexUpdated] = transform(last, blockTimestamp, tick, liquidity);
    }

    /// @notice Prepares the oracle array to store up to `next` observations
    /// @param self The stored oracle array
    /// @param current The current next cardinality of the oracle array
    /// @param next The proposed next cardinality which will be populated in the oracle array
    /// @return next The next cardinality which will be populated in the oracle array
    function grow(Observation[65535] storage self, uint16 current, uint16 next) internal returns (uint16) {
        require(current > 0, 'I');
        // no-op if the passed next value isn't greater than the current next value
        if (next <= current) return current;
        // store in each slot to prevent fresh SSTOREs in swaps
        // this data will not be used because the initialized boolean is still false
        for (uint16 i = current; i < next; i++) self[i].blockTimestamp = 1;
        return next;
    }

    /// @notice comparator for 32-bit timestamps
    /// @dev safe for 0 or 1 overflows, a and b _must_ be chronologically before or equal to time
    /// @param time A timestamp truncated to 32 bits
    /// @param a A comparison timestamp from which to determine the relative position of `time`
    /// @param b From which to determine the relative position of `time`
    /// @return bool Whether `a` is chronologically <= `b`
    // 返回a是否按时间顺序小于b，考虑了时间溢出
    function lte(uint32 time, uint32 a, uint32 b) private pure returns (bool) {
        // if there hasn't been overflow, no need to adjust
        // 如果a和b都小于等于time，则表示没有发生溢出，因此直接返回a <= b
        if (a <= time && b <= time) return a <= b;

        // 如果a大于time，说明a溢出，直接使用a，如果a小于time，说明a没有溢出，那么就是b溢出，a需要加上2**32，主动溢出和b比较
        // 如果b大于time，说明b溢出，直接使用b，如果b小于time，说明b没有溢出，那么就是a溢出，b需要加上2**32，主动溢出和a比较
        uint256 aAdjusted = a > time ? a : a + 2 ** 32;
        uint256 bAdjusted = b > time ? b : b + 2 ** 32;

        return aAdjusted <= bAdjusted;
    }

    /// @notice Fetches the observations beforeOrAt and atOrAfter a target, i.e. where [beforeOrAt, atOrAfter] is satisfied.
    /// The result may be the same observation, or adjacent observations.
    /// @dev The answer must be contained in the array, used when the target is located within the stored observation
    /// boundaries: older than the most recent observation and younger, or the same age as, the oldest observation
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param target The timestamp at which the reserved observation should be for
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @return beforeOrAt The observation recorded before, or at, the target
    /// @return atOrAfter The observation recorded at, or after, the target
    // 二分查找离目标时间最近的两个观测点 [beforeOrAt, atOrAfter]
    function binarySearch(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        uint16 index,
        uint16 cardinality
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        // 不太理解，似乎不是最老/最新观测点，假设cardinality为10，index为5，l为6，r为15
        uint256 l = (index + 1) % cardinality; // oldest observation
        uint256 r = l + cardinality - 1; // newest observation
        uint256 i;
        while (true) {
            i = (l + r) / 2;

            beforeOrAt = self[i % cardinality];

            // we've landed on an uninitialized tick, keep searching higher (more recently)
            // 如果没有初始化，说明数组还未填满
            if (!beforeOrAt.initialized) {
                l = i + 1;
                continue;
            }

            atOrAfter = self[(i + 1) % cardinality];

            bool targetAtOrAfter = lte(time, beforeOrAt.blockTimestamp, target);

            // check if we've found the answer!
            // 目标时间target位于beforeOrAt与atOrAfter时间之间，退出二分查找，返回beforeOrAt与atOrAfter两个观测点
            if (targetAtOrAfter && lte(time, target, atOrAfter.blockTimestamp)) break;

            // target时间小于beforeOrAt，需要从左侧继续查找
            if (!targetAtOrAfter)
                r = i - 1;
                // target时间大于atOrAfter时间，则继续往右半部分查找
            else l = i + 1;
        }
    }

    /// @notice Fetches the observations beforeOrAt and atOrAfter a given target, i.e. where [beforeOrAt, atOrAfter] is satisfied
    /// @dev Assumes there is at least 1 initialized observation.
    /// Used by observeSingle() to compute the counterfactual accumulator values as of a given block timestamp.
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param target The timestamp at which the reserved observation should be for
    /// @param tick The active tick at the time of the returned or simulated observation
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param liquidity The total pool liquidity at the time of the call
    /// @param cardinality The number of populated elements in the oracle array
    /// @return beforeOrAt The observation which occurred at, or before, the given timestamp
    /// @return atOrAfter The observation which occurred at, or after, the given timestamp
    // 获取目标时间target的观测点数据beforeOrAt和atOrAfter，满足target位于[beforeOrAt, atOrAfter]之间。
    function getSurroundingObservations(
        Observation[65535] storage self,
        // 当前块时间
        uint32 time,
        // 目标时间
        uint32 target,
        // 当前tick
        int24 tick,
        // 观测数组最后写入索引
        uint16 index,
        // 当前流动性
        uint128 liquidity,
        // 预言机数组当前长度
        uint16 cardinality
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        // optimistically set before to the newest observation
        // 将beforeOrAt设置为最近一次的观测点
        beforeOrAt = self[index];

        // if the target is chronologically at or after the newest observation, we can early return
        // 如果beforeOrAt.blockTimestamp <= target(目标时间等于或者在最新观测之后)
        if (lte(time, beforeOrAt.blockTimestamp, target)) {
            if (beforeOrAt.blockTimestamp == target) {
                // if newest observation equals target, we're in the same block, so we can ignore atOrAfter
                // 如果相等，说明在同一个块，返回 beforeOrAt，忽略 atOrAfter
                return (beforeOrAt, atOrAfter);
            } else {
                // otherwise, we need to transform
                // 如果小于，计算一个临时的 atOrAfter
                return (beforeOrAt, transform(beforeOrAt, target, tick, liquidity));
            }
        }

        // now, set before to the oldest observation
        // target 大于最新观测点的时间，beforeOrAt设为最老的观测点
        // 当观测数组未溢出时，cardinality可以是index+1，此时(index + 1) % cardinality = 0
        // 也可以是比index+1大很多，此时 (index + 1) % cardinality = index + 1，所以还需要判断是否初始化来找最老观测点
        // 当观测数组溢出时，假如index是10，index + 1 = 11，cardinality 为65535，最老的观测点为索引为index + 1的观测点
        beforeOrAt = self[(index + 1) % cardinality];
        // 如果没初始化，说明数组未填满，最老的一定是索引0
        if (!beforeOrAt.initialized) beforeOrAt = self[0];

        // ensure that the target is chronologically at or after the oldest observation
        // 确认target时间大于等于最早的观测点时间
        require(lte(time, beforeOrAt.blockTimestamp, target), 'OLD');

        // if we've reached this point, we have to binary search
        // 此时target一定位于最早的和最晚观测点的时间区间内，可以使用binarySearch进行二分查找
        return binarySearch(self, time, target, index, cardinality);
    }

    /// @dev Reverts if an observation at or before the desired observation timestamp does not exist.
    /// 0 may be passed as `secondsAgo' to return the current cumulative values.
    /// If called with a timestamp falling between two observations, returns the counterfactual accumulator values
    /// at exactly the timestamp between the two observations.
    /// @param self The stored oracle array
    /// @param time The current block timestamp
    /// @param secondsAgo The amount of time to look back, in seconds, at which point to return an observation
    /// @param tick The current tick
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param liquidity The current in-range pool liquidity
    /// @param cardinality The number of populated elements in the oracle array
    /// @return tickCumulative The tick * time elapsed since the pool was first initialized, as of `secondsAgo`
    /// @return secondsPerLiquidityCumulativeX128 The time elapsed / max(1, liquidity) since the pool was first initialized, as of `secondsAgo`
    function observeSingle(
        Observation[65535] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) internal view returns (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) {
        if (secondsAgo == 0) {
            // 如果时间差等于0，返回最新的观测点数据
            Observation memory last = self[index];
            // 如果最新的观测点数据时间戳不等于当前块的时间戳，则使用transform生成一个最新的临时观测点数据，只生成，不写入
            if (last.blockTimestamp != time) last = transform(last, time, tick, liquidity);
            return (last.tickCumulative, last.secondsPerLiquidityCumulativeX128);
        }

        uint32 target = time - secondsAgo;
        // 使用getSurroundingObservations方法寻找距离目标时间最近的观测点边界beforeOrAt和atOrAfter
        (Observation memory beforeOrAt, Observation memory atOrAfter) = getSurroundingObservations(
            self,
            time,
            target,
            tick,
            index,
            liquidity,
            cardinality
        );

        if (target == beforeOrAt.blockTimestamp) {
            // we're at the left boundary
            // 位于左边界
            return (beforeOrAt.tickCumulative, beforeOrAt.secondsPerLiquidityCumulativeX128);
        } else if (target == atOrAfter.blockTimestamp) {
            // we're at the right boundary
            // 位于右边界
            return (atOrAfter.tickCumulative, atOrAfter.secondsPerLiquidityCumulativeX128);
        } else {
            // we're in the middle
            uint32 observationTimeDelta = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
            uint32 targetDelta = target - beforeOrAt.blockTimestamp;
            // 使用时间加权，加上从beforeOrAt到target的部分累计
            return (
                beforeOrAt.tickCumulative +
                    ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) / observationTimeDelta) *
                    targetDelta,
                beforeOrAt.secondsPerLiquidityCumulativeX128 +
                    uint160(
                        (uint256(
                            atOrAfter.secondsPerLiquidityCumulativeX128 - beforeOrAt.secondsPerLiquidityCumulativeX128
                        ) * targetDelta) / observationTimeDelta
                    )
            );
        }
    }

    /// @notice Returns the accumulator values as of each time seconds ago from the given time in the array of `secondsAgos`
    /// @dev Reverts if `secondsAgos` > oldest observation
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param secondsAgos Each amount of time to look back, in seconds, at which point to return an observation
    /// @param tick The current tick
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param liquidity The current in-range pool liquidity
    /// @param cardinality The number of populated elements in the oracle array
    /// @return tickCumulatives The tick * time elapsed since the pool was first initialized, as of each `secondsAgo`
    /// @return secondsPerLiquidityCumulativeX128s The cumulative seconds / max(1, liquidity) since the pool was first initialized, as of each `secondsAgo`
    // 批量获取指定时间的观测点数据，主要调用observeSingle获取每一个时间点数据
    function observe(
        Observation[65535] storage self,
        uint32 time,
        uint32[] memory secondsAgos,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) internal view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) {
        require(cardinality > 0, 'I');

        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            (tickCumulatives[i], secondsPerLiquidityCumulativeX128s[i]) = observeSingle(
                self,
                time,
                secondsAgos[i],
                tick,
                index,
                liquidity,
                cardinality
            );
        }
    }
}
