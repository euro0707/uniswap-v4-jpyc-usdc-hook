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

## 2026-02-14 - Slither Low/Informational (`src/`) Triage

### Background
After Medium triage, `src/` still had Low/Informational findings from Slither.
We reviewed each finding to separate actionable noise from design-expected behavior.

### Decision
- Remove avoidable noise by renaming `MockERC20` constructor parameters (`name`/`symbol` -> `name_`/`symbol_`) to resolve `shadowing-local`.
- Keep `timestamp` findings as accepted risk because time-based cooldown, warmup, and staleness logic are intentional protocol controls.
- Keep `cyclomatic-complexity` findings as accepted complexity for security-critical guard logic.
- Keep `pragma` mixed-version finding as dependency-driven (`lib/` constraints), not a project `src/` mismatch.
- Keep `unimplemented-functions` as a Slither false positive; `getHookPermissions()` is implemented in `VolatilityDynamicFeeHook`.

### Impact
- No runtime behavior change.
- Reduced static-analysis noise in project-owned code.

### Validation
- `forge test --match-contract MockERC20Test` passed (`4 passed, 0 failed`).
- Re-ran `slither . --json slither-report.latest.json`.
- Current `src/` findings summary: `Low: 5`, `Informational: 4`, `Medium: 0`.
