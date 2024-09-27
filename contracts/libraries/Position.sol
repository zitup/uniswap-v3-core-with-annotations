// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import './FullMath.sol';
import './FixedPoint128.sol';
import './LiquidityMath.sol';

/// @title Position
/// @notice Positions represent an owner address' liquidity between a lower and upper tick boundary
/// @dev Positions store additional state for tracking fees owed to the position
library Position {
    // info stored for each user's position
    struct Info {
        // the amount of liquidity owned by this position
        // 表示上一次头寸更新时，该头寸所表示的虚拟流动性数量。
        // = sqrt(x * y) 𝑥和𝑦分别表示在任意时刻该头寸进入价格区间时，虚拟token0和token1的数量
        // 与Uniswap v2不同（每个流动性份额随时间增长），v3的流动性份额并不改变，因为手续费是单独累计。它总是等价于 sqrt(x * y)
        uint128 liquidity;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        // 上一次更新的每单位流动性代表的token0手续费，也就是上次领取手续费时的每单位流动性表示的token0手续费
        // 再次领取时，需要减去这个值，只领取手续费的增量
        uint256 feeGrowthInside0LastX128;
        // 上一次更新的每单位流动性代表的token1手续费，也就是上次领取手续费时的每单位流动性表示的token1手续费
        // 再次领取时，需要减去这个值，只领取手续费的增量
        uint256 feeGrowthInside1LastX128;
        // the fees owed to the position owner in token0/token1
        // token0 表示的未领取手续费
        uint128 tokensOwed0;
        // token1 表示的未领取手续费
        uint128 tokensOwed1;
    }

    /// @notice Returns the Info struct of a position, given an owner and position boundaries
    /// @param self The mapping containing all user positions
    /// @param owner The address of the position owner
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @return position The position info struct of the given owners' position
    function get(
        mapping(bytes32 => Info) storage self,
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (Position.Info storage position) {
        position = self[keccak256(abi.encodePacked(owner, tickLower, tickUpper))];
    }

    /// @notice Credits accumulated fees to a user's position
    /// @param self The individual position to update
    /// @param liquidityDelta The change in pool liquidity as a result of the position update
    /// @param feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries
    /// @param feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries
    // 更新头寸的流动性和可取回代币，只在mint/burn时更新
    function update(
        Info storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal {
        Info memory _self = self;

        uint128 liquidityNext;
        if (liquidityDelta == 0) {
            require(_self.liquidity > 0, 'NP'); // disallow pokes for 0 liquidity positions
            liquidityNext = _self.liquidity;
        } else {
            liquidityNext = LiquidityMath.addDelta(_self.liquidity, liquidityDelta);
        }

        // calculate accumulated fees
        // 计算累计的手续费
        // 第一次mint时，_self.liquidity为0，所以tokensOwed0和tokensOwed1都为0
        // 同一个tick范围，新增流动性时，减去上一次已经计算过的feeGrowthInside0LastX128，乘以之前的流动性，表示增加的fee
        uint128 tokensOwed0 = uint128(
            FullMath.mulDiv(feeGrowthInside0X128 - _self.feeGrowthInside0LastX128, _self.liquidity, FixedPoint128.Q128)
        );
        uint128 tokensOwed1 = uint128(
            FullMath.mulDiv(feeGrowthInside1X128 - _self.feeGrowthInside1LastX128, _self.liquidity, FixedPoint128.Q128)
        );

        // update the position
        // 更新仓位最新流动性和计算过的fee growth inside
        if (liquidityDelta != 0) self.liquidity = liquidityNext;
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
        // 如果有收益，更新收益
        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            // overflow is acceptable, have to withdraw before you hit type(uint128).max fees
            self.tokensOwed0 += tokensOwed0;
            self.tokensOwed1 += tokensOwed1;
        }
    }
}
