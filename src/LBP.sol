// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettleTake} from "v4-core/libraries/CurrencySettleTake.sol";
import {Hooks, BeforeSwapDeltaLibrary} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "./forks/BaseHook.sol";

import {SafeCast} from "v4-core-lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

import {WeightedMathLib} from "./lib/WeightedMathLib.sol";
import {LiquidityBootstrapLib, Pool} from "./lib/LiquidityBootstrapLib.sol";

contract LBP is BaseHook {
    using CurrencySettleTake for Currency;
    using SafeCast for *;
    using WeightedMathLib for *;
    using LiquidityBootstrapLib for Pool;

    error SalePeriodLow();
    error InvalidWeightConfig();
    error SaleIsActive();
    error SaleHasFinished();
    error NotOwner();
    error TotalPurchasedUnderflow();

    struct CallbackData {
        uint256 assets;
        uint256 shares;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    struct PoolSettings {
        address owner;
        Currency share;
        Currency asset;
        uint256 virtualAssets;
        uint256 virtualShares;
        uint64 weightStart;
        uint64 weightEnd;
        uint256 saleStart;
        uint256 saleEnd;
        bool sellingAllowed;
        uint256 maxSharePrice;
    }

    PoolSettings public poolSettings;

    uint256 public immutable token0ClaimID;
    uint256 public immutable token1ClaimID;
    uint256 public totalPurchased;

    modifier onlyOwner() {
        if (msg.sender != poolSettings.owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager poolManager, PoolSettings memory _args) BaseHook(poolManager) {
         if (
            uint40(block.timestamp + 1 days) > _args.saleEnd ||
            _args.saleEnd - _args.saleStart < uint40(1 days)
        ) {
            revert SalePeriodLow();
        }

        if (
            _args.weightStart < 0.01 ether ||
            _args.weightStart > 0.99 ether ||
            _args.weightEnd > 0.99 ether ||
            _args.weightEnd < 0.01 ether
        ) {
            revert InvalidWeightConfig();
        }

        poolSettings = _args;
        token0ClaimID = CurrencyLibrary.toId(_args.asset);
        token1ClaimID = CurrencyLibrary.toId(_args.share);
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view poolManagerOnly override returns (bytes4) {
        if(block.timestamp < poolSettings.saleEnd) {
            revert SaleIsActive();
        } else {
            return LBP.beforeAddLiquidity.selector;
        }
    }

    function addLiquidity(PoolKey calldata key, uint256 assets, uint256 shares) external {
        if (block.timestamp < poolSettings.saleEnd) {
            poolManager.unlock(
                abi.encode(
                    CallbackData(
                        assets,
                        shares,
                        key.currency0,
                        key.currency1,
                        msg.sender
                    )
                )
            );
        } else {
            revert SaleHasFinished();
        }
    }

    function withdrawLiquidity() external onlyOwner {
        if (block.timestamp <= poolSettings.saleEnd) revert SaleIsActive();

        poolManager.unlock("");
    }

    function unlockCallback(
        bytes calldata data
    ) external override poolManagerOnly returns (bytes memory) {
        if (block.timestamp < poolSettings.saleEnd) {     
            CallbackData memory callbackData = abi.decode(data, (CallbackData));

            callbackData.currency0.settle(
                poolManager,
                callbackData.sender,
                callbackData.assets,
                false 
            );
            callbackData.currency1.settle(
                poolManager,
                callbackData.sender,
                callbackData.shares,
                false
            );


            callbackData.currency0.take(
                poolManager,
                address(this),
                callbackData.assets,
                true
            );
            callbackData.currency1.take(
                poolManager,
                address(this),
                callbackData.shares,
                true
            );
        } else {
            uint256 totalAssets = poolManager.balanceOf(
                address(this),
                token0ClaimID
            );

            uint256 totalShares  = poolManager.balanceOf(
                address(this),
                token1ClaimID
            );

            PoolSettings memory _poolSettings = poolSettings;
            _poolSettings.asset.settle(poolManager, address(this), totalAssets, true);
            _poolSettings.share.settle(poolManager, address(this), totalShares, true);

            _poolSettings.asset.take(poolManager, poolSettings.owner, totalAssets, false);
            _poolSettings.share.take(poolManager, poolSettings.owner, totalShares, false);
        }

        return "";
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external poolManagerOnly override returns (bytes4, BeforeSwapDelta) {
        if(block.timestamp >= poolSettings.saleEnd) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA);
        }

        BeforeSwapDelta beforeSwapDelta;
        Pool memory pool = args();
        IPoolManager manager = poolManager;
        if (params.zeroForOne) {
            if (params.amountSpecified > 0) {
                //swap token0 for exact token1
                uint256 sharesOut = params.amountSpecified.toUint256();
                uint256 assetsIn = pool.previewAssetsIn(sharesOut);
                totalPurchased += sharesOut;

                beforeSwapDelta = toBeforeSwapDelta(
                    -sharesOut.toInt256().toInt128(),
                    assetsIn.toInt256().toInt128()
                );

                key.currency0.take(
                    manager,
                    address(this),
                    assetsIn,
                    true
                );
                
                key.currency1.settle(
                    manager,
                    address(this),
                    sharesOut,
                    true
                );
            } else {
                //swap exact token0 for token1
                uint256 assetsIn = (-params.amountSpecified).toUint256();
                uint256 sharesOut = pool.previewSharesOut(assetsIn);
                totalPurchased += sharesOut;

                beforeSwapDelta = toBeforeSwapDelta(
                    int128(-params.amountSpecified),
                    -sharesOut.toInt256().toInt128()
                );

                key.currency0.take(
                    manager,
                    address(this),
                    assetsIn,
                    true
                );
                
                key.currency1.settle(
                    manager,
                    address(this),
                    sharesOut,
                    true
                );
            }
        } else {
            if (params.amountSpecified > 0) {
                //swap token1 for exact token0
                uint256 assetsOut = params.amountSpecified.toUint256();
                uint256 sharesIn = pool.previewSharesIn(assetsOut);

                if (sharesIn > totalPurchased) revert TotalPurchasedUnderflow();
                totalPurchased -= sharesIn;

                beforeSwapDelta = toBeforeSwapDelta(
                    -(params.amountSpecified).toInt128(),
                    sharesIn.toInt256().toInt128()
                );
                
                key.currency0.settle(
                    manager,
                    address(this),
                    assetsOut,
                    true
                );
                
                key.currency1.take(
                    manager,
                    address(this),
                    sharesIn,
                    true
                );
            } else {
                //swap exact token1 for token0
                uint256 sharesIn = (-params.amountSpecified).toUint256();
                uint256 assetsOut = pool.previewAssetsOut(sharesIn);

                if (sharesIn > totalPurchased) revert TotalPurchasedUnderflow();
                totalPurchased -= sharesIn;

                beforeSwapDelta = toBeforeSwapDelta(
                    sharesIn.toInt256().toInt128(),
                    -(assetsOut.toInt256()).toInt128()
                );

                key.currency0.settle(
                    manager,
                    address(this),
                    assetsOut,
                    true
                );
                
                key.currency1.take(
                    manager,
                    address(this),
                    sharesIn,
                    true
                );
            }
        }

        return (this.beforeSwap.selector, beforeSwapDelta);
    }

     function args() public view virtual returns (Pool memory) {
        PoolSettings memory _poolSettings = poolSettings;
        return Pool(
            Currency.unwrap(_poolSettings.asset),
            Currency.unwrap(_poolSettings.share),
            _poolSettings.virtualAssets,
            _poolSettings.virtualShares,
            poolManager.balanceOf(
                address(this),
                token0ClaimID
            ),
            poolManager.balanceOf(
                address(this),
                token1ClaimID
            ),
            _poolSettings.weightStart,
            _poolSettings.weightEnd,
            _poolSettings.saleStart,
            _poolSettings.saleEnd,
            totalPurchased,
            _poolSettings.maxSharePrice
        );
    }
}
