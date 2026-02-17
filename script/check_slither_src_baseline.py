#!/usr/bin/env python3
"""Run Slither and enforce current src/ baseline findings."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

TMP_REPORT = Path("slither-report.tmp.json")
TMP_IGNORED_REPORT = Path("slither-report.show-ignored.tmp.json")

# Current accepted baseline for this repository.
EXPECTED_VISIBLE = {"pragma": 1}
EXPECTED_IGNORED = {
    "cyclomatic-complexity": 1,
    "divide-before-multiply": 1,
    "pragma": 1,
    "unimplemented-functions": 1,
}


def normalize_exit_code(code: int) -> int:
    # Some environments surface 255 as -1.
    if code in (-1, 4294967295):
        return 255
    return code


def run_command(cmd: list[str], allowed_exit_codes: set[int]) -> None:
    print(f"==> {' '.join(cmd)}")
    completed = subprocess.run(cmd, check=False)
    normalized = normalize_exit_code(completed.returncode)
    if normalized not in allowed_exit_codes:
        raise RuntimeError(
            f"Command failed: {' '.join(cmd)} (exit: {completed.returncode})"
        )


def load_json(path: Path) -> dict:
    if not path.exists():
        raise FileNotFoundError(f"Missing expected report file: {path}")
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def src_check_counts(report: dict) -> dict[str, int]:
    counts: dict[str, int] = {}
    detectors = report.get("results", {}).get("detectors", [])
    for detector in detectors:
        elements = detector.get("elements") or []
        has_src = False
        for element in elements:
            source_mapping = element.get("source_mapping") or {}
            relative = source_mapping.get("filename_relative") or ""
            if relative.startswith("src/"):
                has_src = True
                break
        if not has_src:
            continue
        check = detector.get("check")
        if not check:
            continue
        counts[check] = counts.get(check, 0) + 1
    return dict(sorted(counts.items()))


def print_counts(title: str, counts: dict[str, int]) -> None:
    print(f"\n==> {title}")
    if not counts:
        print("none")
        return
    for check, count in counts.items():
        print(f"{check}\t{count}")


def remove_if_exists(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def ensure_tooling_on_path() -> None:
    foundry_bin = Path.home() / ".foundry" / "bin"
    path_entries = os.environ.get("PATH", "").split(os.pathsep)
    if foundry_bin.exists() and str(foundry_bin) not in path_entries:
        os.environ["PATH"] = f"{foundry_bin}{os.pathsep}{os.environ.get('PATH', '')}"

    for tool in ("slither", "forge"):
        if shutil.which(tool) is None:
            raise RuntimeError(f"Required tool not found on PATH: {tool}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--keep-temp",
        action="store_true",
        help="Keep temporary Slither JSON files for debugging.",
    )
    args = parser.parse_args()

    allowed = {0, 1, 255}

    try:
        ensure_tooling_on_path()

        remove_if_exists(TMP_REPORT)
        remove_if_exists(TMP_IGNORED_REPORT)

        run_command(["slither", ".", "--json", str(TMP_REPORT)], allowed)
        run_command(
            [
                "slither",
                ".",
                "--show-ignored-findings",
                "--json",
                str(TMP_IGNORED_REPORT),
            ],
            allowed,
        )

        visible = src_check_counts(load_json(TMP_REPORT))
        ignored = src_check_counts(load_json(TMP_IGNORED_REPORT))

        print_counts("Slither src/ checks (visible)", visible)
        print_counts("Slither src/ checks (show-ignored-findings)", ignored)

        errors: list[str] = []
        if visible != EXPECTED_VISIBLE:
            errors.append(
                f"Visible src baseline mismatch: expected {EXPECTED_VISIBLE}, got {visible}"
            )
        if ignored != EXPECTED_IGNORED:
            errors.append(
                f"Ignored src baseline mismatch: expected {EXPECTED_IGNORED}, got {ignored}"
            )

        if errors:
            print("\nBaseline validation failed:")
            for err in errors:
                print(f"- {err}")
            return 1

        print("\nSlither src baseline matches expected findings.")
        return 0
    finally:
        if not args.keep_temp:
            remove_if_exists(TMP_REPORT)
            remove_if_exists(TMP_IGNORED_REPORT)


if __name__ == "__main__":
    os.environ.setdefault("PYTHONUTF8", "1")
    sys.exit(main())
