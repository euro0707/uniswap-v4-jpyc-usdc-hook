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

## 2026-02-14 - Slither Medium (`divide-before-multiply`) Triage

### Background
Slither reports `divide-before-multiply` in `_getFeeBasedOnVolatility`.
That warning is usually valid for precision loss, but this path intentionally keeps legacy two-step rounding to avoid fee uplift at specific volatility points.

### Decision
Keep the current arithmetic order as-is to preserve deployed/tested fee outputs.
Add an inline function-scoped `slither-disable-start/end divide-before-multiply` annotation with intent comments.

### Impact
- No runtime behavior change.
- Static analysis Medium count for this path is triaged as intentional.
- Fee regression expectations at `v=14` and `v=64` remain stable.

### Validation
- `test_feeCurve_rounding_regression_legacyBehavior` protects the accepted rounding behavior.
- Re-run Slither after annotation refresh to confirm report alignment.
