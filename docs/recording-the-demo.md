<!--
SPDX-FileCopyrightText: 2026 Netbeheer Nederland

SPDX-License-Identifier: Apache-2.0
-->

# Recording the demo

`scripts/record_demo.py` makes a video of the demo so you can show it
offline. It opens the HMI's **Traffic** page in a Playwright browser, starts
recording, runs a playbook from this repo's `playbooks/` folder (see
[playbooks/README.md](../playbooks/README.md)), and saves the video to
`recordings/` when the playbook ends.

The playbook runs in the BFF, through the same runner as
`playbooks/runner/run.py`. The script uploads it with the BFF's
`/api/playbooks` API as a saved playbook named `record-<name>`, runs it, and
deletes it again afterwards. This is the same as running it from the HMI.
Before recording, the script collapses the HMI's Playbook panel, which would
otherwise list the run's steps, and clears the Timeline, so the video shows
only the demo itself. Nothing from the
`iec61850-websocket` repository is needed.

## Prerequisites

- [uv](https://docs.astral.sh/uv/). The script declares its own dependencies
  (Playwright, PyYAML, requests), so you don't need a virtualenv for it.
- Chromium for Playwright. Install it once:

  ```bash
  uv run --with playwright playwright install chromium
  ```

- `ffmpeg` on the `PATH` (optional) to also get an `.mp4`. Without it you get
  only the `.webm`.

## Running

1. Bring the stack up:

   ```bash
   docker compose up -d
   ```

2. Open the HMI (http://localhost) and make sure the SO and FSPs are
   registered with the BFF (HMI → Connections).

3. Record:

   ```bash
   uv run scripts/record_demo.py
   ```

   This records `playbooks/demo.yaml`. Add `--headed` to watch the browser
   while it records.

The script waits 3 s on the Traffic page, runs the playbook, prints a line
per step (`[ 1/13] ✓ FSP01 dials the SO · linked on cp1 (0.7s)`), waits
another 4 s, and writes:

```text
recordings/demo-20261021-143000.webm
recordings/demo-20261021-143000.mp4    # if ffmpeg is installed
```

The file name is the playbook's name plus a timestamp. If a playbook step
fails, the video is still saved, and the script asks you to check the
recording. The exit code is 0 when every step passed, 1 when a step failed
or the run was stopped, and 2 when the playbook couldn't run at all (bad file,
BFF unreachable, another playbook already running). Ctrl+C stops the run in
the BFF.

## Examples

```bash
# another playbook, faster, only steps 2-5
uv run scripts/record_demo.py playbooks/other.yaml --pace 1s --steps 2-5

# the HMI on another host, at 720p
uv run scripts/record_demo.py \
    --hmi https://<pi-host> --bff http://<pi-host>:3000 --width 1280 --height 720
```

## Options

| Option | Default | |
|---|---|---|
| `playbook` | `playbooks/demo.yaml` | playbook to run |
| `--hmi URL` | `http://localhost` | HMI base URL. Self-signed certificates are accepted |
| `--page PATH` | `/traffic` | HMI page to record |
| `--out DIR` | `recordings/` | where the videos go |
| `--width` / `--height` | `1920` / `1080` | viewport and video size |
| `--lead-in SECONDS` | `3` | wait before the playbook starts |
| `--tail SECONDS` | `4` | wait after the playbook ends |
| `--headed` | off | show the browser |
| `--playbook-panel` | `collapsed` | the HMI's Playbook panel in the video: `collapsed`, `hidden` or `open` |
| `--keep-timeline` | off | keep the HMI's Timeline as it is instead of clearing it first |
| `--no-mp4` | off | keep only the `.webm` |
| `--bff URL` | the playbook's `bff`, else `http://localhost:3000` | BFF that runs the playbook |
| `--pace 2s` | the playbook's `pace` | pause between steps |
| `--steps 3` / `--steps 2-5` | all | only these steps |
| `--keep-going` | off | run on after a failed step |

## Troubleshooting

- **`error: starting the playbook: 409 ...`**: another playbook is running
  in the BFF. Stop it in the HMI (Traffic → Playbook) and try again.
- **`Executable doesn't exist ... chromium`**: run the
  `playwright install chromium` command from Prerequisites.
- **The video shows an empty or login page**: the HMI wasn't reachable at
  `--hmi`, or it requires a login. Run with `--headed` to see what the
  browser gets.
- **The playbook fails at step 1**: the BFF is unreachable, or the SO and
  FSPs aren't registered. Run the playbook from the HMI first (Traffic →
  Playbook) to check the setup.
