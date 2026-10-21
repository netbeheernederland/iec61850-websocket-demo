#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright", "pyyaml", "requests"]
# ///
# Records the HMI's Traffic page while a playbook drives the demo, so the
# demo can be shown offline. The playbook runs in the BFF, through
# playbooks/runner/run.py, as when you run it from the HMI. Bring the stack up first
# (docker compose up -d), then:
#
#   uv run scripts/record_demo.py                 # playbooks/demo.yaml
#   uv run scripts/record_demo.py --headed        # watch while it records
#
# First run only: uv run --with playwright playwright install chromium
"""Record an rti-demo playbook run as a video of the HMI."""

import argparse
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from playwright.sync_api import sync_playwright

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
from playbooks.runner.run import DEFAULT_BFF, run_playbook, step_range  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "playbook", nargs="?", default=REPO / "playbooks" / "demo.yaml", type=Path
    )
    parser.add_argument("--hmi", default="http://localhost", help="HMI base URL")
    parser.add_argument("--page", default="/traffic", help="HMI page to record")
    parser.add_argument("--out", default=REPO / "recordings", type=Path)
    parser.add_argument("--width", default=1920, type=int)
    parser.add_argument("--height", default=1080, type=int)
    parser.add_argument("--lead-in", default=3.0, type=float, help="seconds before the playbook starts")
    parser.add_argument("--tail", default=4.0, type=float, help="seconds after the playbook ends")
    parser.add_argument("--headed", action="store_true", help="show the browser")
    parser.add_argument(
        "--playbook-panel",
        choices=["collapsed", "hidden", "open"],
        default="collapsed",
        help="how the HMI's Playbook panel shows in the video",
    )
    parser.add_argument(
        "--keep-timeline", action="store_true", help="don't clear the HMI's Timeline first"
    )
    parser.add_argument("--no-mp4", action="store_true", help="keep only the .webm")
    parser.add_argument(
        "--bff", help=f"BFF base URL (default: the playbook's 'bff', else {DEFAULT_BFF})"
    )
    parser.add_argument("--pace", help="pause between steps, e.g. 3s (default: the playbook's)")
    parser.add_argument("--steps", type=step_range, help="only these steps, e.g. 3 or 2-5")
    parser.add_argument("--keep-going", action="store_true", help="run on after a failed step")
    return parser.parse_args()


def panel(page, title: str):
    """The Traffic page panel headed `title`."""
    return page.locator("section.page > div").filter(
        has=page.get_by_role("heading", name=title, exact=True)
    )


def collapse_playbook_panel(page) -> None:
    # The panel lists the run's steps; collapsed, only its title shows. Its
    # header toggles it, and a chevron-up means it's open.
    header = panel(page, "Playbook").first.locator(":scope > div").first
    if not header.count():
        print("no Playbook panel on the page; nothing to collapse", file=sys.stderr)
    elif header.locator(".fa-chevron-up").count():
        header.click()


def hide_playbook_panel(page) -> None:
    # The run shows in the HMI's Playbook panel as well; keep it out of the
    # video so the demo itself has the screen.
    playbook = panel(page, "Playbook")
    if playbook.count():
        playbook.first.evaluate("e => { e.style.display = 'none' }")
    else:
        print("no Playbook panel on the page; nothing to hide", file=sys.stderr)


def clear_timeline(page) -> None:
    # By its text: the button's title, not "Clear", is its accessible name.
    clear = panel(page, "Timeline").locator("button", has_text=re.compile(r"^\s*Clear\s*$"))
    if clear.count():
        clear.first.click()
    else:
        print("no Timeline Clear button on the page; not cleared", file=sys.stderr)


def to_mp4(webm: Path) -> Path | None:
    if not shutil.which("ffmpeg"):
        print("ffmpeg not found; keeping the .webm only", file=sys.stderr)
        return None
    mp4 = webm.with_suffix(".mp4")
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(webm),
         "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p",
         "-movflags", "+faststart", str(mp4)],
        check=True,
    )
    return mp4


def main() -> int:
    args = parse_args()
    if not args.playbook.is_file():
        sys.exit(f"no playbook {args.playbook}")
    args.out.mkdir(parents=True, exist_ok=True)
    size = {"width": args.width, "height": args.height}

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not args.headed)
        context = browser.new_context(
            viewport=size,
            record_video_dir=str(args.out),
            record_video_size=size,
            ignore_https_errors=True,
        )
        page = context.new_page()
        page.goto(args.hmi.rstrip("/") + args.page, wait_until="networkidle")
        if args.playbook_panel == "collapsed":
            collapse_playbook_panel(page)
        elif args.playbook_panel == "hidden":
            hide_playbook_panel(page)
        if not args.keep_timeline:
            clear_timeline(page)
        page.wait_for_timeout(args.lead_in * 1000)

        rc = run_playbook(
            args.playbook,
            bff=args.bff,
            pace=args.pace,
            keep_going=args.keep_going,
            steps=args.steps,
            prefix="record",
        )

        page.wait_for_timeout(args.tail * 1000)
        video = page.video
        context.close()  # the video is only written once the context closes
        recorded = Path(video.path())
        browser.close()

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    webm = recorded.rename(args.out / f"{args.playbook.stem}-{stamp}.webm")
    print("video:", webm)
    if not args.no_mp4 and (mp4 := to_mp4(webm)):
        print("video:", mp4)
    if rc:
        print(f"playbook exited with {rc}; check the recording", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
