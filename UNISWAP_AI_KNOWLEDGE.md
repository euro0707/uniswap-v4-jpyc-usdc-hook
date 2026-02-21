# Uniswap AI Knowledge Notes

Last updated: 2026-02-21

## Scope
These notes are for this repository: `uniswap-v4-dynamic-fee-hook`.

## Relevant plugins from `Uniswap/uniswap-ai`
1. `uniswap-hooks`
- Primary use: v4 hook security review and secure coding patterns.
- Practical use here: run/check against `v4-security-foundations` before merge and before deployment.

2. `uniswap-driver`
- Primary use: swap/liquidity planning support.
- Practical use here: useful when validating position strategy assumptions around liquidity behavior.

## Claude Code command
- Install plugin:
  - `/plugin install uniswap-hooks`

## Source handover reference
- `C:\Users\skyeu\.gemini\antigravity\brain\58a388df-6776-4a27-83c1-bfebccfacd9b\handover.md.resolved`

## Current security status snapshot from handover
- `VolatilityDynamicFeeHook.sol` was reviewed with `uniswap-hooks` and Slither.
- Reported result: no new critical/high/medium issues requiring immediate code change.
- Recommended ongoing operation:
  1. Re-run Slither right before mainnet deployment.
  2. Optionally add symbolic analysis (e.g., Mythril) for extra assurance.
