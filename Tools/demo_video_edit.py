#!/usr/bin/env python3
"""Cuts a raw `MacLister --demo-video` take into the finished clip.

  python3 Tools/demo_video_edit.py <raw.mov> <out.mp4>

Reads <raw>.markers.json (scene starts and ends, camera zoom hints) written by the app, then with ffmpeg:
cuts the scenes, zooms the camera where a scene asks for it, joins the scenes with transitions and encodes
an H.264 MP4 for the web (1920×1080, 60 fps, no sound, +faststart) plus a poster frame.
"""
import json, os, subprocess, sys

W, H, FPS = 1920, 1080, 60
# the transition into a scene: (xfade name, seconds); a scene not listed comes in with DEFAULT
TRANSITIONS = {
    "copy": ("smoothleft", 0.45),
    "drag": ("smoothup", 0.45),
    "archive": ("circleopen", 0.5),
    "tools": ("smoothleft", 0.45),
    "many": ("smoothright", 0.45),
    "tabs": ("slideup", 0.45),
    "twoPanel": ("slideleft", 0.45),
    "tree": ("smoothdown", 0.45),
    "dark": ("fade", 0.6),          # light dissolving into dark
    "buttons": ("circleclose", 0.5),
    "card": ("zoomin", 0.6),
}
DEFAULT = ("smoothleft", 0.45)
ZOOM, ZOOM_IN, ZOOM_OUT = 1.3, 0.7, 0.6


def scenes(markers):
    """[(name, start, end, zooms)] where zooms are (start, end, fx, fy) relative to the scene."""
    out, current = [], None
    for m in markers:
        if m["kind"] == "scene":
            current = {"name": m["name"], "start": m["t"], "zooms": []}
        elif m["kind"] == "zoom" and current:
            current["zooms"].append([m["t"] - current["start"], None, m["fx"], m["fy"]])
        elif m["kind"] == "zoomEnd" and current and current["zooms"]:
            current["zooms"][-1][1] = m["t"] - current["start"]
        elif m["kind"] == "end" and current:
            out.append((current["name"], current["start"], m["t"], current["zooms"]))
            current = None
    return out


def ease(u):
    u = f"clip({u},0,1)"
    return f"({u}*{u}*(3-2*{u}))"


def camera(zooms):
    """A zoompan that is 1:1 outside the zooms and eases into ZOOM around (fx, fy) inside them."""
    if not zooms:
        return f"scale={W}:{H}:flags=lanczos"
    start, end, fx, fy = zooms[0]
    ramp = f"({ease(f'(it-{start:.3f})/{ZOOM_IN}')}-{ease(f'(it-{end:.3f})/{ZOOM_OUT}')})"
    z = f"1+{ZOOM - 1}*{ramp}"
    x = f"max(0,min(iw-iw/zoom,{fx:.4f}*iw-iw/zoom/2))"
    y = f"max(0,min(ih-ih/zoom,{fy:.4f}*ih-ih/zoom/2))"
    # upscaled first, so the whole-pixel steps of zoompan are a quarter pixel in the result
    return (f"scale={W * 2}:{H * 2}:flags=lanczos,"
            f"zoompan=z='{z}':x='{x}':y='{y}':d=1:s={W}x{H}:fps={FPS}")


def main():
    raw, out = sys.argv[1], sys.argv[2]
    meta = json.load(open(os.path.splitext(raw)[0] + ".markers.json"))
    parts = scenes(meta["markers"])
    filters, labels = [], []
    for i, (name, start, end, zooms) in enumerate(parts):
        filters.append(f"[0:v]trim=start={start:.3f}:end={end:.3f},setpts=PTS-STARTPTS,fps={FPS},"
                       f"{camera(zooms)},setsar=1,format=yuv420p,settb=AVTB[s{i}]")
        labels.append((f"s{i}", end - start, name))
    # join with transitions
    current, length, _ = labels[0]
    for i, (label, duration, name) in enumerate(labels[1:]):
        kind, seconds = TRANSITIONS.get(name, DEFAULT)
        offset = length - seconds
        filters.append(f"[{current}][{label}]xfade=transition={kind}:duration={seconds}:offset={offset:.3f}[x{i}]")
        current, length = f"x{i}", offset + duration
    filters.append(f"[{current}]null[v]")   # the end card fades to the bare desktop the video starts on: it loops
    cmd = ["ffmpeg", "-v", "error", "-y", "-i", raw, "-filter_complex", ";".join(filters), "-map", "[v]",
           "-c:v", "libx264", "-preset", "slow", "-crf", "19", "-profile:v", "high", "-pix_fmt", "yuv420p",
           "-movflags", "+faststart", "-an", out]
    subprocess.run(cmd, check=True)
    poster = os.path.splitext(out)[0] + "-poster.jpg"
    first_scene = labels[0][1]
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{first_scene - 0.6:.2f}", "-i", out, "-frames:v", "1",
                    "-q:v", "3", poster], check=True)
    print(f"wrote {out} ({length:.1f} s) and {os.path.basename(poster)}")


if __name__ == "__main__":
    main()
