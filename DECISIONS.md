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

## 2026-02-14 - CI Gas Snapshot Enforcement

### Background
We started tracking `.gas-snapshot` as a baseline artifact, but there was no CI workflow to prevent accidental drift.

### Decision
Add GitHub Actions workflow `.github/workflows/ci.yml` and enforce:
- `forge test`
- `forge snapshot --check .gas-snapshot`

### Impact
- Pull requests fail when gas snapshots are stale.
- Gas baseline updates become explicit and reviewable in diffs.

### Validation
- Locally verified `forge snapshot --check .gas-snapshot` passes with current baseline.

## 2026-02-14 - Slither Noise Reduction (`timestamp`) in `src/`

### Background
After prior triage, `src/` still contained timestamp-based Low findings.
These checks are part of intended cooldown/warmup/staleness controls, but repeated in reports as known noise.

### Decision
- Add explicit Slither suppressions for `timestamp` in:
  - `VolatilityDynamicFeeHook._beforeSwap`
  - `VolatilityDynamicFeeHook._afterSwap`
  - `ObservationLibrary.getRecent`
  - `ObservationLibrary.isStale`
  - `ObservationLibrary.validateMultiBlock`
- Keep logic unchanged; only annotate intent for static analysis.

### Impact
- No runtime behavior change.
- `src/` Low findings reduced to zero.

### Validation
- `forge test --match-contract VolatilityDynamicFeeHookTest` passed (`19 passed, 0 failed`).
- Re-ran `slither . --json slither-report.latest.json`.
- Current `src/` findings summary: `Medium: 0`, `Low: 0`, `Informational: 3`.

## 2026-02-15 - `_calculateVolatility` Cyclomatic Complexity

### Background
Slither still reports `cyclomatic-complexity` (Informational) for `_calculateVolatility`.
We reviewed whether to refactor into helper functions now or keep the current implementation.

### Decision
Keep `_calculateVolatility` as-is for now and retain the existing function-scoped complexity suppression.
Do not perform a structural refactor in this cycle.

### Impact
- No runtime behavior change.
- No gas-profile drift risk from control-flow changes in the volatility path.
- Static analysis keeps one accepted Informational finding for this function.

### Validation
- Run full baseline checks:
  - `forge test --gas-report`
  - `forge snapshot`
  - `forge snapshot --check .gas-snapshot`
  - `slither . --json slither-report.tmp.json` then replace `slither-report.latest.json`
- 2026-02-15 rerun results:
  - `forge test --gas-report`: `57 passed, 0 failed, 0 skipped`
  - `forge snapshot`: `57 passed, 0 failed, 0 skipped`
  - `forge snapshot --check .gas-snapshot`: pass
  - `slither` (`src/` scope): `Informational: 3` (`cyclomatic-complexity`, `pragma`, `unimplemented-functions`)

## 2026-02-15 - Migrate `timestamp` Slither Suppressions to Config

### Background
`timestamp` detector noise was previously handled with inline `slither-disable` comments in `src/`.
To reduce source-code annotation noise, we evaluated config-based suppression instead.

### Decision
- Add `slither.config.json` with `detectors_to_exclude: "timestamp"`.
- Remove inline `timestamp` suppressions from:
  - `VolatilityDynamicFeeHook._beforeSwap`
  - `VolatilityDynamicFeeHook._afterSwap`
  - `ObservationLibrary.getRecent`
  - `ObservationLibrary.isStale`
  - `ObservationLibrary.validateMultiBlock`

### Impact
- No runtime behavior change.
- Slither `timestamp` triage is centralized in config instead of inline comments.
- Slither runs 99 detectors (was 100) due config exclusion.

### Validation
- `forge test --match-contract VolatilityDynamicFeeHookTest` passed (`19 passed, 0 failed`).
- `slither . --json slither-report.tmp.json` completed with config loaded.
- `src/` findings remained: `Informational: 3` (`cyclomatic-complexity`, `pragma`, `unimplemented-functions`).

## 2026-02-15 - Migrate `divide-before-multiply` / `unimplemented-functions` to Triage DB

### Background
`divide-before-multiply` and `unimplemented-functions` were previously managed with inline source annotations.
To keep detector coverage while reducing source annotation noise, we moved these two accepted findings to a triage database.

### Decision
- Add `triage_database: "config/slither.db.json"` in `slither.config.json`.
- Add accepted finding IDs to `config/slither.db.json`:
  - `3bda7a9eb94b537088307ecfa0924f7a13b2c643661245014331dc90e4c607a2` (`divide-before-multiply` in `_getFeeBasedOnVolatility`)
  - `0dee0e45a80c0e6982faadfd9c18fbb608990b0f9872e10d64bcef49b190f350` (`unimplemented-functions` false positive on `BaseHook`)
- Remove inline suppressions for these two checks from `src/VolatilityDynamicFeeHook.sol`.

### Impact
- No runtime behavior change.
- Detector coverage is retained (checks still run), while only accepted findings are hidden via triage DB.
- `src/` findings drop from 3 informational items to 2 (`cyclomatic-complexity`, `pragma`).

### Validation
- `slither . --json slither-report.triage-verify.json` completed with config + triage DB.
- Verified `src/` detector set from JSON no longer includes `divide-before-multiply` or `unimplemented-functions`.
- `forge test --match-test test_feeCurve_rounding_regression_legacyBehavior` passed (`1 passed, 0 failed`).
- Added maintenance note for triage ID drift and refresh steps in `config/SLITHER_TRIAGE.md`.
