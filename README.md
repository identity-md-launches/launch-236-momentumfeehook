# Momentum (MOMO) + MomentumFeeHook

This is a Uniswap v4 hook launch for Sepolia (chain 11155111). It has two parts:

- **`Momentum`** (`src/Momentum.sol`) is the launch token: an ERC-20 named Momentum, symbol MOMO, 18 decimals. Its fixed supply of 1,000,000,000 MOMO is minted once to `msg.sender` (the factory). The constructor takes no arguments. There is no mint function, no owner and no admin.
- **`MomentumFeeHook`** (`src/MomentumFeeHook.sol`) is a v4 hook on the token's native-ETH pool. While swaps keep going the same way, its fee grows. Fees are held as ERC-6909 claims, and anyone can donate them to in-range LPs.
- **`HookFlags`** (`src/HookFlags.sol`) is a pure helper library for the permission bits in a hook address.

The hook has no owner, no admin, no upgrade path, no proxy, no `delegatecall` and no `selfdestruct`. It uses no oracle and no randomness.

## The fee rule

Each pool keeps its own state, keyed by `PoolId`:

- `lastDirection`: buy or sell.
- `n`: the number of qualifying swaps in a row in `lastDirection`. It is 0 before the first qualifying swap.

A *buy* is `zeroForOne`: ETH in, MOMO out on the launch pool. A *sell* is the reverse. In v4, `amountSpecified < 0` means exact input.

| Case | Fee paid by this swap |
|---|---|
| direction == `lastDirection` | `min(30 + 10·n, 200)` bps |
| direction != `lastDirection` | 30 bps |

A swap **qualifies** when the ETH side of its pool delta is at least **0.001 ETH**. The ETH side is `|delta.amount0()|`, measured before the hook's fee. A qualifying swap then updates the streak:

- same direction: `n += 1`
- opposite direction: `lastDirection = d`, `n = 1`

Swaps below 0.001 ETH pay the fee for their direction but never change the streak, so dust cannot reset it. Each swap reads the streak and updates it inside the same `afterSwap`. The rate is read first, so a swap pays for the streak it found.

The resulting schedule:

- The first buy pays 0.30%, the second 0.40%, and so on.
- The 17th buy pays 1.90%. The 18th and every later buy pay 2.00%.
- The first qualifying sell after that pays 0.30% and starts a sell streak.

**Where the fee is taken:** on the swap's *unspecified* currency, through the `afterSwapReturnDelta`.
- Exact input: the fee comes off the output.
- Exact output: the fee is added to the input.

`fee = ceil(|unspecified| × bps / 10_000)`, capped at `|unspecified|`. The fee is credited to the hook with `poolManager.mint` inside the callback. No ETH or tokens move to or from the hook during a swap.

### Resetting a streak has a price

To reset a streak, someone has to make a qualifying **counter-swap**: at least 0.001 ETH in the opposite direction. In practice that costs **two hook fees plus LP fees**:

1. The counter-swap pays 30 bps to the hook plus the pool's 0.30% LP fee.
2. Unwinding the counter-position (swapping back in the original direction) pays at least another 30 bps hook fee plus LP fee again.

A trader facing a 2% buy fee can therefore make the next buy cost 0.30%. The reset only pays off when the saving is larger than that round trip. This is intended. The streak is a price signal, not a lock.

## Interface

| Function / event | Notes |
|---|---|
| `constructor(IPoolManager poolManager)` | The only argument. On Sepolia: `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`. |
| `getHookPermissions()` | Enables exactly `afterSwap` and `afterSwapReturnDelta`; every other permission is false. |
| `nextFeeBps(PoolId, bool buy) → uint256` | The fee the next swap in that direction would pay. |
| `streak(PoolId) → (bool buy, uint256 n)` | Returns `(false, 0)` before the first qualifying swap. |
| `accrued(PoolId) → (uint256 amount0, uint256 amount1)` | Claims accrued for that pool and not yet donated. |
| `donateFees(PoolKey) → (uint256 amount0, uint256 amount1)` | Permissionless. Unlocks the PoolManager, burns the pool's claims in both currencies and calls `poolManager.donate` with them. |
| `unlockCallback(bytes)` | Accepts only the PoolManager, and only during a `donateFees` call the hook itself started (transient-storage flag). |
| `event Momentum(PoolId indexed poolId, bool buy, uint256 streak, uint256 feeBps, Currency currency, uint256 fee)` | Emitted on every swap. `streak` is the length *after* this swap was applied. `feeBps` is the rate this swap paid. `currency` is the currency the fee was taken in. |
| `event FeesDonated(PoolId indexed poolId, uint256 amount0, uint256 amount1)` | Emitted on each successful donation. |

`donateFees` can revert in these cases:

| Error | When |
|---|---|
| `NoLiquidity()` | The pool has zero in-range liquidity. The claims stay accrued for a later call. |
| `NothingToDonate()` | Both accrued amounts are zero. Added so there are no empty `FeesDonated` events. |
| `WrongHook()` | The key names a different hook. |
| `AlreadyUnlocked()` | Called while the PoolManager is already unlocked. This one comes from v4-core. |

The full ABIs are exported at `docs/abi/Momentum.json` and `docs/abi/MomentumFeeHook.json`.

## Deployment parameters

| Item | Value |
|---|---|
| Chain | Sepolia, 11155111 |
| Token | `Momentum`, no constructor arguments, 1,000,000,000 × 10^18 minted to the deployer |
| Hook | `MomentumFeeHook(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543)` |
| Hook address flags | `AFTER_SWAP \| AFTER_SWAP_RETURN_DELTA` = `0x0044` in the low 14 bits. The factory mines a CREATE2 salt for this. The `BaseHook` constructor reverts `HookAddressNotValid` at any other address. |
| Pool key | currency0 = native ETH (`address(0)`), currency1 = MOMO, fee 3000, tickSpacing 60, hooks = the hook |
| Seed | Opened by the factory with one-sided MOMO liquidity below the opening price, so the first buy lands in a pool holding no ETH. The hook has no initialize or liquidity callbacks and cannot revert either step. |
| Compiler | solc 0.8.26, `evm_version = "cancun"` (needed for `tstore`/`tload`), optimizer 200 runs, `bytecode_hash = "none"` |

Frontend references, all live on Sepolia and not used by the contracts:

| Contract | Address |
|---|---|
| PoolSwapTest | `0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe` |
| StateView | `0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C` |
| V4Quoter | `0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227` |

## Assumptions and design choices

- **ETH side = currency0.** Native ETH always sorts first, so on the launch pool currency0 is ETH. State is keyed by `PoolId`, so any pool may attach the hook. On a pool without native ETH, the 0.001 threshold is applied to currency0's raw units (`1e15`), and *buy* still means `zeroForOne`.
- **hookData is ignored.** The hook never needs a swapper identity and credits nobody, so a router can never claim anything. hookData is unauthenticated: any router can put anything in it. That is why nothing here relies on it.
- **Qualification uses the pool's own delta.** For exact-output swaps, the ETH side is what the pool took or paid, not counting the hook fee.
- **The fee cap is kept for safety.** With at most 200 bps, `ceil(x·bps/10_000) ≤ x` always holds, so `min(fee, |unspecified|)` never actually binds.
- **Streak length** is stored as `uint248` and cannot realistically overflow.

## Operational responsibilities and risks

- **No one administers the hook.** The fee schedule, threshold and permissions are constants. Changing them means deploying a new hook and a new pool.
- **Donations have to be triggered.** Fees accumulate as claims until someone calls `donateFees(key)`. Anyone can: a keeper, the website's donate button, or an LP. While the price is outside all positions, calls revert `NoLiquidity` and the claims wait.
- **Donations go to liquidity in range at the current tick.** An LP who adds a narrow position just before calling `donateFees` (JIT) captures a proportional share. That is inherent to `poolManager.donate`. Frequent donations reduce the amount at stake in any one call.
- **Streaks create MEV surface.** A same-direction trader raises the fee for the next same-direction trader. A searcher can reset a streak (at the cost above) before a large swap. Users should set price limits and slippage. V4Quoter simulates the hook, so its quotes include the fee.
- **Exact-output swaps pay the fee on top of the input.** Routers must budget input for it.
- **Tests are not an audit.** This hook holds users' fees. It needs the independent adversarial review step before release. The manifest (`launch.json`) is written by a separate assignment, and publication, attestation, admission, deployment and the frontend are handled by the services afterwards. This repository authorizes no transactions and controls no wallet.

## Build and test

```bash
forge build
forge test
forge fmt --check
```

All dependencies are vendored as plain files under `lib/`, so no network or submodules are needed:

| Dependency | Source | What is vendored |
|---|---|---|
| v4-core | `Uniswap/v4-core@46c6834` | `src/`, `test/utils/CurrencySettler.sol`, licenses |
| v4-periphery | `Uniswap/v4-periphery@3779387e` | `BaseHook`, `ImmutableState`, `IImmutableState`. This is the last commit before `BaseHook` moved out of periphery. |
| forge-std | v1.9.7 | `src/` |
| OpenZeppelin Contracts | v5.1.0 | `ERC20` and its direct imports |
| solmate | `89365b8` | `auth/Owned.sol`, which v4-core's `ProtocolFees` needs |

Tests run against a real v4-core `PoolManager` using v4-core's `PoolSwapTest` and `PoolModifyLiquidityTest`:

- **`test/MomentumFeeHook.t.sol`** covers:
  - permissions and address flags, including CREATE2 salt mining and the constructor revert at an address without the flags
  - callers other than the PoolManager being refused, and `unlockCallback` from the PoolManager being refused outside `donateFees`
  - the 30 → 200 bps schedule and the cap from the 18th swap
  - a qualifying flip resetting the fee to 30
  - a 0.0009 ETH swap leaving the streak unchanged
  - the threshold edges
  - the exact-input and exact-output fee for buys and sells, checked against an identical pool with no hook
  - rounding, per-pool state, and fee-formula fuzzing
  - `donateFees` success (fee-growth accounting) and each of its failure paths
- **`test/LaunchRehearsal.t.sol`** rehearses the launch:
  - one-sided MOMO seeded below the opening price
  - a first buy into the pool while it holds no ETH, then a sell
  - `NoLiquidity` while the price is out of range, then a successful donation later
- **`test/MomentumFeeHook.invariant.t.sol`** runs random swaps and donations across two hooked pools that share both currencies. It checks four invariants:
  - claims held == the sum of accrued, per currency
  - every fee matches the schedule
  - streaks match an independent model
  - the hook holds no raw balances
- **`test/Momentum.t.sol`** covers token supply, metadata, transfer failures and that no mint path exists.
