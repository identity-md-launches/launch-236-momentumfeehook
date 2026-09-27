// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentumFixture} from "./utils/MomentumFixture.sol";
import {MomentumFeeHook} from "../src/MomentumFeeHook.sol";
import {Momentum as MomentumToken} from "../src/Momentum.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

/// @notice Rehearses the launch the factory performs: a fresh MOMO, the native-ETH pool (fee 3000,
/// tickSpacing 60) opened with this hook, one-sided MOMO liquidity seeded below the opening price, then
/// the first buy into a pool holding no ETH, followed by a sell.
contract LaunchRehearsalTest is MomentumFixture {
    using StateLibrary for IPoolManager;

    /// @dev About 1,000 MOMO per ETH. Not a multiple of the tick spacing, so the seed's upper tick
    /// (69060) is strictly below the opening tick and the pool opens with zero in-range liquidity.
    int24 internal constant OPEN_TICK = 69_090;
    int24 internal constant SEED_UPPER = 69_060;
    uint256 internal constant SEED_MOMO = 900_000_000 ether;

    MomentumToken internal launched;
    PoolKey internal launch;
    PoolId internal launchId;
    uint160 internal openPrice;

    function setUp() public override {
        super.setUp();

        launched = new MomentumToken();
        launched.approve(address(swapRouter), type(uint256).max);
        launched.approve(address(lpRouter), type(uint256).max);

        launch = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(launched)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        launchId = launch.toId();
        openPrice = TickMath.getSqrtPriceAtTick(OPEN_TICK);

        manager.initialize(launch, openPrice);

        uint160 lower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(60));
        uint160 upper = TickMath.getSqrtPriceAtTick(SEED_UPPER);
        uint256 liquidity = FullMath.mulDiv(SEED_MOMO, FixedPoint96.Q96, upper - lower);
        BalanceDelta seeded = lpRouter.modifyLiquidity(
            launch,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60), tickUpper: SEED_UPPER, liquidityDelta: int256(liquidity), salt: 0
            }),
            ""
        );
        require(seeded.amount0() == 0, "seed must be MOMO only");
    }

    function test_seed_isOneSidedAndThePoolHoldsNoEth() public view {
        assertEq(manager.getLiquidity(launchId), 0, "no in-range liquidity at the opening price");
        (uint160 price,,,) = manager.getSlot0(launchId);
        assertEq(price, openPrice);
        assertLe(SEED_MOMO - launched.balanceOf(address(manager)), 1 ether, "seed landed in the manager");
        assertEq(hook.nextFeeBps(launchId, true), 30);
    }

    function test_rehearsal_firstBuyIntoTheEthlessPoolThenASell() public {
        vm.expectRevert(MomentumFeeHook.NothingToDonate.selector);
        hook.donateFees(launch);

        // First buy: 0.1 ETH in. The price crosses the empty gap and enters the seed.
        uint256 momoBefore = launched.balanceOf(address(this));
        BalanceDelta buy = _swapLaunch(true, -0.1 ether, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(buy.amount0(), -0.1 ether, "paid exactly the ETH in");
        uint256 received = launched.balanceOf(address(this)) - momoBefore;
        assertEq(int256(received), int256(buy.amount1()));
        (, uint256 fee1) = hook.accrued(launchId);
        assertEq(fee1, _ceilBps(received + fee1, 30), "first buy pays 0.3% of the pool's output");
        assertApproxEqRel(received + fee1, 99.7 ether, 0.01e18, "about 1,000 MOMO/ETH less the LP fee");
        assertGt(manager.getLiquidity(launchId), 0, "now trading inside the seed");

        (bool isBuy, uint256 n) = hook.streak(launchId);
        assertTrue(isBuy);
        assertEq(n, 1);
        assertEq(hook.nextFeeBps(launchId, true), 40);

        // Then a sell: 20 MOMO in. Opposite direction, qualifying, so 0.3% of the ETH out and a reset.
        uint256 ethBefore = address(this).balance;
        BalanceDelta sell = _swapLaunch(false, -20 ether, TickMath.MAX_SQRT_PRICE - 1);
        assertEq(sell.amount1(), -20 ether);
        uint256 ethOut = address(this).balance - ethBefore;
        (uint256 fee0,) = hook.accrued(launchId);
        assertEq(fee0, _ceilBps(ethOut + fee0, 30), "the sell pays 0.3% of the pool's ETH output");
        (isBuy, n) = hook.streak(launchId);
        assertFalse(isBuy);
        assertEq(n, 1);

        assertEq(_claims(launch.currency0), fee0);
        assertEq(_claims(launch.currency1), fee1);

        (uint256 d0, uint256 d1) = hook.donateFees(launch);
        assertEq(d0, fee0);
        assertEq(d1, fee1);
        assertEq(_claims(launch.currency0), 0);
        assertEq(_claims(launch.currency1), 0);
    }

    function test_donateFees_revertsNoLiquidityOutOfRangeAndSucceedsLater() public {
        _swapLaunch(true, -0.1 ether, TickMath.MIN_SQRT_PRICE + 1);

        // Sell back up to the opening price: out of the seed's range again, zero in-range liquidity.
        _swapLaunch(false, -1_000_000 ether, openPrice);
        assertEq(manager.getLiquidity(launchId), 0);
        (uint256 a0, uint256 a1) = hook.accrued(launchId);
        assertGt(a0, 0);
        assertGt(a1, 0);

        vm.expectRevert(MomentumFeeHook.NoLiquidity.selector);
        hook.donateFees(launch);
        (uint256 k0, uint256 k1) = hook.accrued(launchId);
        assertEq(k0, a0, "claims wait");
        assertEq(k1, a1, "claims wait");

        // A later buy brings the price back into range, and the waiting claims can be donated.
        _swapLaunch(true, -0.05 ether, TickMath.MIN_SQRT_PRICE + 1);
        (uint256 w0, uint256 w1) = hook.accrued(launchId);
        (uint256 d0, uint256 d1) = hook.donateFees(launch);
        assertEq(d0, w0);
        assertEq(d1, w1);
        assertGe(d0, a0);
        assertGe(d1, a1);
    }

    function test_dustFirstBuy_paysButStartsNoStreak() public {
        _swapLaunch(true, -0.0009 ether, TickMath.MIN_SQRT_PRICE + 1);
        (, uint256 n) = hook.streak(launchId);
        assertEq(n, 0);
        (, uint256 a1) = hook.accrued(launchId);
        assertGt(a1, 0);
    }

    function _swapLaunch(bool buy, int256 amountSpecified, uint160 limit) internal returns (BalanceDelta) {
        uint256 value = buy ? uint256(-amountSpecified) : 0;
        return swapRouter.swap{value: value}(
            launch,
            SwapParams({zeroForOne: buy, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
