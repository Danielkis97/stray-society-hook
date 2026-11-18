# Stray Society — Uniswap v4 fee hook

The hook on the official $STRAY/ETH pool on Robinhood Chain (chain id 4663). It takes the protocol's
trading fee on every swap, in ETH, and hands it to the protocol's revenue router.

| | |
|---|---|
| Contract | [`src/hooks/StrayFeeHook.sol`](src/hooks/StrayFeeHook.sol) |
| Pool manager | Uniswap v4 `0x8366a39CC670B4001A1121B8F6A443A643e40951` (Robinhood Chain) |
| Permissions | `afterInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta` |
| Deployed | [`0xD0849FB0C69c7ACe0af96cdAFd6D3A27ee0890CC`](https://repo.sourcify.dev/4663/0xD0849FB0C69c7ACe0af96cdAFd6D3A27ee0890CC) (Robinhood Chain, source verified on Sourcify) |
| Pool | `0xf9dde077e1a4c026d8b930480b993d819348bba78b9ae4ab9e5a37d9956e9c6c` ($STRAY/ETH, fee 0, tick spacing 60) |
| Upgradeable | No. No owner, no admin function, no proxy. |
| Custom swap data | None. Swaps need no `hookData`. |

## What it does

- **Buy (ETH in):** the fee is taken from the ETH going in, in `beforeSwap`.
- **Sell (ETH out):** the fee is taken from the ETH coming out, in `afterSwap`.
- **Exact-output swaps** are refused rather than handled: the sign conventions flip there, and a
  refused swap costs a retry, a wrong one costs money.
- **One pool only:** the hook serves the one pool its launch contract opened; a second pool on the
  same hook is refused.
- The fee rate follows the pool's measured depth in four states (FeeSplits.sol); during the first
  hour after launch a launch rate applies that starts at 90 % and falls in a straight line to the normal fee.

The fee leaves the hook only towards the revenue router named at deployment; the hook holds no
other funds and has no function that sends to an address someone passes in.

## Tested against the live pool manager

The protocol repository tests this hook against the PoolManager deployed on chain 4663 (fork tests):
4.00 % taken on buys and sells, 1,024 fuzz runs over the swap size, exact-output refused, a second
pool refused, calls from anyone but the pool manager refused.

## Build

```bash
forge install uniswap/v4-core
forge build
```

Compiler settings in `foundry.toml` match the deployment, so the build reproduces the deployed bytecode.

## License

All rights reserved.
