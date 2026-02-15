# Slither Triage DB Notes

`config/slither.db.json` stores accepted Slither findings by finding `id`.

## Important

- Finding `id` can change when source line mapping changes.
- Typical triggers: edits around `src/VolatilityDynamicFeeHook.sol` contract header or `_getFeeBasedOnVolatility`.
- If IDs drift, accepted findings can reappear in Slither output.

## Refresh Procedure

1. Run:
   - `slither . --show-ignored-findings --json slither-report.show-ignored.json`
2. Extract target findings (`divide-before-multiply`, `unimplemented-functions`) from `src/` and capture their latest `id`.
3. Update `config/slither.db.json` with the new IDs.
4. Verify:
   - `slither . --json slither-report.triage-verify.json`
   - Confirm `src/` output does not include the accepted two findings.
