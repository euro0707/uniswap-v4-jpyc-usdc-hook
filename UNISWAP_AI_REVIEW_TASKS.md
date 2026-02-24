# Uniswap AI Review Tasks

Target: `Uniswap/uniswap-ai` (`main` @ `febd7e699d442168114548384b7d2ea7524a3811`)
Last updated: 2026-02-21

## Task 1 (P1): Fix Windows `UnicodeEncodeError` in `test_logic.py`
- Status: `DONE`
- Problem: Printing Unicode symbols (checkmark, cross, arrow) crashes on cp932 console.
- Files:
  - `_external/uniswap-ai/packages/plugins/uniswap-cca/mcp-server/supply-schedule/test_logic.py`
- Acceptance:
  - `python .../test_logic.py` completes on Windows PowerShell.
  - Linux/macOS compatibility remains intact.
- Result:
  - Replaced Unicode symbols with ASCII-safe strings (`OK`/`NG`, `->`).
  - Verified by full script execution (all tests passed).

## Task 2 (P1): Align MCP `inputSchema` and runtime validation
- Status: `DONE`
- Problem:
  - `final_block_pct` boundary behavior differs between schema and Pydantic.
  - `alpha` minimum behavior differs between schema and Pydantic.
- Files:
  - `_external/uniswap-ai/packages/plugins/uniswap-cca/mcp-server/supply-schedule/server.py`
- Acceptance:
  - Schema and runtime boundaries are exactly aligned.
  - Boundary inputs are validated with small reproducible checks.
- Result:
  - Updated schema to use `exclusiveMinimum`/`exclusiveMaximum` for `final_block_pct` and `alpha`.
  - Updated descriptions to match open-interval behavior.
  - Verified boundary behavior with a reproducible Python check:
    - `final_block_pct=0.1` rejected.
    - `alpha=0` rejected.
    - positive `alpha` accepted.

## Task 3 (P2): Make npm version check semver-aware in `prepare.cjs`
- Status: `DONE`
- Problem:
  - Range spec like `>=11.7.0` is compared by string equality, causing false warnings.
- Files:
  - `_external/uniswap-ai/scripts/prepare.cjs`
- Acceptance:
  - `engines.npm` range is evaluated correctly.
  - No warning for satisfying npm versions.
- Result:
  - Switched npm version check from string equality to `semver.satisfies(current, engines.npm)`.
  - Added graceful fallback to string comparison when version/range parsing is invalid.
  - Updated mismatch message to display `Required range` and suggest `semver.minVersion(range)` when available.

## Task 4 (P3): Define policy for `round_to_nearest` degenerate cases
- Status: `TODO`
- Problem:
  - Extreme rounding can produce many zero-duration phases but still pass.
  - Behavior can diverge from documentation expectations.
- Files:
  - `_external/uniswap-ai/packages/plugins/uniswap-cca/mcp-server/supply-schedule/logic.py`
  - `_external/uniswap-ai/packages/plugins/uniswap-cca/mcp-server/supply-schedule/README.md`
- Acceptance:
  - Explicit policy documented (allow vs reject degenerate rounding).
  - Implementation/docs updated to match policy.
  - Representative regression checks pass.

## Execution order
1. Task 1
2. Task 2
3. Task 3
4. Task 4
