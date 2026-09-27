// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MomentumFixture} from "./utils/MomentumFixture.sol";
import {MomentumFeeHook} from "../src/MomentumFeeHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Drives random swaps and donations across two hooked pools that share both currencies, and
/// keeps its own model of each pool's streak. Fees are measured from the PoolManager's ERC-6909
/// balances, not from the hook's bookkeeping.
contract MomentumHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable router;
    MomentumFeeHook internal immutable hook;
    IERC20 internal immutable momo;
    PoolKey[2] internal keys;

    struct Model {
        bool buy;
        uint256 n;
    }

    mapping(uint256 => Model) public model;
    uint256 public feeMismatches;
    uint256 public swaps;
    uint256 public donations;

    constructor(
        IPoolManager manager_,
        PoolSwapTest router_,
        MomentumFeeHook hook_,
        PoolKey memory a,
        PoolKey memory b
    ) {
        manager = manager_;
        router = router_;
        hook = hook_;
        keys[0] = a;
        keys[1] = b;
        momo = IERC20(Currency.unwrap(a.currency1));
        momo.approve(address(router_), type(uint256).max);
    }

    function key(uint256 i) external view returns (PoolKey memory) {
        return keys[i];
    }

    function swap(uint256 poolSeed, bool buy, bool exactInput, uint256 amount) external {
        uint256 i = poolSeed % 2;
        amount = amount % 4 == 0 ? bound(amount, 1, 0.002 ether) : bound(amount, 1, 2 ether);

        Model memory m = model[i];
        uint256 expectedBps = m.buy == buy ? (m.n >= 17 ? 200 : 30 + 10 * m.n) : 30;
        (int256 pool0, int256 pool1, uint256 fee0, uint256 fee1) = _swapAndMeasure(keys[i], buy, exactInput, amount);
        swaps++;

        bool unspecifiedIs1 = exactInput == buy;
        uint256 expectedFee = (_abs(unspecifiedIs1 ? pool1 : pool0) * expectedBps + 9_999) / 10_000;
        if ((unspecifiedIs1 ? fee1 : fee0) != expectedFee || (unspecifiedIs1 ? fee0 : fee1) != 0) feeMismatches++;

        if (_abs(pool0) >= 0.001 ether) {
            if (m.buy == buy) {
                m.n += 1;
            } else {
                m.buy = buy;
                m.n = 1;
            }
            model[i] = m;
        }
    }

    /// @dev Swaps, then undoes the hook's delta to recover the pool's own swap delta.
    function _swapAndMeasure(PoolKey memory k, bool buy, bool exactInput, uint256 amount)
        internal
        returns (int256 pool0, int256 pool1, uint256 fee0, uint256 fee1)
    {
        uint256 claims0 = manager.balanceOf(address(hook), k.currency0.toId());
        uint256 claims1 = manager.balanceOf(address(hook), k.currency1.toId());

        BalanceDelta d = router.swap{value: buy ? (exactInput ? amount : 3 * amount + 1 ether) : 0}(
            k,
            SwapParams({
                zeroForOne: buy,
                amountSpecified: exactInput ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        fee0 = manager.balanceOf(address(hook), k.currency0.toId()) - claims0;
        fee1 = manager.balanceOf(address(hook), k.currency1.toId()) - claims1;
        pool0 = int256(d.amount0()) + int256(fee0);
        pool1 = int256(d.amount1()) + int256(fee1);
    }

    function donate(uint256 poolSeed) external {
        PoolKey memory k = keys[poolSeed % 2];
        (uint256 a0, uint256 a1) = hook.accrued(k.toId());
        if (a0 == 0 && a1 == 0) return;
        if (manager.getLiquidity(k.toId()) == 0) return;
        hook.donateFees(k);
        donations++;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        // casting to 'uint256' is safe because the value is non-negative after the sign check
        // forge-lint: disable-next-line(unsafe-typecast)
        return x < 0 ? uint256(-x) : uint256(x);
    }

    receive() external payable {}
}

contract MomentumFeeHookInvariantTest is MomentumFixture {
    MomentumHandler internal handler;
    PoolKey internal second;

    function setUp() public override {
        super.setUp();
        second = key;
        second.fee = 500;
        second.tickSpacing = 10;
        _openFullRange(second);

        handler = new MomentumHandler(manager, swapRouter, hook, key, second);
        vm.deal(address(handler), 1_000_000 ether);
        momo.transfer(address(handler), 100_000_000 ether);

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = MomentumHandler.swap.selector;
        selectors[1] = MomentumHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice The hook's ERC-6909 claims equal the sum of every pool's accrued fees, per currency.
    function invariant_claimsHeldEqualAccrued() public view {
        (uint256 a0, uint256 a1) = hook.accrued(key.toId());
        (uint256 b0, uint256 b1) = hook.accrued(second.toId());
        assertEq(_claims(key.currency0), a0 + b0, "ETH claims");
        assertEq(_claims(key.currency1), a1 + b1, "MOMO claims");
    }

    /// @notice Every swap paid exactly ceil(unspecified x bps / 10,000), in the unspecified currency only.
    function invariant_everyFeeMatchesTheSchedule() public view {
        assertEq(handler.feeMismatches(), 0);
    }

    /// @notice The hook's streaks and quoted fees agree with an independent model of the rule.
    function invariant_streakMatchesTheModel() public view {
        for (uint256 i = 0; i < 2; i++) {
            PoolId pid = handler.key(i).toId();
            (bool mBuy, uint256 mN) = handler.model(i);
            (bool buy, uint256 n) = hook.streak(pid);
            assertEq(n, mN, "streak length");
            if (mN > 0) assertEq(buy, mBuy, "streak direction");
            uint256 nextBuy = hook.nextFeeBps(pid, true);
            uint256 nextSell = hook.nextFeeBps(pid, false);
            assertGe(nextBuy, 30);
            assertLe(nextBuy, 200);
            assertGe(nextSell, 30);
            assertLe(nextSell, 200);
            assertTrue(nextBuy == 30 || nextSell == 30, "at most one direction is on a streak");
        }
    }

    /// @notice Fees are never pushed: the hook holds no raw ETH or MOMO, only claims.
    function invariant_hookHoldsNoRawBalances() public view {
        assertEq(address(hook).balance, 0);
        assertEq(momo.balanceOf(address(hook)), 0);
    }
}
