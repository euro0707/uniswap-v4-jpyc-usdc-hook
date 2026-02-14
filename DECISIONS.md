# Technical Decisions

## 2026-02-14 - Dynamic Fee Rounding (Safety-First)

### Background
During review we confirmed that changing the dynamic fee rounding method can increase effective fees at specific volatility points.

### Decision
We restored the legacy rounding behavior for `_getFeeBasedOnVolatility` to avoid unintended fee uplift.
We kept the Slot0 read helper change because it matches Uniswap v4 `StateLibrary` slot access layout.

### Impact
- Dynamic fee outputs return to previous effective values.
- No external interface changes.
- No storage layout changes.

### Validation
- Added regression test for representative volatility points in `test/VolatilityDynamicFeeHook.t.sol`.
- Existing BASE/MAX boundary checks remain in place.
