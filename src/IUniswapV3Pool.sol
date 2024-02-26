// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

interface IUniswapV3Pool {
    struct CallbackData {
        address token0;
        address token1;
        address payer;
    }
}