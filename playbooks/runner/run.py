#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml", "requests"]
# ///
# SPDX-FileCopyrightText: 2025-2026 Netbeheer Nederland
# SPDX-License-Identifier: Apache-2.0
#
# Copyright 2025-2026 Netbeheer Nederland
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Run a demo playbook from the command line, in the BFF:

    uv run playbooks/runner/run.py playbooks/demo.yaml [--pace 2s] [--keep-going]

The BFF runs it, as when you run it from the HMI: the file is uploaded as a
saved playbook through /api/playbooks, run, followed until it ends and
deleted again. scripts/record_demo.py runs playbooks with this too. See
playbooks/README.md.
"""

from __future__ import annotations

import argparse
import re
import sys
import time
from pathlib import Path
from typing import Any

import requests
import yaml

DEFAULT_BFF = "http://localhost:3000"


def step_range(text: str) -> range:
    """ "3" or "2-5" -> a range of step numbers."""
    m = re.fullmatch(r"(\d+)(?:-(\d+))?", text)
    if not m:
        raise argparse.ArgumentTypeError(f"not a step or range: {text!r}")
    first = int(m.group(1))
    return range(first, int(m.group(2) or first) + 1)


def run_playbook(
    path: Path,
    *,
    bff: str | None = None,
    pace: str | None = None,
    keep_going: bool = False,
    steps: range | None = None,
    prefix: str = "cli",
) -> int:
    """Run the playbook file in the BFF; 0 if all steps passed, 1 if not, 2
    if it couldn't run."""
    try:
        playbook = yaml.safe_load(path.read_text())
    except (OSError, yaml.YAMLError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if not isinstance(playbook, dict) or not isinstance(playbook.get("steps"), list):
        print(f"error: {path} has no list of steps", file=sys.stderr)
        return 2
    if steps:
        playbook["steps"] = [
            step for i, step in enumerate(playbook["steps"], 1) if i in steps
        ]
    bff = (bff or playbook.get("bff") or DEFAULT_BFF).rstrip("/")
    # Saved under a name of its own, so the BFF runs exactly this file (and
    # only these steps), whatever its built-in copy holds.
    name = f"{prefix}-{path.stem}"[:64]
    try:
        r = requests.put(
            f"{bff}/api/playbooks/{name}", json={"playbook": playbook}, timeout=10
        )
        if not r.ok:
            print(f"error: saving the playbook: {r.status_code} {r.text}", file=sys.stderr)
            return 2
        r = requests.post(
            f"{bff}/api/playbooks/{name}/run",
            json={"pace": pace, "keep_going": keep_going},
            timeout=10,
        )
        if not r.ok:
            print(f"error: starting the playbook: {r.status_code} {r.text}", file=sys.stderr)
            return 2
        print(f"playbook: {path} running in the BFF as {name!r}", flush=True)
        return follow_run(bff)
    except requests.RequestException as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    finally:
        try:
            requests.delete(f"{bff}/api/playbooks/{name}", timeout=10)
        except requests.RequestException:
            pass


def follow_run(bff: str) -> int:
    """Print each step as it ends; 0 if all passed, 1 if not, 2 on an error."""
    printed = set()
    try:
        while True:
            run: dict[str, Any] = requests.get(
                f"{bff}/api/playbooks/run", timeout=10
            ).json()["run"]
            steps = run["steps"]
            for step in steps:
                if step["status"] in ("ok", "failed") and step["index"] not in printed:
                    printed.add(step["index"])
                    mark = "✓" if step["status"] == "ok" else "✗"
                    detail = f" · {step['message']}" if step["message"] else ""
                    print(
                        f"[{step['index']:>2}/{len(steps)}] {mark} {step['label']}"
                        f"{detail} ({step['seconds']}s)",
                        flush=True,
                    )
            if run["state"] != "running":
                break
            time.sleep(0.5)
    except KeyboardInterrupt:
        requests.post(f"{bff}/api/playbooks/run/stop", timeout=10)
        raise
    if run["error"]:
        print(f"error: {run['error']}", file=sys.stderr)
    return {"passed": 0, "error": 2}.get(run["state"], 1)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run an rti-demo playbook in the BFF."
    )
    parser.add_argument("playbook", type=Path, help="playbook file (.yaml or .json)")
    parser.add_argument(
        "--bff",
        help=f"BFF base URL (default: the playbook's 'bff', else {DEFAULT_BFF})",
    )
    parser.add_argument(
        "--pace",
        help="pause between steps, e.g. 2s (default: the playbook's 'pace', else none)",
    )
    parser.add_argument(
        "--keep-going", action="store_true", help="run on after a failed step"
    )
    parser.add_argument(
        "--steps", type=step_range, help="only these steps, e.g. 3 or 2-5"
    )
    args = parser.parse_args(argv)
    return run_playbook(
        args.playbook,
        bff=args.bff,
        pace=args.pace,
        keep_going=args.keep_going,
        steps=args.steps,
    )


if __name__ == "__main__":
    sys.exit(main())
