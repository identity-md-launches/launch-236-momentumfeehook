// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MomentumFeeHook} from "../../src/MomentumFeeHook.sol";
import {Momentum as MomentumToken} from "../../src/Momentum.sol";
import {HookFlags} from "../../src/HookFlags.sol";

/// @notice Places a MomentumFeeHook at an address carrying its permission bits, without mining.
/// @dev Runs the creation code at the target (so `address(this)` in the constructor is the target and
/// BaseHook's address validation sees the real flags), then installs the returned runtime code there.
library HookDeployer {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function deploy(IPoolManager manager, uint160 prefix) internal returns (MomentumFeeHook hook) {
        address target = address((prefix << 144) | uint160(HookFlags.AFTER_SWAP | HookFlags.AFTER_SWAP_RETURN_DELTA));
        bytes memory init = abi.encodePacked(type(MomentumFeeHook).creationCode, abi.encode(manager));
        VM.etch(target, init);
        (bool ok, bytes memory runtime) = target.call("");
        require(ok, "hook constructor reverted");
        VM.etch(target, runtime);
        hook = MomentumFeeHook(target);
    }
}

/// @notice Shared setup: a real v4-core PoolManager, the v4-core test routers, MOMO, the hook, a
/// native-ETH/MOMO pool using the hook and an otherwise identical twin pool with no hook.
/// @dev Fees go to hook claims, never into the pool, so the same swap sequence leaves both pools in
/// the same state. The twin's deltas are therefore the exact "before fee" amounts for the hooked pool.
abstract contract MomentumFixture is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant LP_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    int128 internal constant FULL_RANGE_LIQUIDITY = 1_000 ether;

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    MomentumToken internal momo;
    MomentumFeeHook internal hook;

    PoolKey internal key;
    PoolId internal id;
    PoolKey internal twin;

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        momo = new MomentumToken();
        hook = HookDeployer.deploy(manager, 0x4444);

        momo.approve(address(swapRouter), type(uint256).max);
        momo.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 100_000 ether);

        key = _key(IHooks(address(hook)));
        id = key.toId();
        twin = _key(IHooks(address(0)));

        _openFullRange(key);
        _openFullRange(twin);
    }

    function _key(IHooks hooks) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(momo)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: hooks
        });
    }

    function _openFullRange(PoolKey memory k) internal {
        manager.initialize(k, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity{value: 1_001 ether}(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: FULL_RANGE_LIQUIDITY,
                salt: 0
            }),
            ""
        );
    }

    /// @dev `amount` > 0 is the size; `exactInput` picks the sign v4 expects (negative = exact input).
    function _swap(PoolKey memory k, bool buy, bool exactInput, uint256 amount) internal returns (BalanceDelta) {
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        // A buy pays ETH: exact input needs exactly `amount`; exact output gets headroom, refunded.
        uint256 value = buy ? (exactInput ? amount : amount * 2 + 1 ether) : 0;
        return swapRouter.swap{value: value}(
            k,
            SwapParams({
                zeroForOne: buy,
                amountSpecified: specified,
                sqrtPriceLimitX96: buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Swaps on the twin first, then on the hooked pool; returns (hooked, twin) deltas.
    function _swapBoth(bool buy, bool exactInput, uint256 amount)
        internal
        returns (BalanceDelta hooked, BalanceDelta plain)
    {
        plain = _swap(twin, buy, exactInput, amount);
        hooked = _swap(key, buy, exactInput, amount);
    }

    function _ceilBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps + 9_999) / 10_000;
    }

    function _abs(int128 x) internal pure returns (uint256) {
        // casting to 'uint256' is safe because the operand is widened from int128 and is non-negative
        // forge-lint: disable-next-line(unsafe-typecast)
        return x < 0 ? uint256(-int256(x)) : uint256(int256(x));
    }

    function _claims(Currency c) internal view returns (uint256) {
        return manager.balanceOf(address(hook), c.toId());
    }

    receive() external payable {}
}
