// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentumFixture, HookDeployer} from "./utils/MomentumFixture.sol";
import {MomentumFeeHook} from "../src/MomentumFeeHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";

contract MomentumFeeHookTest is MomentumFixture {
    using StateLibrary for IPoolManager;

    uint256 internal constant QUALIFYING = 0.01 ether;
    uint256 internal constant DUST = 0.0009 ether;

    // ------------------------------------------------------------------------------------------------
    // Deployment and permissions
    // ------------------------------------------------------------------------------------------------

    function test_permissions_enableExactlyAfterSwapAndAfterSwapReturnDelta() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterSwap);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.beforeInitialize || p.afterInitialize);
        assertFalse(p.beforeAddLiquidity || p.afterAddLiquidity || p.afterAddLiquidityReturnDelta);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.afterRemoveLiquidityReturnDelta);
        assertFalse(p.beforeSwap || p.beforeSwapReturnDelta);
        assertFalse(p.beforeDonate || p.afterDonate);
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.AFTER_SWAP | HookFlags.AFTER_SWAP_RETURN_DELTA);
    }

    function test_constructor_storesPoolManager() public view {
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_constructor_revertsAtAnAddressWithoutTheFlags() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        require(!HookFlags.matches(predicted, HookFlags.AFTER_SWAP | HookFlags.AFTER_SWAP_RETURN_DELTA));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new MomentumFeeHook(manager);
    }

    function test_constructor_deploysAtAMinedCreate2Salt() public {
        uint160 flags = HookFlags.AFTER_SWAP | HookFlags.AFTER_SWAP_RETURN_DELTA;
        bytes32 initHash = keccak256(abi.encodePacked(type(MomentumFeeHook).creationCode, abi.encode(manager)));
        for (uint256 i = 0; i < 200_000; i++) {
            address predicted = vm.computeCreate2Address(bytes32(i), initHash, address(this));
            if (!HookFlags.matches(predicted, flags)) continue;
            MomentumFeeHook deployed = new MomentumFeeHook{salt: bytes32(i)}(manager);
            assertEq(address(deployed), predicted);
            assertEq(address(deployed.poolManager()), address(manager));
            return;
        }
        fail();
    }

    function test_launchKey_initializesAndSeedsWithTheHookAttached() public view {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(manager.getLiquidity(id), uint128(FULL_RANGE_LIQUIDITY));
    }

    // ------------------------------------------------------------------------------------------------
    // Access control
    // ------------------------------------------------------------------------------------------------

    function test_afterSwap_refusesCallersOtherThanThePoolManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }

    function test_unlockCallback_refusesCallersOtherThanThePoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(key, uint256(1), uint256(1)));
    }

    function test_unlockCallback_refusesThePoolManagerOutsideDonateFees() public {
        vm.prank(address(manager));
        vm.expectRevert(MomentumFeeHook.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(key, uint256(1), uint256(1)));
    }

    function test_undeclaredCallbacks_revertEvenFromThePoolManager() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");
    }

    // ------------------------------------------------------------------------------------------------
    // Fee schedule
    // ------------------------------------------------------------------------------------------------

    function test_buyStreak_rises30To200AndCapsFromThe18th() public {
        for (uint256 i = 0; i < 22; i++) {
            uint256 expected = i < 17 ? 30 + 10 * i : 200;
            assertEq(hook.nextFeeBps(id, true), expected, "next buy fee");
            assertEq(hook.nextFeeBps(id, false), 30, "next sell fee");

            BalanceDelta plain = _swap(twin, true, true, QUALIFYING);
            uint256 fee = _ceilBps(uint256(int256(plain.amount1())), expected);

            vm.expectEmit(true, false, false, true, address(hook));
            emit MomentumFeeHook.Momentum(id, true, i + 1, expected, key.currency1, fee);
            BalanceDelta hooked = _swap(key, true, true, QUALIFYING);

            assertEq(hooked.amount0(), plain.amount0(), "input unchanged");
            assertEq(int256(hooked.amount1()), int256(plain.amount1()) - int256(fee), "fee off output");
        }
        (bool buy, uint256 n) = hook.streak(id);
        assertTrue(buy);
        assertEq(n, 22);
        assertEq(hook.nextFeeBps(id, true), 200);
    }

    function test_the18thBuyIsTheFirstToPay200() public {
        for (uint256 i = 0; i < 16; i++) {
            _swap(key, true, true, QUALIFYING);
        }
        assertEq(hook.nextFeeBps(id, true), 190, "17th buy");
        _swap(key, true, true, QUALIFYING);
        assertEq(hook.nextFeeBps(id, true), 200, "18th buy");
    }

    function test_sellStreak_risesAndChargesInEth() public {
        for (uint256 i = 0; i < 5; i++) {
            uint256 expected = 30 + 10 * i;
            (BalanceDelta hooked, BalanceDelta plain) = _swapBoth(false, true, QUALIFYING);
            uint256 fee = _ceilBps(uint256(int256(plain.amount0())), expected);
            assertEq(int256(hooked.amount0()), int256(plain.amount0()) - int256(fee));
            assertEq(hooked.amount1(), plain.amount1());
        }
        (bool buy, uint256 n) = hook.streak(id);
        assertFalse(buy);
        assertEq(n, 5);
    }

    function test_qualifyingFlip_resetsTheFeeTo30() public {
        for (uint256 i = 0; i < 18; i++) {
            _swapBoth(true, true, QUALIFYING);
        }
        assertEq(hook.nextFeeBps(id, true), 200);
        assertEq(hook.nextFeeBps(id, false), 30);

        (BalanceDelta hooked, BalanceDelta plain) = _swapBoth(false, true, QUALIFYING);
        assertEq(
            int256(hooked.amount0()), int256(plain.amount0()) - int256(_ceilBps(uint256(int256(plain.amount0())), 30))
        );

        (bool buy, uint256 n) = hook.streak(id);
        assertFalse(buy);
        assertEq(n, 1);
        assertEq(hook.nextFeeBps(id, true), 30, "buy streak is gone");
        assertEq(hook.nextFeeBps(id, false), 40, "sell streak started");

        _swapBoth(true, true, QUALIFYING);
        (buy, n) = hook.streak(id);
        assertTrue(buy);
        assertEq(n, 1);
        assertEq(hook.nextFeeBps(id, true), 40);
    }

    function test_dustCounterSwap_paysItsFeeButLeavesTheStreak() public {
        for (uint256 i = 0; i < 5; i++) {
            _swapBoth(true, true, QUALIFYING);
        }
        assertEq(hook.nextFeeBps(id, true), 80);

        // A sell for exactly 0.0009 ETH out: opposite direction, so it pays 30 bps, and it is dust.
        (BalanceDelta hooked, BalanceDelta plain) = _swapBoth(false, false, DUST);
        assertEq(plain.amount0(), int128(int256(DUST)));
        uint256 fee = _ceilBps(_abs(plain.amount1()), 30);
        assertEq(int256(hooked.amount1()), int256(plain.amount1()) - int256(fee), "fee added to input");

        (bool buy, uint256 n) = hook.streak(id);
        assertTrue(buy);
        assertEq(n, 5, "dust cannot reset");
        assertEq(hook.nextFeeBps(id, true), 80);
    }

    function test_dustSameDirectionSwap_paysTheStreakFeeButDoesNotExtendIt() public {
        for (uint256 i = 0; i < 5; i++) {
            _swapBoth(true, true, QUALIFYING);
        }
        (BalanceDelta hooked, BalanceDelta plain) = _swapBoth(true, true, DUST);
        uint256 fee = _ceilBps(uint256(int256(plain.amount1())), 80);
        assertEq(int256(hooked.amount1()), int256(plain.amount1()) - int256(fee));

        (, uint256 n) = hook.streak(id);
        assertEq(n, 5);
    }

    function test_threshold_exactlyOneFinneyQualifies() public {
        _swap(key, true, true, 0.001 ether);
        (bool buy, uint256 n) = hook.streak(id);
        assertTrue(buy);
        assertEq(n, 1);
    }

    function test_threshold_justBelowOneFinneyDoesNot() public {
        _swap(key, true, true, 0.001 ether - 1);
        (, uint256 n) = hook.streak(id);
        assertEq(n, 0);
    }

    function test_exactOutputBuy_addsTheFeeToTheEthInput() public {
        _swapBoth(true, true, QUALIFYING);

        (BalanceDelta hooked, BalanceDelta plain) = _swapBoth(true, false, QUALIFYING);
        uint256 fee = _ceilBps(_abs(plain.amount0()), 40);
        assertEq(hooked.amount1(), plain.amount1(), "exact output delivered");
        assertEq(int256(hooked.amount0()), int256(plain.amount0()) - int256(fee), "fee added to input");
        (uint256 a0,) = hook.accrued(id);
        assertEq(a0, fee);
    }

    function test_exactOutputSell_addsTheFeeToTheMomoInput() public {
        (BalanceDelta hooked, BalanceDelta plain) = _swapBoth(false, false, QUALIFYING);
        uint256 fee = _ceilBps(_abs(plain.amount1()), 30);
        assertEq(hooked.amount0(), plain.amount0());
        assertEq(int256(hooked.amount1()), int256(plain.amount1()) - int256(fee));
        (bool buy, uint256 n) = hook.streak(id);
        assertFalse(buy);
        assertEq(n, 1, "exact output qualifies on the pool's ETH side");
    }

    function test_feeRoundsUp() public {
        // 1 wei of output at 30 bps still costs 1 wei, and the fee never exceeds the output.
        (BalanceDelta hooked, BalanceDelta plain) = _swapBoth(true, false, 1);
        assertEq(plain.amount1(), 1);
        uint256 fee = _ceilBps(_abs(plain.amount0()), 30);
        assertGt(fee, 0);
        assertEq(int256(hooked.amount0()), int256(plain.amount0()) - int256(fee));
    }

    function testFuzz_feeMatchesTheFormula(bool buy, bool exactInput, uint256 amount, uint8 prior) public {
        amount = bound(amount, 1, 5 ether);
        prior = uint8(bound(prior, 0, 25));
        for (uint256 i = 0; i < prior; i++) {
            _swapBoth(buy, true, QUALIFYING);
        }
        uint256 bps = hook.nextFeeBps(id, buy);
        assertEq(bps, prior < 17 ? 30 + 10 * uint256(prior) : 200);
        (uint256 before0, uint256 before1) = hook.accrued(id);

        (BalanceDelta hooked, BalanceDelta plain) = _swapBoth(buy, exactInput, amount);

        bool unspecifiedIs1 = exactInput == buy;
        uint256 base = _abs(unspecifiedIs1 ? plain.amount1() : plain.amount0());
        uint256 fee = _ceilBps(base, bps);
        assertLe(fee, base);
        if (unspecifiedIs1) {
            assertEq(hooked.amount0(), plain.amount0());
            assertEq(int256(hooked.amount1()), int256(plain.amount1()) - int256(fee));
        } else {
            assertEq(hooked.amount1(), plain.amount1());
            assertEq(int256(hooked.amount0()), int256(plain.amount0()) - int256(fee));
        }
        (uint256 after0, uint256 after1) = hook.accrued(id);
        assertEq(after0 - before0, unspecifiedIs1 ? 0 : fee);
        assertEq(after1 - before1, unspecifiedIs1 ? fee : 0);
        assertEq(_claims(key.currency0), after0);
        assertEq(_claims(key.currency1), after1);
    }

    function test_streakIsKeptPerPool() public {
        PoolKey memory other = key;
        other.fee = 500;
        other.tickSpacing = 10;
        _openFullRange(other);

        for (uint256 i = 0; i < 3; i++) {
            _swap(key, true, true, QUALIFYING);
        }
        assertEq(hook.nextFeeBps(id, true), 60);
        assertEq(hook.nextFeeBps(other.toId(), true), 30);
        (, uint256 n) = hook.streak(other.toId());
        assertEq(n, 0);
    }

    function test_feesAreHeldAsClaimsAndNothingIsPushed() public {
        _swap(key, true, true, QUALIFYING);
        _swap(key, false, true, QUALIFYING);
        _swap(key, true, false, QUALIFYING);
        _swap(key, false, false, QUALIFYING);

        (uint256 a0, uint256 a1) = hook.accrued(id);
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(_claims(key.currency0), a0);
        assertEq(_claims(key.currency1), a1);
        assertEq(address(hook).balance, 0, "no ETH pushed");
        assertEq(momo.balanceOf(address(hook)), 0, "no MOMO pushed");
    }

    // ------------------------------------------------------------------------------------------------
    // Donations
    // ------------------------------------------------------------------------------------------------

    function test_donateFees_burnsTheClaimsAndPaysInRangeLps() public {
        _swap(key, true, true, 1 ether);
        _swap(key, false, true, 1 ether);
        (uint256 a0, uint256 a1) = hook.accrued(id);
        (uint256 g0Before, uint256 g1Before) = manager.getFeeGrowthGlobals(id);
        uint128 liquidity = manager.getLiquidity(id);
        uint256 managerEth = address(manager).balance;

        address anyone = makeAddr("anyone");
        vm.expectEmit(true, false, false, true, address(hook));
        emit MomentumFeeHook.FeesDonated(id, a0, a1);
        vm.prank(anyone);
        (uint256 d0, uint256 d1) = hook.donateFees(key);

        assertEq(d0, a0);
        assertEq(d1, a1);
        (uint256 r0, uint256 r1) = hook.accrued(id);
        assertEq(r0, 0);
        assertEq(r1, 0);
        assertEq(_claims(key.currency0), 0);
        assertEq(_claims(key.currency1), 0);

        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(id);
        assertEq(g0 - g0Before, FullMath.mulDiv(a0, FixedPoint128.Q128, liquidity));
        assertEq(g1 - g1Before, FullMath.mulDiv(a1, FixedPoint128.Q128, liquidity));
        assertEq(address(manager).balance, managerEth, "claims became pool fees in place");
    }

    function test_donateFees_revertsWhenNothingAccrued() public {
        vm.expectRevert(MomentumFeeHook.NothingToDonate.selector);
        hook.donateFees(key);
    }

    function test_donateFees_revertsForAKeyNamingAnotherHook() public {
        vm.expectRevert(MomentumFeeHook.WrongHook.selector);
        hook.donateFees(twin);
    }

    function test_donateFees_revertsWhenTheManagerIsAlreadyUnlocked() public {
        _swap(key, true, true, QUALIFYING);
        Reentrant r = new Reentrant(manager, hook, key);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        r.go();
        (, uint256 a1) = hook.accrued(id);
        assertGt(a1, 0, "claims untouched");
    }
}

/// @dev Calls {MomentumFeeHook.donateFees} from inside its own unlock callback.
contract Reentrant {
    IPoolManager internal immutable manager;
    MomentumFeeHook internal immutable hook;
    PoolKey internal key;

    constructor(IPoolManager manager_, MomentumFeeHook hook_, PoolKey memory key_) {
        manager = manager_;
        hook = hook_;
        key = key_;
    }

    function go() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        hook.donateFees(key);
        return "";
    }
}
