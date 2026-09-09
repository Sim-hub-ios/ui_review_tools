#!/usr/bin/env python3
"""Synthetic T0 fixtures. Requires local ffmpeg/ffprobe and Xcode; no user library access."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

root = Path(tempfile.mkdtemp(prefix="ui-review-motion-t0-"))
print(f"Artifacts: {root}", flush=True)

def run(args):
    result = subprocess.run(args, text=True, capture_output=True, timeout=180)
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        raise SystemExit(result.returncode)
    return result.stdout

patches = ",".join([
    "drawbox=x=0:y=0:w=iw/8:h=ih/8:color=red:t=fill",
    "drawbox=x=iw-iw/8:y=0:w=iw/8:h=ih/8:color=lime:t=fill",
    "drawbox=x=0:y=ih-ih/8:w=iw/8:h=ih/8:color=blue:t=fill",
    "drawbox=x=iw-iw/8:y=ih-ih/8:w=iw/8:h=ih/8:color=yellow:t=fill",
])
for name, size, rate, duration in [("cfr30", "640x360", 30, 2), ("vfr", "640x360", 30, 2), ("benchmark60", "1920x1080", 60, 10)]:
    filt = patches
    if name == "vfr":
        filt += ",setpts='if(lt(N,30),N/(30*TB),(1+(N-30)/15)/TB)'"
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
         f"testsrc2=size={size}:rate={rate}:duration={duration}", "-vf", filt,
         "-c:v", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p",
         "-bf", "3", "-g", "120", "-fps_mode", "vfr", "-video_track_timescale", "60000", str(root / f"{name}.mp4")])
run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-display_rotation:v:0", "90", "-i", str(root / "cfr30.mp4"),
     "-c", "copy", str(root / "rotated90.mp4")])
for name in ["cfr30", "vfr", "rotated90", "benchmark60"]:
    output = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_frames",
                  "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", str(root / f"{name}.mp4")])
    (root / f"{name}.pts.json").write_text(output)
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(root / f"{name}.mp4"),
         "-frames:v", "1", str(root / f"{name}.reference.png")])
source = Path(__file__).with_name("motion_probe.swift")
compiler = run(["xcrun", "swiftc", "-parse-as-library", "-O", "-module-cache-path", str(root / "module-cache"),
                str(source), "-o", str(root / "motion-probe")])
print(compiler, end="")
print(run([str(root / "motion-probe"), str(root)]), end="")
print((root / "results.json").read_text())
