// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {LBP} from "../src/LBP.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {LiquidityBootstrapLib, Pool} from "../src/lib/LiquidityBootstrapLib.sol";
import {SafeCast} from "v4-core-lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

contract LBPTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using LiquidityBootstrapLib for Pool;
    using SafeCast for *;

    LBP hook;

    uint256 token0Liq = 1000e18;
    uint256 token1Liq = 1000e18;


    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
        LBP.PoolSettings memory poolSettings = LBP.PoolSettings({
            owner: address(this),
            asset: currency0,
            share: currency1,
            virtualAssets: 0,
            virtualShares: 0,
            weightStart: 0.1 ether,
            weightEnd: 0.9 ether,
            saleStart: block.timestamp,
            saleEnd: block.timestamp + 2 days,
            sellingAllowed: true,
            maxSharePrice: 1000 ether
        });

        deployCodeTo("LBP.sol", abi.encode(manager, poolSettings), hookAddress);
        hook = LBP(hookAddress);

        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // Add some initial liquidity
        IERC20Minimal(Currency.unwrap(key.currency0)).approve(
            hookAddress,
            1000 ether
        );
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(
            hookAddress,
            1000 ether
        );

        hook.addLiquidity(key, token0Liq, token1Liq);
    }

    function test_LiqTokenBalances() public {
        uint token0ClaimID = CurrencyLibrary.toId(currency0);
        uint token1ClaimID = CurrencyLibrary.toId(currency1);

        uint token0ClaimsBalance = manager.balanceOf(
            address(hook),
            token0ClaimID
        );
        uint token1ClaimsBalance = manager.balanceOf(
            address(hook),
            token1ClaimID
        );

        assertEq(token0ClaimsBalance, token0Liq);
        assertEq(token1ClaimsBalance, token1Liq);
    }
    
    function test_WithdrawLiqToken() public {
        vm.warp(block.timestamp + 2 days + 1);

        uint token0OwnerBalanceBefore = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(
            address(this)
        );
        uint token1OwnerBalanceBefore = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(
            address(this)
        );

        hook.withdrawLiquidity();

        uint token0ClaimID = CurrencyLibrary.toId(currency0);
        uint token1ClaimID = CurrencyLibrary.toId(currency1);

        uint token0ClaimsBalance = manager.balanceOf(
            address(hook),
            token0ClaimID
        );
        uint token1ClaimsBalance = manager.balanceOf(
            address(hook),
            token1ClaimID
        );

        assertEq(token0ClaimsBalance, 0);
        assertEq(token1ClaimsBalance, 0);

        uint token0OwnerBalanceAfter = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(
            address(this)
        );
        uint token1OwnerBalanceAfter = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(
            address(this)
        );

        assertEq(token0OwnerBalanceAfter - token0OwnerBalanceBefore, token0Liq);
        assertEq(token1OwnerBalanceAfter - token1OwnerBalanceBefore, token1Liq);
    }

    function test_cannotAddLiquidityBeforeSaleEnd() public {
        vm.expectRevert(LBP.SaleIsActive.selector);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1e18,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

     function test_AddLiquidityBeforeSaleEnd() public {
        vm.warp(block.timestamp + 2 days + 1);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1e18,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_swap_exactInput_zeroForOne() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        Pool memory args = hook.args();
        uint256 amountIn = 100e18;
        uint256 amountOut = args.previewSharesOut(amountIn);

        uint balanceToken0Before = key.currency0.balanceOfSelf();
        uint balanceToken1Before = key.currency1.balanceOfSelf();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -(amountIn.toInt256()),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );
   
        uint balanceToken0After = key.currency0.balanceOfSelf();
        uint balanceToken1After = key.currency1.balanceOfSelf();

        assertEq(balanceToken0Before - balanceToken0After, amountIn);
        assertEq(balanceToken1After - balanceToken1Before, amountOut);

        uint token1ClaimID = CurrencyLibrary.toId(currency1);
        uint token0ClaimID = CurrencyLibrary.toId(currency0);

        uint token0ClaimsBalance = manager.balanceOf(
            address(hook),
            token0ClaimID
        );
        uint token1ClaimsBalance = manager.balanceOf(
            address(hook),
            token1ClaimID
        );

        assertEq(token0Liq + amountIn, token0ClaimsBalance);
        assertEq(token1Liq - amountOut, token1ClaimsBalance);

        uint256 totalPurchased = hook.totalPurchased();

        assertEq(amountOut, totalPurchased);
    }

    function test_swap_exactOutput_zeroForOne() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        Pool memory args = hook.args();

        uint256 amountOut = 12e18;
        uint256 amountIn = args.previewAssetsIn(amountOut);
        amountOut = args.previewSharesOut(amountIn);

        uint balanceToken0Before = key.currency0.balanceOfSelf();
        uint balanceToken1Before = key.currency1.balanceOfSelf();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -(amountIn.toInt256()),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );
   
        uint balanceToken0After = key.currency0.balanceOfSelf();
        uint balanceToken1After = key.currency1.balanceOfSelf();

        assertEq(balanceToken0Before - balanceToken0After, amountIn);
        assertEq(balanceToken1After - balanceToken1Before, amountOut);

        uint token1ClaimID = CurrencyLibrary.toId(currency1);
        uint token0ClaimID = CurrencyLibrary.toId(currency0);

        uint token0ClaimsBalance = manager.balanceOf(
            address(hook),
            token0ClaimID
        );
        uint token1ClaimsBalance = manager.balanceOf(
            address(hook),
            token1ClaimID
        );

        assertEq(token0Liq + amountIn, token0ClaimsBalance);
        assertEq(token1Liq - amountOut, token1ClaimsBalance);

        uint256 totalPurchased = hook.totalPurchased();

        assertEq(amountOut, totalPurchased);
    }

     function test_swap_exactInput_oneForZero() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        Pool memory args = hook.args();
        uint256 amountInToken0 = 100e18;
        uint256 amountOutToken1 = args.previewSharesOut(amountInToken0);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -(amountInToken0.toInt256()),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        args = hook.args();
        uint256 amountOutToken0 = args.previewAssetsOut(amountOutToken1);

        uint balanceToken0Before = key.currency0.balanceOfSelf();
        uint balanceToken1Before = key.currency1.balanceOfSelf();

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -(amountOutToken1.toInt256()),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        uint balanceToken0After = key.currency0.balanceOfSelf();
        uint balanceToken1After = key.currency1.balanceOfSelf();

        assertEq(balanceToken0After - balanceToken0Before, amountOutToken0);
        assertEq(balanceToken1Before - balanceToken1After, amountOutToken1);


        uint256 totalPurchased = hook.totalPurchased();

        assertEq(totalPurchased, 0);
    }

    function test_swap_exactOutput_oneForZero() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        Pool memory args = hook.args();
        uint256 amountInToken0 = 100e18;
        uint256 amountOutToken1 = args.previewSharesOut(amountInToken0);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -(amountInToken0.toInt256()),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        args = hook.args();

        uint balanceToken0Before = key.currency0.balanceOfSelf();
        uint balanceToken1Before = key.currency1.balanceOfSelf();

        uint256 assetsOut = 10000000000000000;
        uint256 sharesIn = args.previewSharesIn(assetsOut);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: assetsOut.toInt256(),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );


        uint balanceToken0After = key.currency0.balanceOfSelf();
        uint balanceToken1After = key.currency1.balanceOfSelf();

        assertEq(balanceToken0After - balanceToken0Before, assetsOut);
        assertEq(balanceToken1Before - balanceToken1After, sharesIn);


        uint256 totalPurchased = hook.totalPurchased();

        assertEq(amountOutToken1 - sharesIn, totalPurchased);
    }
}
