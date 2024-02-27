// test/UniswapV3Pool.t.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "./ERC20Mintable.sol";
import "../src/UniswapV3Pool.sol";

import "../src/IUniswapV3Pool.sol";

contract UniswapV3PoolTest is Test {
    ERC20Mintable public token0;
    ERC20Mintable public token1;
    UniswapV3Pool public pool;

    bool transferInMintCallback = true;
    bool transferInSwapCallback = true;

    struct TestCaseParams {
        uint256 wethBalance;
        uint256 usdcBalance;
        int24 currentTick;
        int24 lowerTick;
        int24 upperTick;
        uint128 liquidity;
        uint160 currentSqrtP;
        bool transferInMintCallback;
        bool transferInSwapCallback;
        bool mintLiquidity;
    }

    function setUp() public {
        token0 = new ERC20Mintable("Ether", "ETH", 18);
        token1 = new ERC20Mintable("USDC", "USDC", 18);
    }

    function setupTestCase(TestCaseParams memory params) internal returns (uint poolBalance0, uint poolBalance1) {
        token0.mint(address(this), params.wethBalance);
        token1.mint(address(this), params.usdcBalance);

        pool = new UniswapV3Pool(
            address(token0), 
            address(token1), 
            params.currentSqrtP, 
            params.currentTick
        );

        if (params.mintLiquidity) {
            token0.approve(address(this), params.wethBalance);
            token1.approve(address(this), params.usdcBalance);

            UniswapV3Pool.CallbackData memory extra = IUniswapV3Pool.CallbackData({
            token0: address(token0),
            token1: address(token1),
            payer: address(this)
        });

            (poolBalance0, poolBalance1) = pool.mint(
                address(this),
                params.lowerTick,
                params.upperTick,
                params.liquidity,
                abi.encode(extra)
            );
        }

        transferInMintCallback = params.transferInMintCallback;
        transferInSwapCallback = params.transferInSwapCallback;
    }

    function uniswapV3MintCallback(uint amount0, uint amount1, bytes calldata data) public {
        if (transferInSwapCallback) {
            UniswapV3Pool.CallbackData memory extra = abi.decode(
                data,
                (IUniswapV3Pool.CallbackData)
            );

            if (amount0 > 0) {
                IERC20(extra.token0).transferFrom(
                    extra.payer,
                    msg.sender,
                    uint256(amount0)
                );
            }

            if (amount1 > 0) {
                IERC20(extra.token1).transferFrom(
                    extra.payer,
                    msg.sender,
                    uint256(amount1)
                );
            }
        }
    }

    function uniswapV3SwapCallback(int amount0, int amount1, bytes calldata data) public {
        // Amounts can be positive or negative.
        // We only want to transfer if the amount is positive
        if (amount0 > 0) {
            token0.transfer(msg.sender, uint256(amount0));
        }

        if (amount1 > 0) {
            token1.transfer(msg.sender, uint256(amount1));
        }
    }

    function testMintSuccess() public {
        TestCaseParams memory params = TestCaseParams({
            wethBalance: 1 ether,
            usdcBalance: 5000 ether,
            currentTick: 85176,
            lowerTick: 84222,
            upperTick: 86129,
            liquidity: 1517882343751509868544,
            currentSqrtP: 5602277097478614198912276234240,
            transferInMintCallback: true,
            transferInSwapCallback: true,
            mintLiquidity: true
        });

        (uint256 poolBalance0, uint256 poolBalance1) = setupTestCase(params);

        uint256 expectedAmount0 = 0.998976618347425280 ether;
        uint256 expectedAmount1 = 5000 ether;
        assertEq(
            poolBalance0,
            expectedAmount0,
            "incorrect token0 deposited amount"
        );
        assertEq(
            poolBalance1,
            expectedAmount1,
            "incorrect token1 deposited amount"
        );

        bytes32 positionKey = keccak256(abi.encodePacked(address(this), params.lowerTick, params.upperTick));
        uint128 posLiquidty = pool.positions(positionKey);
        
        assertEq(
            posLiquidty,
            params.liquidity,
            "incorrect liquidity minted"
        );

        (bool tickInitialized, uint128 tickLiquidity) = pool.ticks(params.lowerTick);
        assertTrue(tickInitialized);
        assertEq(
            tickLiquidity,
            params.liquidity,
            "incorrect liquidity minted"
        );

        (tickInitialized, tickLiquidity) = pool.ticks(params.upperTick);
        assertTrue(tickInitialized);
        assertEq(
            tickLiquidity,
            params.liquidity,
            "incorrect liquidity minted"
        );

        (uint160 sqrtPriceX96, int24 tick) = pool.slot0();
        assertEq(
            sqrtPriceX96,
            5602277097478614198912276234240,
            "incorrect sqrtPriceX96"
        );
        assertEq(tick, 85176, "invalid current tick");
        assertEq(pool.liquidity(), 1517882343751509868544, "incorrect liquidity minted");
    }

    function testSwapBuyEth() public {
        TestCaseParams memory params = TestCaseParams({
            wethBalance: 1 ether,
            usdcBalance: 5000 ether,
            currentTick: 85176,
            lowerTick: 84222,
            upperTick: 86129,
            liquidity: 1517882343751509868544,
            currentSqrtP: 5602277097478614198912276234240,
            transferInMintCallback: true,
            transferInSwapCallback: true,
            mintLiquidity: true
        });
        (uint256 poolBalance0, uint256 poolBalance1) = setupTestCase(params);

        // Get ETH balance of this contract before swap, for asserts later in test
        uint userBalance0Before = token0.balanceOf(address(this));

        // We are swapping 42 USDC for ETH
        token1.mint(address(this), 42 ether);

        // log balance of this
        console2.log("this balance", token0.balanceOf(address(this)), token1.balanceOf(address(this)));

        // log address of this
        console2.log("this address", address(this));

        console2.log("Pool.t::calling swap");

        (int amount0Delta, int256 amount1Delta) = pool.swap(address(this), "");

        // Check token amounts swapped are correct
        assertEq(
            amount0Delta,
            -0.008396714242162444 ether,
            "incorrect ETH out"
        );
        assertEq(
            amount1Delta,
            42 ether,
            "incorrect USDC in"
        );

        // Ensure tokens were transferred from the caller
        console2.log("userBalance0Before", userBalance0Before);
        assertEq(
            token0.balanceOf(address(this)),
            userBalance0Before + uint(-amount0Delta),
            "incorrect user ETH balance"
        );
        assertEq(
            token1.balanceOf(address(this)),
            0,
            "incorrect user USDC balance"
        );

        // Ensure tokens were transferred to the pool
        assertEq(
            token0.balanceOf(address(pool)),
            uint(int(poolBalance0) + amount0Delta),
            "incorrect pool ETH balance"
        );
        assertEq(
            token1.balanceOf(address(pool)),
            uint(int(poolBalance1) + amount1Delta),
            "incorrect pool USDC balance"
        );

        // Check pool state was updated correctly
        (uint160 sqrtPriceX96, int24 tick) = pool.slot0();
        assertEq(
            sqrtPriceX96,
            5604469350942327889444743441197,
            "incorrect sqrtPriceX96"
        );
        assertEq(tick, 85184, "invalid current tick");
        assertEq(pool.liquidity(), 1517882343751509868544, "incorrect liquidity minted");

    }

}
