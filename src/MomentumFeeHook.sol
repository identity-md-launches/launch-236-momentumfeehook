// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

/// @title MomentumFeeHook
/// @notice A Uniswap v4 hook that charges a fee which grows while swaps keep going the same way.
/// @dev Per pool: `lastDirection` and a streak `n` of qualifying swaps in a row in that direction
/// (n = 0 before the first). A swap in direction d pays min(30 + 10 * n, 200) bps if d == lastDirection,
/// else 30 bps. A swap qualifies when the currency0 (native ETH) side of its pool delta is at least
/// 0.001 ETH; after a qualifying swap n += 1 if d == lastDirection, else lastDirection = d and n = 1.
/// Non-qualifying swaps pay the fee for their direction but never touch the streak.
///
/// The fee is taken on the unspecified currency through the afterSwap return delta and credited to the
/// hook as ERC-6909 claims with `poolManager.mint`. Nothing is pushed during a swap. Anyone may call
/// {donateFees} to burn a pool's claims and donate them to its in-range LPs.
///
/// No owner, no admin, no upgrade path. State is keyed by PoolId, so any pool may attach this hook.
contract MomentumFeeHook is BaseHook, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    /// @notice Fee charged on a swap that does not extend a streak, in basis points.
    uint256 public constant BASE_FEE_BPS = 30;
    /// @notice Fee added per qualifying swap already in the streak, in basis points.
    uint256 public constant STEP_BPS = 10;
    /// @notice Maximum fee, in basis points. Reached from the 18th same-direction swap.
    uint256 public constant MAX_FEE_BPS = 200;
    /// @notice Minimum currency0 (ETH) side of a swap's pool delta for it to move the streak.
    uint256 public constant MIN_QUALIFYING_AMOUNT = 0.001 ether;
    uint256 internal constant BPS = 10_000;

    /// @dev Transient-storage slot set only while this contract's own {donateFees} holds the lock.
    bytes32 internal constant DONATING_SLOT = keccak256("MomentumFeeHook.donating");

    struct Streak {
        bool buy;
        uint248 n;
    }

    struct Accrued {
        uint256 amount0;
        uint256 amount1;
    }

    mapping(PoolId => Streak) internal _streaks;
    mapping(PoolId => Accrued) internal _accrued;

    /// @notice Emitted on every swap through a pool using this hook.
    /// @param poolId The pool.
    /// @param buy True for zeroForOne (ETH in, MOMO out on the launch pool).
    /// @param streak The pool's streak length after this swap was applied.
    /// @param feeBps The fee rate this swap paid.
    /// @param currency The currency the fee was taken in (the swap's unspecified currency).
    /// @param fee The fee amount credited to the hook.
    event Momentum(PoolId indexed poolId, bool buy, uint256 streak, uint256 feeBps, Currency currency, uint256 fee);

    /// @notice Emitted when a pool's accrued fees are donated to its in-range LPs.
    event FeesDonated(PoolId indexed poolId, uint256 amount0, uint256 amount1);

    /// @notice The pool has no in-range liquidity to donate to; the claims stay accrued.
    error NoLiquidity();
    /// @notice The pool has no accrued fees.
    error NothingToDonate();
    /// @notice The key does not name this hook.
    error WrongHook();
    /// @notice The unlock callback was not started by this contract's {donateFees}.
    error UnexpectedUnlock();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------

    /// @notice The fee, in bps, the next swap in direction `buy` would pay on `poolId`.
    function nextFeeBps(PoolId poolId, bool buy) external view returns (uint256) {
        return _feeBps(_streaks[poolId], buy);
    }

    /// @notice The pool's current streak direction and length. (false, 0) before the first qualifying swap.
    function streak(PoolId poolId) external view returns (bool buy, uint256 n) {
        Streak memory s = _streaks[poolId];
        return (s.buy, s.n);
    }

    /// @notice Fees accrued for `poolId` and not yet donated, in currency0 and currency1.
    function accrued(PoolId poolId) external view returns (uint256 amount0, uint256 amount1) {
        Accrued memory a = _accrued[poolId];
        return (a.amount0, a.amount1);
    }

    // ------------------------------------------------------------------------------------------------
    // Hook callback
    // ------------------------------------------------------------------------------------------------

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        bool buy = params.zeroForOne;

        // Read the rate before the streak moves: this swap pays for the streak it found.
        uint256 feeBps = _feeBps(_streaks[id], buy);
        uint256 n = _updateStreak(id, buy, delta);

        // The unspecified currency is currency1 when the specified one is currency0, which happens for
        // exact-input zeroForOne and exact-output oneForZero.
        bool unspecifiedIs1 = (params.amountSpecified < 0) == buy;
        uint256 unspecifiedAmount = _abs(unspecifiedIs1 ? delta.amount1() : delta.amount0());
        uint256 fee = (unspecifiedAmount * feeBps + BPS - 1) / BPS;
        if (fee > unspecifiedAmount) fee = unspecifiedAmount;

        Currency feeCurrency = unspecifiedIs1 ? key.currency1 : key.currency0;
        if (fee > 0) {
            if (unspecifiedIs1) _accrued[id].amount1 += fee;
            else _accrued[id].amount0 += fee;
            poolManager.mint(address(this), feeCurrency.toId(), fee);
        }

        emit Momentum(id, buy, n, feeBps, feeCurrency, fee);
        return (this.afterSwap.selector, fee.toInt128());
    }

    /// @dev Applies the streak rule for a swap in direction `buy` and returns the resulting length.
    /// Only swaps whose currency0 side is at least {MIN_QUALIFYING_AMOUNT} move the streak.
    function _updateStreak(PoolId id, bool buy, BalanceDelta delta) internal returns (uint256) {
        Streak memory s = _streaks[id];
        if (_abs(delta.amount0()) < MIN_QUALIFYING_AMOUNT) return s.n;
        if (s.buy == buy) {
            s.n += 1;
        } else {
            s.buy = buy;
            s.n = 1;
        }
        _streaks[id] = s;
        return s.n;
    }

    // ------------------------------------------------------------------------------------------------
    // Fee donation
    // ------------------------------------------------------------------------------------------------

    /// @notice Burns `key`'s accrued claims and donates them to the pool's in-range LPs. Callable by anyone.
    /// @dev Reverts {NoLiquidity} while in-range liquidity is zero; the claims wait for a later call.
    function donateFees(PoolKey calldata key) external returns (uint256 amount0, uint256 amount1) {
        if (address(key.hooks) != address(this)) revert WrongHook();
        PoolId id = key.toId();
        Accrued memory a = _accrued[id];
        if (a.amount0 == 0 && a.amount1 == 0) revert NothingToDonate();
        if (poolManager.getLiquidity(id) == 0) revert NoLiquidity();

        delete _accrued[id];
        _setDonating(true);
        poolManager.unlock(abi.encode(key, a.amount0, a.amount1));
        _setDonating(false);

        emit FeesDonated(id, a.amount0, a.amount1);
        return (a.amount0, a.amount1);
    }

    /// @notice PoolManager callback for {donateFees}. Accepts only the PoolManager, and only while this
    /// contract's own {donateFees} holds the lock.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_donating()) revert UnexpectedUnlock();
        (PoolKey memory key, uint256 amount0, uint256 amount1) = abi.decode(data, (PoolKey, uint256, uint256));

        // Burning claims credits the hook; donating debits it by the same amounts, so deltas net to zero.
        if (amount0 > 0) poolManager.burn(address(this), key.currency0.toId(), amount0);
        if (amount1 > 0) poolManager.burn(address(this), key.currency1.toId(), amount1);
        poolManager.donate(key, amount0, amount1, "");
        return "";
    }

    // ------------------------------------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------------------------------------

    function _feeBps(Streak memory s, bool buy) internal pure returns (uint256) {
        if (s.buy != buy) return BASE_FEE_BPS;
        uint256 n = s.n;
        // 30 + 10 * n reaches 200 at n = 17; checking first keeps the multiplication bounded.
        if (n >= (MAX_FEE_BPS - BASE_FEE_BPS) / STEP_BPS) return MAX_FEE_BPS;
        return BASE_FEE_BPS + STEP_BPS * n;
    }

    function _abs(int128 x) internal pure returns (uint256) {
        // casting to 'uint256' is safe because the operand is widened from int128 and is non-negative
        // forge-lint: disable-next-line(unsafe-typecast)
        return x < 0 ? uint256(-int256(x)) : uint256(int256(x));
    }

    function _donating() internal view returns (bool flag) {
        bytes32 slot = DONATING_SLOT;
        assembly ("memory-safe") {
            flag := tload(slot)
        }
    }

    function _setDonating(bool flag) internal {
        bytes32 slot = DONATING_SLOT;
        assembly ("memory-safe") {
            tstore(slot, flag)
        }
    }
}
