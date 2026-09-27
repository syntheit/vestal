#!/usr/bin/env python3
"""Generate the expression engine's ground-truth fixtures from real jq.

Reads Tests/VestalCoreTests/Fixtures/expr-cases.txt, runs every case through
jq, and writes Tests/VestalCoreTests/Fixtures/expr-cases.json, which
ExprFixtureTests replays against JQExpression.

usage: scripts/gen-expr-fixtures.py [--jq PATH] [--jq18 PATH]

--jq    jq 1.7.x for most cases (default: `jq` on PATH). With Nix:
        nix build 'github:nixos/nixpkgs/nixos-24.05#jq.bin' --print-out-paths
--jq18  jq 1.8.x for cases marked @jq18 (default: same as --jq)

jq runs with TZ=UTC and LC_ALL=C so date output does not depend on the
machine. jq 1.7 prints number literals verbatim (1.000, 1E+17), so outputs
are stored as parsed JSON values, not jq's text.
"""

import argparse
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Tests" / "VestalCoreTests" / "Fixtures"


def run_jq(jq, expr, input_text):
    env = dict(os.environ, TZ="UTC", LC_ALL="C")
    # A leading space keeps jq from reading "-1" as an option.
    args = [jq, "-c", " " + expr if expr.startswith("-") else expr]
    if input_text is None:
        args.insert(1, "-n")
    try:
        p = subprocess.run(args, input=(input_text or "").encode(), capture_output=True, env=env, timeout=20)
    except subprocess.TimeoutExpired:
        return {"error": "timeout", "kind": "timeout"}
    out = p.stdout.decode()
    err = p.stderr.decode().strip()
    outputs = [json.loads(line) for line in out.splitlines() if line.strip()]
    if p.returncode == 0:
        return {"outputs": outputs}
    if "compile error" in err or p.returncode == 3:
        return {"outputs": outputs, "error": err.splitlines()[0] if err else "", "kind": "compile"}
    # Runtime error: "jq: error (at <unknown>): MESSAGE" or
    # "jq: error (at <unknown>) (not a string): VALUE".
    line = err.splitlines()[0] if err else ""
    msg = line
    for prefix in ("jq: error (at <unknown>): ", "jq: error (at <stdin>:0): ", "jq: error (at <stdin>:1): "):
        if line.startswith(prefix):
            msg = line[len(prefix):]
    if "(not a string): " in line:
        msg = line.split("(not a string): ", 1)[1] + " (not a string)"
    if "Assertion failed" in err or p.returncode < 0:
        return {"outputs": outputs, "error": err, "kind": "crash"}
    return {"outputs": outputs, "error": msg, "kind": "runtime"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jq", default="jq")
    ap.add_argument("--jq18", default=None)
    a = ap.parse_args()
    jq18 = a.jq18 or a.jq

    for jq in {a.jq, jq18}:
        v = subprocess.run([jq, "--version"], capture_output=True).stdout.decode().strip()
        print(f"{jq}: {v}", file=sys.stderr)

    cases = []
    input_text = None
    loose = False
    use18 = False
    for n, raw in enumerate((FIXTURES / "expr-cases.txt").read_text().splitlines(), 1):
        line = raw.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        if line.startswith("@input "):
            input_text = line[len("@input "):]
            json.loads(input_text)
            continue
        if line == "@null":
            input_text = None
            continue
        if line == "@loose":
            loose = True
            continue
        if line == "@jq18":
            use18 = True
            continue
        result = run_jq(jq18 if use18 else a.jq, line, input_text)
        case = {"line": n, "expr": line, "input": None if input_text is None else json.loads(input_text)}
        if input_text is None:
            case["nullInput"] = True
        case.update(result)
        if loose:
            case["loose"] = True
        if use18:
            case["jq"] = "1.8"
        if result.get("kind") in ("crash", "timeout"):
            print(f"line {n}: jq {result['kind']}: {line}", file=sys.stderr)
        cases.append(case)
        loose = False
        use18 = False

    out = FIXTURES / "expr-cases.json"
    out.write_text(json.dumps(cases, indent=1, ensure_ascii=False) + "\n")
    print(f"wrote {len(cases)} cases to {out.relative_to(ROOT)}", file=sys.stderr)


if __name__ == "__main__":
    main()
