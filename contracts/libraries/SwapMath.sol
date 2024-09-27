// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import './FullMath.sol';
import './SqrtPriceMath.sol';

/// @title Computes the result of a swap within ticks
/// @notice Contains methods for computing the result of a swap within a single tick price range, i.e., a single tick.
library SwapMath {
    /// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    /// @dev The fee, plus the amount in, will never exceed the amount remaining if the swap's `amountSpecified` is positive
    /// @param sqrtRatioCurrentX96 The current sqrt price of the pool
    /// @param sqrtRatioTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    /// @param amountRemaining How much input or output amount is remaining to be swapped in/out
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// @return sqrtRatioNextX96 The price after swapping the amount in/out, not to exceed the price target
    /// @return amountIn The amount to be swapped in, of either token0 or token1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either token0 or token1, based on the direction of the swap
    /// @return feeAmount The amount of input that will be taken as a fee
    // 计算swap每一步的结果
    // 传入当前价格，目标价格，流动性，精确输入或输出的剩余代币数量，手续费基数
    // 返回这一步swap后的价格，输入token数量，输出token数量，手续费数量
    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    ) internal pure returns (uint160 sqrtRatioNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        bool exactIn = amountRemaining >= 0;

        if (exactIn) {
            // 如果是精确输入，则交易手续费需要从输入代币中扣除（注意，这里只是为了计算，去掉了需要收取的fee部分，实际还没有收取手续费）
            uint256 amountRemainingLessFee = FullMath.mulDiv(uint256(amountRemaining), 1e6 - feePips, 1e6);
            // 0换1，amountIn为token0，需要根据公式计算delta x
            // 1换0，amountIn为token1，需要根据公式计算delta y
            amountIn = zeroForOne
                ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
            // 如果可用代币数量大于amountIn，则表示该步交易可以完成，因此交换后的价格等于目标价格
            if (amountRemainingLessFee >= amountIn)
                sqrtRatioNextX96 = sqrtRatioTargetX96;
                // 否则可用代币数量小于amountIn，说明只用了这个tick的一部分流动性，需要手动计算交换后的价格
            else
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    amountRemainingLessFee,
                    zeroForOne
                );
        } else {
            // 精确输出
            // 0换1，amountOut为token1，需要根据公式计算delta y
            // 1换0，amountOut为token9，需要根据公式计算delta x
            amountOut = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
            // 如果未转换代币数量大于amountOut，说明这步交易可以完成，因此交换后的价格等于目标价格
            if (uint256(-amountRemaining) >= amountOut)
                sqrtRatioNextX96 = sqrtRatioTargetX96;
                // 否则未转换代币数量小于amountOut，说明只用了这个tick的一部分流动性，需要手动计算交换后的价格
            else
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    uint256(-amountRemaining),
                    zeroForOne
                );
        }

        // 表示这步交换是否完全完成
        bool max = sqrtRatioTargetX96 == sqrtRatioNextX96;

        // get the input/output amounts
        if (zeroForOne) {
            // 如果交换完成而且是精确输入，那么amountIn就是上面计算的amountIn，表示token0
            // 否则需要根据上面计算出来的sqrtRatioNextX96来计算实际的delta x
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true);
            // 如果交换完成而且是精确输出，那么amountOut就是上面计算的amountOut，表示token1
            // 否则需要根据上面计算出来的sqrtRatioNextX96来计算实际的delta y
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
        } else {
            // 如果交换完成而且是精确输入，那么amountIn就是上面计算的amountIn，表示token1
            // 否则需要根据上面计算出来的sqrtRatioNextX96来计算实际的delta y
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
            // 如果交换完成而且是精确输出，那么amountOut就是上面计算的amountOut，表示token0
            // 否则需要根据上面计算出来的sqrtRatioNextX96来计算实际的delta x
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
        }

        // cap the output amount to not exceed the remaining output amount
        // 如果是精确输出，而且amountOut大于剩余未转换代币数量，需要确保所得输出没有超过指定输出
        if (!exactIn && amountOut > uint256(-amountRemaining)) {
            amountOut = uint256(-amountRemaining);
        }

        // 如果是精确输入，而且交换后的价格不等于目标价格（说明只用了这个tick的一部分流动性，相当于是最后一次交换）
        // 直接把可转换数量剩余部分作为手续费
        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            // we didn't reach the target, so take the remainder of the maximum input as fee
            feeAmount = uint256(amountRemaining) - amountIn;
        } else {
            // 其它情况，精确输入但是达到目标价格或精确输出，从输入token数量，即amountIn中扣除手续费
            // 这里使用1e6 - feePips，而不是用1e6，个人理解为取了这两个中的最大值
            // 因为这里的amountIn可能为精确输入和max时，通过已经去掉了手续费计算出来的，这时候不能用1e6当分母
            // 或者是精确输出，这时候计算价格sqrtRatioNextX96时，都用的是amountRemaining，没有去掉手续费，通过它算出来的amountIn，是包含手续费的，所以应该用1e6
            // 为了池子不损失手续费，取他们中比较大的值
            feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
        }
    }
}
