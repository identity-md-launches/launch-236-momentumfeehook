// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {MomentumFixture} from "./utils/MomentumFixture.sol";
import {MomentumFeeHook} from "../src/MomentumFeeHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

/// @notice Fuzzes sequences of swaps (direction, exact input/output, sizes clustered around the
/// 0.001 ETH threshold) through the hooked pool and its hook-less twin, and checks every single swap
/// against an independent model of the fee schedule and the streak rule, against the tokens that
/// actually moved, and against the PoolManager's transient delta accounting.
contract MomentumFeeHookSequenceTest is MomentumFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 internal constant THRESHOLD = 0.001 ether;
    uint256 internal constant MIN_BPS = 30;
    uint256 internal constant MAX_BPS = 200;

    /// @dev Independent model of the pool's streak. Starts as the hook does: (false, 0).
    bool internal mBuy;
    uint256 internal mN;

    uint256 internal qualifyingSteps;
    uint256 internal dustSteps;

    struct Snap {
        uint256 eth;
        uint256 momo;
        uint256 managerEth;
        uint256 managerMomo;
        uint256 claims0;
        uint256 claims1;
        uint256 accrued0;
        uint256 accrued1;
    }

    // ------------------------------------------------------------------------------------------------
    // Model
    // ------------------------------------------------------------------------------------------------

    function _modelBps(bool buy) internal view returns (uint256) {
        if (buy != mBuy) return MIN_BPS;
        return mN >= 17 ? MAX_BPS : MIN_BPS + 10 * mN;
    }

    function _modelApply(bool buy, uint256 eth) internal {
        if (eth < THRESHOLD) return;
        if (buy == mBuy) {
            mN += 1;
        } else {
            mBuy = buy;
            mN = 1;
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Step decoding
    // ------------------------------------------------------------------------------------------------

    /// @dev Sizes cluster around the threshold. When the ETH side is not the specified side (exact-input
    /// sells, exact-output buys) the band modes still land its computed ETH side on both sides of it.
    function _size(uint256 e) internal pure returns (uint256) {
        uint256 mode = (e >> 2) % 5;
        uint256 r = e >> 8;
        if (mode == 0) return _bound(r, 1, THRESHOLD - 1); // dust
        if (mode == 1) return THRESHOLD - 3 + (r % 7); // threshold -3 .. +3 wei
        if (mode == 2) return _bound(r, 0.00094 ether, 0.00106 ether); // tight band around it
        if (mode == 3) return _bound(r, THRESHOLD, 2 ether); // clearly qualifying
        return _bound(r, 1, 1_000); // a few wei
    }

    // ------------------------------------------------------------------------------------------------
    // One checked step
    // ------------------------------------------------------------------------------------------------

    function _snap() internal view returns (Snap memory s) {
        s.eth = address(this).balance;
        s.momo = momo.balanceOf(address(this));
        s.managerEth = address(manager).balance;
        s.managerMomo = momo.balanceOf(address(manager));
        s.claims0 = _claims(key.currency0);
        s.claims1 = _claims(key.currency1);
        (s.accrued0, s.accrued1) = hook.accrued(id);
    }

    function _step(bool buy, bool exactInput, uint256 amount) internal returns (uint256) {
        return _stepWithLimit(buy, exactInput, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    /// @dev Performs one swap on the twin and the hooked pool and checks everything about it.
    /// Returns the pool's own (pre-hook-fee) ETH side, taken from the hook-less twin.
    function _stepWithLimit(bool buy, bool exactInput, uint256 amount, uint160 limit) internal returns (uint256 eth) {
        // The rate this swap must pay, from the model; the hook's quote must agree before the swap.
        uint256 bps = _modelBps(buy);
        assertEq(hook.nextFeeBps(id, buy), bps, "quoted rate differs from the schedule");
        assertGe(bps, MIN_BPS, "rate below 30 bps");
        assertLe(bps, MAX_BPS, "rate above 200 bps");

        Measured memory m = _measure(buy, exactInput, amount, limit);

        // Fee: only on the unspecified currency, ceil(|unspecified| x bps / 10,000), capped at it.
        bool unspecifiedIs1 = exactInput == buy;
        uint256 base = _abs(unspecifiedIs1 ? m.plain.amount1() : m.plain.amount0());
        uint256 fee = _ceilBps(base, bps);
        if (fee > base) fee = base;
        _checkFee(unspecifiedIs1, fee, base, m.plain, m.hooked, m.b, m.a);
        _checkSettled(m.hooked, m.b, m.a);
        uint256 eStreak = _checkEvent(m.logs, buy, bps, unspecifiedIs1 ? key.currency1 : key.currency0, fee);

        eth = _abs(m.plain.amount0());
        _checkStreak(buy, eth, eStreak);
    }

    struct Measured {
        BalanceDelta plain;
        BalanceDelta hooked;
        Snap b;
        Snap a;
        Vm.Log[] logs;
    }

    function _measure(bool buy, bool exactInput, uint256 amount, uint160 limit) internal returns (Measured memory m) {
        m.plain = _swapLimited(twin, buy, exactInput, amount, limit);
        m.b = _snap();
        vm.recordLogs();
        m.hooked = _swapLimited(key, buy, exactInput, amount, limit);
        m.logs = vm.getRecordedLogs();
        m.a = _snap();
    }

    /// @dev Streak: moves only when the pool's ETH side reached the threshold.
    function _checkStreak(bool buy, uint256 eth, uint256 eStreak) internal {
        bool buyBefore = mBuy;
        uint256 nBefore = mN;
        _modelApply(buy, eth);
        (bool sBuy, uint256 sN) = hook.streak(id);
        if (eth < THRESHOLD) {
            dustSteps++;
            assertEq(sN, nBefore, "sub-threshold swap changed the streak length");
            assertEq(sBuy, buyBefore, "sub-threshold swap changed the streak direction");
        } else {
            qualifyingSteps++;
        }
        assertEq(eStreak, mN, "event streak differs from the model");
        assertEq(sN, mN, "streak length differs from the model");
        assertEq(sBuy, mBuy, "streak direction differs from the model");

        // Fees never enter the pool, so the hooked pool tracks its twin exactly.
        (uint160 pHooked,,,) = manager.getSlot0(id);
        (uint160 pTwin,,,) = manager.getSlot0(twin.toId());
        assertEq(pHooked, pTwin, "hook moved the pool price");
    }

    function _assertStreak(bool buy, uint256 n) internal view {
        (bool sBuy, uint256 sN) = hook.streak(id);
        assertEq(sN, n, "streak length");
        assertEq(sBuy, buy, "streak direction");
    }

    /// @dev A run of qualifying swaps in one direction, each checked.
    function _run(bool buy, uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            _step(buy, true, 0.01 ether);
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Fuzzed sequences
    // ------------------------------------------------------------------------------------------------

    /// @notice Arbitrary directions, modes and threshold-clustered sizes: every swap pays the schedule,
    /// settles, and only qualifying swaps move the streak.
    function testFuzz_randomSequence(uint256[16] memory steps, uint8 len) public {
        len = uint8(_bound(len, 1, 16));
        for (uint256 i = 0; i < len; i++) {
            uint256 e = steps[i];
            _step(e & 1 == 1, e & 2 == 2, _size(e));
        }
        assertEq(qualifyingSteps + dustSteps, len);
    }

    /// @notice Long, mostly one-directional sequences so streaks reach and pass the 200 bps cap, with
    /// dust, threshold-edge swaps and exact output interleaved.
    function testFuzz_streakySequence(uint256 seed, uint8 len) public {
        len = uint8(_bound(len, 18, 40));
        bool buy = seed & 1 == 1;
        for (uint256 i = 0; i < len; i++) {
            uint256 e = uint256(keccak256(abi.encode(seed, i)));
            if (e % 10 == 0) buy = !buy;
            uint256 amount = (e >> 128) % 3 == 0 ? _size(e) : _bound(e >> 16, 0.002 ether, 0.05 ether);
            _step(buy, (e >> 1) & 1 == 1, amount);
        }
        if (mN >= 17) assertEq(hook.nextFeeBps(id, mBuy), MAX_BPS, "cap not in force from the 18th");
        assertEq(hook.nextFeeBps(id, !mBuy), MIN_BPS, "counter-direction not at base rate");
    }

    /// @notice Whatever streak is standing, no run of sub-threshold swaps, in either direction and
    /// either mode, changes it -- they pay their direction's rate and leave it alone.
    function testFuzz_dustNeverChangesTheStreak(bool priorBuy, uint8 prior, uint256[12] memory dust) public {
        prior = uint8(_bound(prior, 0, 22));
        _run(priorBuy, prior);
        (bool buy0, uint256 n0) = hook.streak(id);
        uint256 nextBuy = hook.nextFeeBps(id, true);
        uint256 nextSell = hook.nextFeeBps(id, false);

        for (uint256 i = 0; i < dust.length; i++) {
            uint256 e = dust[i];
            // ETH side specified (exact-in buy, exact-out sell): any size below 0.001 ETH.
            // ETH side computed (exact-in sell, exact-out buy): MOMO size small enough to stay below it.
            bool buy = e & 1 == 1;
            bool exactInput = e & 2 == 2;
            bool ethSpecified = buy == exactInput;
            uint256 amount = _bound(e >> 2, 1, ethSpecified ? THRESHOLD - 1 : 0.00095 ether);
            uint256 eth = _step(buy, exactInput, amount);
            assertLt(eth, THRESHOLD, "fixture produced a qualifying swap");
        }
        _assertStreak(buy0, n0);
        assertEq(hook.nextFeeBps(id, true), nextBuy);
        assertEq(hook.nextFeeBps(id, false), nextSell);
        assertEq(dustSteps, dust.length);
    }

    /// @notice Where the ETH side is the specified amount, the threshold is exact to the wei: a
    /// counter-swap of 0.001 ETH flips the streak, one wei less leaves it.
    function testFuzz_thresholdEdge_ethSpecified(bool buyExactIn, uint8 prior, int256 offset) public {
        prior = uint8(_bound(prior, 1, 20));
        offset = _bound(offset, -2_000, 2_000);
        // Opposite streak first, so a qualifying swap is a visible flip.
        bool buy = buyExactIn;
        _run(!buy, prior);
        uint256 amount = uint256(int256(THRESHOLD) + offset);

        uint256 eth = _step(buy, buyExactIn, amount);
        assertEq(eth, amount, "specified ETH side must be filled exactly");
        if (amount >= THRESHOLD) _assertStreak(buy, 1);
        else _assertStreak(!buy, prior);
    }

    /// @notice Where the ETH side is computed by the pool (exact-in sells, exact-out buys), the pool's
    /// own ETH amount decides, both sides of the threshold.
    function testFuzz_thresholdEdge_ethComputed(bool sell, uint8 prior, uint256 amount) public {
        prior = uint8(_bound(prior, 1, 20));
        amount = _bound(amount, 0.00096 ether, 0.00104 ether);
        bool buy = !sell;
        _run(!buy, prior);

        // exact-input sell or exact-output buy: the MOMO side is specified.
        uint256 eth = _step(buy, sell, amount);
        if (eth >= THRESHOLD) _assertStreak(buy, 1);
        else _assertStreak(!buy, prior);
    }

    /// @notice Every rate in the schedule, both directions, both modes, with a sub-threshold swap
    /// replayed at each streak length: none of them is outside [30, 200] and none moves the streak.
    function testFuzz_scheduleWithDustAtEveryLength(bool buy, bool exactInput, uint256 dustSeed) public {
        for (uint256 i = 0; i < 20; i++) {
            bool ethSpecified = buy == exactInput;
            uint256 d =
                _bound(uint256(keccak256(abi.encode(dustSeed, i))), 1, ethSpecified ? THRESHOLD - 1 : 0.0009 ether);
            _step(buy, exactInput, d);
            _step(!buy, !exactInput, d);
            _step(buy, exactInput, ethSpecified ? THRESHOLD : 0.002 ether);
            assertEq(mN, i + 1);
        }
        assertEq(hook.nextFeeBps(id, buy), MAX_BPS);
        assertEq(hook.nextFeeBps(id, !buy), MIN_BPS);
    }

    // ------------------------------------------------------------------------------------------------
    // Partial fills: the pool delta, not the requested amount, decides
    // ------------------------------------------------------------------------------------------------

    function test_partialFillBuy_requestAboveThresholdButPoolEthBelow_leavesStreak() public {
        _run(false, 4);
        (uint160 p,,,) = manager.getSlot0(id);
        // A limit a hair below the price stops a 1 ETH exact-input buy after a sliver of ETH.
        uint256 eth = _stepWithLimit(true, true, 1 ether, p - p / 8_000_000);
        assertGt(eth, 0);
        assertLt(eth, THRESHOLD, "limit too loose for this test");
        _assertStreak(false, 4);
    }

    function test_partialFillSell_exactOutputAboveThresholdButPoolEthBelow_leavesStreak() public {
        _run(true, 6);
        (uint160 p,,,) = manager.getSlot0(id);
        uint256 eth = _stepWithLimit(false, false, 1 ether, p + p / 8_000_000);
        assertGt(eth, 0);
        assertLt(eth, THRESHOLD, "limit too loose for this test");
        _assertStreak(true, 6);
    }

    function test_partialFill_poolEthAboveThreshold_stillQualifies() public {
        _run(false, 3);
        (uint160 p,,,) = manager.getSlot0(id);
        uint256 eth = _stepWithLimit(true, true, 1 ether, p - p / 200_000);
        assertGe(eth, THRESHOLD);
        assertLt(eth, 1 ether, "not a partial fill");
        _assertStreak(true, 1);
    }

    // ------------------------------------------------------------------------------------------------
    // Failure paths: a swap that reverts leaves no trace
    // ------------------------------------------------------------------------------------------------

    function _assertUntouched(bool buy, uint256 n, uint256 a0, uint256 a1) internal view {
        _assertStreak(buy, n);
        (uint256 r0, uint256 r1) = hook.accrued(id);
        assertEq(r0, a0, "accrued0 moved");
        assertEq(r1, a1, "accrued1 moved");
        assertEq(_claims(key.currency0), a0, "claims0 moved");
        assertEq(_claims(key.currency1), a1, "claims1 moved");
    }

    function testFuzz_zeroAmountSwapReverts(bool buy, uint8 prior) public {
        prior = uint8(_bound(prior, 0, 20));
        _run(buy, prior);
        (uint256 a0, uint256 a1) = hook.accrued(id);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        swapRouter.swap(
            key,
            SwapParams(buy, 0, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        // Before the first qualifying swap the streak is (false, 0).
        _assertUntouched(prior == 0 ? false : buy, prior, a0, a1);
    }

    /// @notice A qualifying counter-swap whose settlement fails (buy without the ETH to pay for it)
    /// reverts entirely: the streak it would have reset, and the fee it would have paid, are untouched.
    function testFuzz_unpaidQualifyingSwapRevertsAndLeavesTheStreak(uint8 prior, bool exactInput, uint256 amount)
        public
    {
        prior = uint8(_bound(prior, 1, 20));
        amount = _bound(amount, 0.01 ether, 1 ether);
        _run(false, prior);
        (uint256 a0, uint256 a1) = hook.accrued(id);

        vm.expectRevert();
        swapRouter.swap{value: exactInput ? amount - 1 : 0}(
            key,
            SwapParams(true, exactInput ? -int256(amount) : int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        _assertUntouched(false, prior, a0, a1);
        assertEq(hook.nextFeeBps(id, false), prior >= 17 ? MAX_BPS : MIN_BPS + 10 * prior);
    }

    function testFuzz_priceLimitOnTheWrongSideReverts(bool buy, uint8 prior) public {
        prior = uint8(_bound(prior, 1, 20));
        _run(!buy, prior);
        (uint256 a0, uint256 a1) = hook.accrued(id);
        (uint160 p,,,) = manager.getSlot0(id);
        uint160 limit = buy ? p + 1 : p - 1;

        vm.expectRevert(abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, p, limit));
        _swapLimited(key, buy, true, 1 ether, limit);
        _assertUntouched(!buy, prior, a0, a1);
    }

    /// @notice A limit equal to the current price fills nothing: no ETH moves, so nothing qualifies,
    /// and there is no unspecified amount to charge.
    function testFuzz_limitAtThePriceFillsNothingAndChargesNothing(bool buy, bool exactInput) public {
        _run(!buy, 5);
        (uint160 p,,,) = manager.getSlot0(id);
        (uint256 a0, uint256 a1) = hook.accrued(id);
        // v4 rejects a limit equal to the price on the swap's side with PriceLimitAlreadyExceeded.
        vm.expectRevert(abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, p, p));
        _swapLimited(key, buy, exactInput, 1 ether, p);
        _assertUntouched(!buy, 5, a0, a1);
    }

    function _checkFee(
        bool unspecifiedIs1,
        uint256 fee,
        uint256 base,
        BalanceDelta plain,
        BalanceDelta hooked,
        Snap memory b,
        Snap memory a
    ) internal pure {
        // Rate bounds on the amount actually charged (ceil rounding allows at most one wei over).
        assertGe(fee * 10_000, base * MIN_BPS, "paid less than 30 bps");
        assertLe(fee, _ceilBps(base, MAX_BPS), "paid more than 200 bps");

        uint256 claimed0 = a.claims0 - b.claims0;
        uint256 claimed1 = a.claims1 - b.claims1;
        assertEq(unspecifiedIs1 ? claimed1 : claimed0, fee, "fee credited to the hook");
        assertEq(unspecifiedIs1 ? claimed0 : claimed1, 0, "fee taken on the specified currency");
        assertEq(a.accrued0 - b.accrued0, claimed0, "accrued0 differs from claims minted");
        assertEq(a.accrued1 - b.accrued1, claimed1, "accrued1 differs from claims minted");
        assertEq(a.claims0, a.accrued0, "claims0 != accrued0");
        assertEq(a.claims1, a.accrued1, "claims1 != accrued1");

        // The specified side is untouched; the unspecified side is worse for the swapper by the fee.
        if (unspecifiedIs1) {
            assertEq(hooked.amount0(), plain.amount0(), "specified ETH side changed");
            assertEq(int256(hooked.amount1()), int256(plain.amount1()) - int256(fee), "MOMO side not net of fee");
        } else {
            assertEq(hooked.amount1(), plain.amount1(), "specified MOMO side changed");
            assertEq(int256(hooked.amount0()), int256(plain.amount0()) - int256(fee), "ETH side not net of fee");
        }
    }

    function _checkSettled(BalanceDelta hooked, Snap memory b, Snap memory a) internal view {
        // What the router reported is exactly what the swapper's balances did.
        assertEq(int256(a.eth) - int256(b.eth), int256(hooked.amount0()), "swapper ETH != reported delta");
        assertEq(int256(a.momo) - int256(b.momo), int256(hooked.amount1()), "swapper MOMO != reported delta");
        // The PoolManager holds the counterpart (pool reserves plus the hook's claims).
        assertEq(int256(a.managerEth) - int256(b.managerEth), -int256(hooked.amount0()), "manager ETH");
        assertEq(int256(a.managerMomo) - int256(b.managerMomo), -int256(hooked.amount1()), "manager MOMO");
        // Every transient delta was closed out.
        assertEq(manager.getNonzeroDeltaCount(), 0, "open deltas after the swap");
        assertFalse(manager.isUnlocked(), "manager left unlocked");
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0, "hook ETH delta open");
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0, "hook MOMO delta open");
        assertEq(manager.currencyDelta(address(swapRouter), key.currency0), 0, "router ETH delta open");
        assertEq(manager.currencyDelta(address(swapRouter), key.currency1), 0, "router MOMO delta open");
        // Nothing was pushed to the hook.
        assertEq(address(hook).balance, 0, "raw ETH pushed to the hook");
        assertEq(momo.balanceOf(address(hook)), 0, "raw MOMO pushed to the hook");
    }

    /// @dev Checks the single Momentum event of the swap and returns the streak it reported.
    function _checkEvent(Vm.Log[] memory logs, bool buy, uint256 bps, Currency feeCurrency, uint256 fee)
        internal
        view
        returns (uint256 eStreak)
    {
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != MomentumFeeHook.Momentum.selector) continue;
            seen++;
            assertEq(logs[i].topics[1], PoolId.unwrap(id), "event pool");
            bool eBuy;
            uint256 eBps;
            Currency eCurrency;
            uint256 eFee;
            (eBuy, eStreak, eBps, eCurrency, eFee) =
                abi.decode(logs[i].data, (bool, uint256, uint256, Currency, uint256));
            assertEq(eBuy, buy, "event direction");
            assertEq(eBps, bps, "event rate");
            assertGe(eBps, MIN_BPS, "event rate below 30");
            assertLe(eBps, MAX_BPS, "event rate above 200");
            assertEq(Currency.unwrap(eCurrency), Currency.unwrap(feeCurrency), "event currency");
            assertEq(eFee, fee, "event fee");
        }
        assertEq(seen, 1, "exactly one Momentum event per swap");
    }

    function _swapLimited(PoolKey memory k, bool buy, bool exactInput, uint256 amount, uint160 limit)
        internal
        returns (BalanceDelta)
    {
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        uint256 value = buy ? (exactInput ? amount : amount * 2 + 1 ether) : 0;
        return swapRouter.swap{value: value}(
            k,
            SwapParams({zeroForOne: buy, amountSpecified: specified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
