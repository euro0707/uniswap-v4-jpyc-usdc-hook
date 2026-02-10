---
name: codex-review
description: Codex CLI (read-only) を使うリスク優先のレビューゲート。PRレビュー、差分レビュー、セキュリティ監査、仕様/計画更新後レビュー、commit/PR/merge/release 前の品質ゲートで使用する。Findings は重大度順で、ファイル:行の証拠、影響、修正案、必要テストを必ず示す。作るものに応じて review lens を切り替える。非対象: 実装のみ依頼、翻訳、単純要約。
allowed-tools: Read, Grep, Glob, Bash
---

# Codex Review Gate

## Overview
このスキルは、Codex を監査役、Claude Code を修正役として分離し、
`review -> fix -> re-review` を `ok: true` まで反復する。

## Trigger Policy
### Use this skill
- PR/差分のコードレビュー
- セキュリティ監査、リスク評価
- 仕様/計画更新直後の整合性チェック
- commit/PR/merge/release 前の品質ゲート

### Do not use this skill
- 新規機能の実装だけを求められている時
- 翻訳、要約、文章校正のみの依頼
- UI文言や軽微な整形だけの依頼

## Mandatory Gates
以下のタイミングでは必ず実行する。
1. 仕様/計画更新直後
2. Major step 完了直後（>=5 files、新規モジュール、公開API変更、infra/config変更）
3. commit/PR/merge/release 前

## Core + Lens Model
毎回まず共通コアを確認する。
- correctness
- security
- regression
- testing

その上で作るものに応じて review lens を追加する。
- financial (DeFi / smart contracts)
- backend (API / DB / integration)
- frontend (UX / state / accessibility)
- infra (deploy / runtime / ops)
- product (business / conversion / UX friction)

詳細の選択基準は `reference/review-lens-matrix.md` を参照する。

## Workflow
規模判定 -> レンズ選択 -> フェーズレビュー -> 修正 -> 再レビュー

```text
small  : diff
medium : arch -> diff
large  : arch -> diff (parallel) -> cross-check
```

### Size Rules
- small: <=3 files and <=100 LOC
- medium: 4-10 files or 100-500 LOC
- large: >10 files or >500 LOC

`diff_range` を省略した場合は `HEAD` 比較を使用する。

## Execution
```bash
git diff <diff_range> --stat
git diff <diff_range> --name-status --find-renames
codex exec --sandbox read-only --model gpt-5.2-codex "<PROMPT>"
```

### Runtime Rules
- Codex 実行中に別工程へ進まない。
- 60秒ごとに最大20回 poll し、完了確認する。
- タイムアウト時は1回だけ再実行する。
- 再失敗時は未レビュー範囲を明記して継続する。

## Output Contract
Codex には JSON を1つだけ出力させる。
スキーマは `prompts/output-schema.json` を必ず使う。

### Report ordering
1. Findings (重大度順)
2. Open questions / assumptions
3. Summary (短く)

### Finding requirements
各 finding に以下を必須で含める。
- severity (`blocking` or `advisory`)
- category
- file and lines
- problem
- recommendation
- impact (summary または context 内で明示)

`blocking` が1件でもあれば `ok: false`。

## Quality Rules
- 推測ではなく証拠ベースで指摘する。
- スタイル指摘より、correctness/security/regression/testing を優先する。
- 不確実な内容は issue 化せず open question として残す。
- 修正案は「最小差分」で提示する。

## Presets
- technical: correctness, perf, maintainability, testing, style
- financial: security, correctness, testing
- backend: correctness, security, perf, testing, maintainability
- frontend: correctness, ux, perf, testing, accessibility
- infra: reliability, security, operability, rollback, observability
- product: business, ux, perf, security, maintainability

DeFi/金融では `reference/defi-security-checklist.md` を必読にする。

## Prompt Templates
- arch: `prompts/phase-arch.md`
- diff: `prompts/phase-diff.md`
- cross-check: `prompts/phase-cross-check.md`

各フェーズで次を含める。
1. テンプレート本文
2. 変数展開
3. JSON schema (`prompts/output-schema.json`)
4. 必要に応じた reference ファイル

## Parameters
- `preset`: technical | financial | backend | frontend | infra | product
- `review_focus`: カンマ区切りで観点を上書き
- `diff_range`: 比較範囲（省略時 `HEAD`）
- `parallelism`: large 時の並列度（1-5）
- `max_iters`: 再レビュー反復回数（既定 5）

## Validation and Iteration
3種類のテストを実施する。
1. Triggering tests: obvious / paraphrased / unrelated の3群を確認
2. Functional tests: 出力妥当性、エラーハンドリング、エッジケースを確認
3. Performance comparison: スキルあり/なしで tool calls と tokens を比較

目標値:
- Relevant query の自動発火率 90% 以上
- Unrelated query の非発火率 90% 以上

運用中は under/over-triggering を監視し、`description` と `trigger-tuning` を継続更新する。

- JSON 検証: `python scripts/validate-json-output.py output.json`
- 失敗時は schema 不整合と business rule を分離して修正する。
- スキル更新時は、`reference/trigger-tuning.md` のテストクエリで発火精度を再評価する。

## Troubleshooting
代表パターンは `reference/troubleshooting.md` を参照する。

## References
- `reference/review-lens-matrix.md`
- `reference/defi-security-checklist.md`
- `reference/severity-definitions.md`
- `reference/trigger-tuning.md`
- `reference/troubleshooting.md`
- `prompts/output-schema.json`