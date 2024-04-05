pragma solidity ^0.8.14;

import "../lib/forge-std/src/console2.sol";
import "../lib/forge-std/src/interfaces/IERC20.sol";
import "./IUniswapV3MintCallback.sol";
import "./IUniswapV3SwapCallback.sol";
import "./IUniswapV3Pool.sol";
import "./TickBitmap.sol" as TickBitmap;
import "./Tick.sol" as TickLib;
import "./TickMath.sol";
import "./Math.sol";
import "./SwapMath.sol";

// src/lib/Position.sol
library Position {
    struct Info {
        uint128 liquidity;
    }

    function update(Info storage self, uint128 liquidityDelta) internal {
        uint128 liquidityBefore = self.liquidity;
        uint128 liquidityAfter = liquidityBefore + liquidityDelta;

        self.liquidity = liquidityAfter;
    }

    function get(mapping(bytes32 => Info) storage self, address owner, int24 lowerTick, int24 upperTick)
        internal
        view
        returns (Position.Info storage position)
    {
        position = self[keccak256(abi.encodePacked(owner, lowerTick, upperTick))];
    }
}

contract UniswapV3Pool is IUniswapV3Pool {
    using TickLib.Tick for mapping(int24 => TickLib.Tick.Info);
    using TickBitmap.TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    // Pool tokens, immutable
    address public immutable token0;
    address public immutable token1;

    // Packing variables that are read together
    struct Slot0 {
        // Current sqrt(P)
        uint160 sqrtPriceX96;
        // Current tick
        int24 tick;
    }

    // Struct to hold the overall state of the swap
    // amountSpecifiedRemaining: The amount of token0 or token1 remaining that need to be bought by the pool. Used during looping to fulfill the order. When zero, the swap is done
    // amountCalculated: The amount of token0 or token1 calculated to be sold to the user
    // sqrtPriceX96: New current price of token0/token1 after swap
    // tick: New current tick after swap
    struct SwapState {
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
    }

    // Struct to hold the state of the swap at each step
    // sqrtPriceStartX96: The price of token0/token1 at the start of the step
    // nextTick: Next intialised tick that will provide liquidity
    // sqrtPriceNextX96: Next price at the next tick.
    // amountIn: The amountIn of token0 or token1 that can be bought by the liquidity at the current iteration
    // amountOut: The amountOut of token0 or token1 that can be sold by the liquidity at the current iteration
    struct StepState {
        uint160 sqrtPriceStartX96;
        int24 nextTick;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
    }

    Slot0 public slot0;

    // Amount of liquidity, L
    uint128 public liquidity;

    // Ticks info
    mapping(int24 => TickLib.Tick.Info) public ticks;
    mapping(int16 => uint256) public tickBitmap;
    // Positions info
    mapping(bytes32 => Position.Info) public positions;

    error InvalidTickRange();
    error ZeroLiquidity();
    error InsufficientInputAmount();

    event Mint(
        address indexed sender,
        address indexed owner,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    constructor(address token0_, address token1_, uint160 sqrtPriceX96, int24 tick) {
        token0 = token0_;
        token1 = token1_;

        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: 85176});
    }

    function mint(address owner, int24 lowerTick, int24 upperTick, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (lowerTick >= upperTick || lowerTick < TickMath.MIN_TICK || lowerTick > TickMath.MAX_TICK) {
            revert InvalidTickRange();
        }

        if (amount == 0) revert ZeroLiquidity();

        bool flippedLower = ticks.update(lowerTick, amount);
        bool flippedUpper = ticks.update(upperTick, amount);

        if (flippedLower) tickBitmap.flipTick(lowerTick, 1);
        if (flippedUpper) tickBitmap.flipTick(upperTick, 1);

        Position.Info storage position = positions.get(owner, lowerTick, upperTick);
        position.update(amount);

        Slot0 memory slot0_ = slot0;

        amount0 = Math.calcAmount0Delta(slot0_.sqrtPriceX96, TickMath.getSqrtRatioAtTick(upperTick), amount);
        amount1 = Math.calcAmount1Delta(slot0_.sqrtPriceX96, TickMath.getSqrtRatioAtTick(lowerTick), amount);

        liquidity += uint128(amount);

        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        IUniswapV3MintCallback mintCallback = IUniswapV3MintCallback(msg.sender);
        mintCallback.uniswapV3MintCallback(amount0, amount1, data);
        if (amount0 > 0 && balance0Before + amount0 > balance0()) revert InsufficientInputAmount();
        if (amount1 > 0 && balance1Before + amount1 > balance1()) revert InsufficientInputAmount();

        emit Mint(msg.sender, owner, lowerTick, upperTick, amount, amount0, amount1);
    }

    function swap(address recipient, bool zeroForOne, uint256 amountSpecified, bytes calldata data)
        public
        returns (int256 amount0, int256 amount1)
    {
        console2.log("In swap");
        // Get the current slot0 state
        Slot0 memory slot0_ = slot0;

        // Before filling an order, initialize a new SwapState
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick
        });

        while (state.amountSpecifiedRemaining > 0) {
            // console2.log("In loop");
            StepState memory step;

            // Setup price range from sPSX96 to sPNX96
            // Start of price range
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.nextTick,) = tickBitmap.nextInitializedTickWithinOneWord(state.tick, 1, zeroForOne);

            // End of price range - price at next initialised tick
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);

            // Calculate amounts that can be provided by current price range, and the new current price that the swap will result in
            (state.sqrtPriceX96, step.amountIn, step.amountOut) = SwapMath.computeSwapStep(
                state.sqrtPriceX96, step.sqrtPriceNextX96, liquidity, state.amountSpecifiedRemaining
            );

            // Update SwapState struct:
            // step.amountIn: no. of tokens the price range can buy from the user
            // step.amountOut: no. of tokens the price range can sell to the user
            // state.sqrtPriceX96: new price after the swap
            state.amountSpecifiedRemaining -= step.amountIn;
            state.amountCalculated += step.amountOut;
            state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);

            console2.log("AmountIn: ", step.amountIn);
            console2.log("amountSpecifiedRemaining: ", state.amountSpecifiedRemaining);
            console2.log("AmountCalculated: ", state.amountCalculated);
        }

        if (state.tick != slot0_.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        }

        (amount0, amount1) = zeroForOne 
            ? (int256(amountSpecified - state.amountSpecifiedRemaining), -int256(state.amountCalculated)) 
            : (-int256(state.amountCalculated), int256(amountSpecified - state.amountSpecifiedRemaining));

        if (zeroForOne) {
            IERC20(token1).transfer(recipient, uint(-amount1));

            uint balance0Before = balance0(); 
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0, 
                amount1, 
                data
            );
            if (balance0Before + uint(amount0) > balance0()) revert InsufficientInputAmount();
            emit Swap(msg.sender, recipient, amount0, amount1, slot0.sqrtPriceX96, liquidity, slot0.tick);
        } else {
            IERC20(token0).transfer(recipient, uint(-amount0));

            uint balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0, 
                amount1, 
                data
            );
            if (balance1Before + uint(amount1) > balance1()) revert InsufficientInputAmount();
            emit Swap(msg.sender, recipient, amount0, amount1, slot0.sqrtPriceX96, liquidity, slot0.tick);
        }
    }

    function balance0() internal returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    function balance1() internal returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }
}
