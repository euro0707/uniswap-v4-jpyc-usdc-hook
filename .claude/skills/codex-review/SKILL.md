---
name: codex-review
description: Codex CLI（read-only）を用いて、レビュー→Claude Code修正→再レビュー（ok: true まで）を反復し収束させるレビューゲート。仕様書/SPEC/PRD/要件定義/設計、実装計画（PLANS.md等）の作成・更新直後、major step（>=5 files / 新規モジュール / 公開API / infra・config変更）完了後、および git commit / PR / merge / release 前に使用する。キーワード: Codexレビュー, codex review, レビューゲート.
allowed-tools: Read, Grep, Glob, Bash
---

# Codex反復レビュー

> **品質保証**: このスキルは GPT-5.2-codex (xhigh) による最高推論レベルのセキュリティレビューを提供します。
> **構造化出力**: JSON Schema準拠の検証済み出力を保証します。
> **DeFi特化**: 50+項目のセキュリティチェックリストに基づく金融コントラクト監査。

---

## 📋 目次

1. [必須実行タイミング](#必須実行タイミングmandatory-review-gate)
2. [フロー概要](#フロー)
3. [規模判定](#規模判定)
4. [修正ループ](#修正ループ)
5. [Codex実行](#codex実行)
6. [出力スキーマ](#codex出力スキーマ)
7. [プロンプトテンプレート](#プロンプトテンプレート)
8. [レビュープリセット](#レビュープリセット)
9. [パラメータ](#パラメータ)
10. [参考資料](#参考資料)

---

## 必須実行タイミング（Mandatory Review Gate）

以下のマイルストーン到達時、**必ず** このスキルを実行し、`ok: true` を得てから次工程へ進むこと:

1. **仕様・計画の更新後**
   - 仕様書/SPEC/PRD/要件定義/設計 の作成・更新直後
   - 実装計画（PLANS.md等）の作成・更新直後

2. **Major implementation steps 完了後**
   - ≥5 files: 5ファイル以上を変更
   - 新規モジュール追加
   - 公開API (public API) の追加・変更
   - インフラ・設定ファイル (infra・config) の変更

3. **リリースプロセスの各段階**
   - git commit 前
   - PR (Pull Request) 作成前
   - merge 前
   - release 前

**原則**: review→fix→re-review を `ok: true` が出るまで反復し、品質ゲートを通過してから次へ進む。

## フロー
規模判定 → Codex規模別レビュー → Claude Code修正 → 再レビュー（`ok: true`まで反復）

```
[規模判定] → small:  diff ──────────────────→ [修正ループ]
          → medium: arch → diff ───────────→ [修正ループ]
          → large:  arch → diff並列 → cross-check → [修正ループ]
```

- Codex: read-onlyでレビュー（監査役）
- Claude Code: 修正担当

## 規模判定

```bash
git diff <diff_range> --stat
git diff <diff_range> --name-status --find-renames
```

| 規模 | 基準 | 戦略 |
|-----|------|-----|
| small | ≤3ファイル、≤100行 | diff |
| medium | 4-10ファイル、100-500行 | arch → diff |
| large | >10ファイル、>500行 | arch → diff並列 → cross-check |

`diff_range` 省略時: HEAD を使用し、作業ツリーの未コミット変更（作業ツリー vs HEAD）を対象とする（staged/unstaged の区別はしない）。

**large時:**
- 並列: 3-5サブエージェント、各サブは担当ファイルのみ
- 分割: 1呼び出しあたり最大5ファイル/300行、ディレクトリ単位で分割（cross-cutting concernsはcross-checkで検出）
- 統合はメイン（Claude Code）で実施

## 修正ループ

`ok: false`の場合、`max_iters`回まで反復:
1. `issues`解析 → 修正計画
2. Claude Codeが修正（最小差分のみ、仕様変更は未解決issueに）
3. テスト/リンタ実行（可能なら）
4. Codexに再レビュー依頼

停止条件:
`ok: true` / `max_iters`到達 / テスト2回連続失敗


## Codex実行

```bash
codex exec --sandbox read-only --model gpt-5.2-codex "<PROMPT>"
```

**重要な設定**:
- `--sandbox read-only`: 読み取り専用モードで実行（監査役としての独立性確保）
- `--model gpt-5.2-codex`: **GPT-5.2-codex** を使用（最高推論レベルのレビュー）
  - reasoning effort: **xhigh** が自動適用（~/.codex/config.toml の設定）
  - OpenAI の最高推論レベルで詳細な分析
  - DeFi/金融コントラクトのセキュリティ問題を徹底的に検出
  - コスト・品質・時間のバランスが最適
- PROMPT には（スキーマ含む）最終プロンプトを渡す
- 主要な関連ファイルパスはClaude Codeが明示

**レビュー完了待ち（必須）**:
- codex exec 実行中は次の工程に進まない（別タスク開始・推測での中断禁止）
- 定期確認: 60秒ごとに最大20回、`poll i/20` と経過時間のみをログし、追加作業はしない
- 20回到達後も未完了なら: 「タイムアウト」扱いでエラー時ルールへ
- 長時間無出力になり得るため、必要に応じて codex exec をバックグラウンド実行し、プロセス生存確認を poll として扱ってよい

## Codex出力スキーマ

CodexにJSON1つのみ出力させる。Claude Codeはプロンプト末尾に以下のスキーマとフィールド説明を添付。

**完全なJSONスキーマ**: [prompts/output-schema.json](prompts/output-schema.json)

**出力例**:
```json
{
  "ok": true,
  "phase": "arch|diff|cross-check",
  "summary": "レビューの要約",
  "issues": [
    {
      "severity": "blocking",
      "category": "security",
      "file": "src/auth.py",
      "lines": "42-45",
      "problem": "問題の説明",
      "recommendation": "修正案",
      "context": "オプション: 追加情報"
    }
  ],
  "notes_for_next_review": "メモ"
}
```

**フィールド説明**:
- `ok`: blockingなissueが0件ならtrue、1件以上ならfalse
- `phase`: "arch" | "diff" | "cross-check"
- `summary`: レビューの要約（10-500文字）
- `issues`: 発見された問題のリスト
  - `severity`: 2段階
    - **blocking**: 修正必須。1件でもあれば`ok: false`
    - **advisory**: 推奨・警告。`ok: true`でも出力可、レポートに記載のみ
  - `category`: correctness / security / perf / maintainability / testing / style / business / ux
    - **security**: 再入攻撃、アクセス制御、整数オーバーフロー、価格操作
    - **correctness**: 手数料計算、状態遷移、不変条件
    - **business**: ビジネスロジック、収益影響、市場適合性
    - **ux**: ユーザー体験、オンボーディング、エラーメッセージ、遅延
  - `file`: ファイルパス（リポジトリルートからの相対パス）
  - `lines`: 行番号または範囲（例: "42" または "42-45"）
  - `problem`: 問題の詳細説明（10文字以上）
  - `recommendation`: 修正案（10文字以上）
  - `context` (オプション): 追加コンテキスト、関連コードスニペット
- `notes_for_next_review`: Codexが残すメモ。再レビュー時にClaude Codeがプロンプトに含める

**検証ツール**: [scripts/validate-json-output.py](scripts/validate-json-output.py)
```bash
# 出力を検証
python scripts/validate-json-output.py output.json
# または stdin から
codex exec ... | python scripts/validate-json-output.py --stdin
```

## プロンプトテンプレート

各フェーズの詳細なプロンプトテンプレートは以下のファイルを参照してください：

- **arch フェーズ**: [prompts/phase-arch.md](prompts/phase-arch.md)
  - アーキテクチャ整合性レビュー
  - 依存関係、責務分割、破壊的変更、セキュリティ設計

- **diff フェーズ**: [prompts/phase-diff.md](prompts/phase-diff.md)
  - 詳細な差分レビュー
  - Correctness, Security, Performance, Maintainability, Testing

- **cross-check フェーズ**: [prompts/phase-cross-check.md](prompts/phase-cross-check.md)
  - 横断的整合性レビュー
  - Interface整合、Error handling、認可、API互換

### テンプレート使用時の注意

Claude Codeは各フェーズのプロンプトを構築する際、以下を含めること：
1. 該当フェーズのテンプレート本文
2. `{変数}` を実際の値で置換
3. JSON Schemaを末尾に添付（`prompts/output-schema.json`から読み込み）
4. DeFi セキュリティチェックリスト参照（financial preset時）

## エラー時の共通ルール

Codex exec失敗時（タイムアウト・API障害・その他）:
1. 1回リトライ（タイムアウトはファイル数を半分に分割して）
2. 再失敗 → 該当フェーズをスキップし、理由をレポートに記録
3. archスキップ時はdiffのみで続行、diffスキップ時はそのファイル群を「未レビュー」としてレポート

## レビュープリセット

プロジェクトタイプに応じた観点の組み合わせ。`preset` パラメータで指定可能（`review_focus` で個別上書き可）。

| プリセット | 対象 | 観点 | 重点項目 |
|----------|------|------|---------|
| **technical**（既定） | OSS・ライブラリ・インフラ | correctness, perf, maintainability, testing, style | 技術的正確性・汎用性 |
| **financial** | DeFi・金融コントラクト・決済 | security, correctness, testing | 資金損失防止・監査可能性・ガス効率 |
| **product** | SaaS・toC・収益アプリ | business, ux, perf, security, maintainability | オンボーディング遅延・決済UX・エラーハンドリング |

### プリセット別の詳細観点

#### technical（技術重視）
- correctness: アルゴリズム正確性、エッジケース
- perf: 時間計算量、メモリ使用量
- maintainability: 命名、関数分割、コメント
- testing: テストカバレッジ、テスタビリティ
- style: コーディング規約、一貫性

#### financial（セキュリティ最優先）
- security: 再入攻撃、アクセス制御、整数オーバーフロー、価格操作
- correctness: 手数料計算、状態遷移、不変条件
- testing: セキュリティテスト、フォーマル検証、監査ログ
- **重点リスク**: 資金損失、ハッキング、評判崩壊

#### product（ビジネス視点）
- business: 収益影響、KPI、市場適合性、競合優位性
- ux: オンボーディング/ペイウォール遅延、エラーメッセージ、決済フロー、ローディング状態
- perf: ユーザー体験に影響するレスポンス時間
- security: 認証・認可、データ保護
- maintainability: 機能追加のしやすさ
- **重点リスク**: 解約率、コンバージョン低下、ユーザー不満

## パラメータ

| 引数 | 既定 | 説明 |
|-----|-----|-----|
| preset | technical | technical / financial / product（上記プリセット参照） |
| max_iters | 5 | 最大反復（上限5） |
| review_focus | - | 重点観点（preset上書き、カンマ区切り）。例: "security,perf,ux" |
| diff_range | HEAD | 比較範囲 |
| parallelism | 3 | large時並列度（上限5） |

### 使用例

```bash
# 技術的正確性のみ（OSS・ライブラリ開発）
/codex-review
/codex-review --preset technical

# 金融コントラクト（現プロジェクト）
/codex-review --preset financial

# SaaS・収益アプリ
/codex-review --preset product

# カスタム（プリセット上書き）
/codex-review --preset financial --review_focus "security,perf,business"
```

## 参考資料

### 詳細ドキュメント

- **DeFi セキュリティチェックリスト**: [reference/defi-security-checklist.md](reference/defi-security-checklist.md)
  - 50+項目の詳細チェックリスト
  - フラッシュローン、MEV、Oracle、ガス効率、アップグレードセキュリティ等

- **Severity 定義ガイド**: [reference/severity-definitions.md](reference/severity-definitions.md)
  - blocking vs advisory の判定基準
  - カテゴリ別（security, correctness, testing等）の詳細ガイド

- **JSON Schema**: [prompts/output-schema.json](prompts/output-schema.json)
  - Structured Outputs 準拠スキーマ
  - `additionalProperties: false` による厳格な検証

- **JSON 検証スクリプト**: [scripts/validate-json-output.py](scripts/validate-json-output.py)
  - スキーマ検証 + ビジネスロジック検証
  - 使用例: `python scripts/validate-json-output.py output.json`

### 外部参考資料

- [Consensys Smart Contract Best Practices](https://consensys.github.io/smart-contract-best-practices/)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Trail of Bits Security Guide](https://github.com/crytic/building-secure-contracts)

---

## 終了レポート例

```
## Codexレビュー結果（Opus 4.5）
- モデル: claude-opus-4-5-20251101
- 規模: large（12ファイル、620行）
- 並列: 3サブエージェント、4グループ
- 反復: 2/5 / ステータス: ✅ ok

### 修正履歴
- auth.py: 認可チェック追加

### Advisory（参考）
- main.py: 関数名がやや冗長、リファクタ推奨

### 未レビュー（エラー時のみ）
- utils/legacy.py: Codexタイムアウト、手動確認推奨

### 未解決（あれば）
- main.py: 内容、リスク、推奨アクション

### 検証
- JSON Schema検証: ✅ 成功
- ビジネスロジック検証: ✅ ok=true, blocking issues=0
```

---

## 変更履歴

- **2026-01-10**: Progressive Disclosure化、Opus 4.5対応、DeFiチェックリスト追加、JSON検証スクリプト実装
