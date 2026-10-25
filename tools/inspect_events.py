"""Render a contact sheet of every detected event, cropped around the hoop, so make/miss
verdicts can be checked by eye. Tuning the scoring rule without this is guesswork.

  python tools/inspect_events.py video_test_5.mp4
  open fixtures/inspection_video_test_5_sheet1.png
"""

import argparse
import json
import os
import sys

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "fixtures")
OFFSETS = [-14, -10, -6, -2, 2, 6]   # frames around the "ball below the net" frame
PER_SHEET = 6
KEEP = {"all": None, "make": {"make"}, "miss": {"miss"}}
BALL = 0
TRAIL = 6                            # frames of ball history drawn behind each tile


def sheet(video, events_json, detections_json, prefix, only="all", indices=None):
    with open(events_json) as f:
        data = json.load(f)
    with open(detections_json) as f:
        det = json.load(f)
    balls = {fr["i"]: [d for d in fr["d"] if d[0] == BALL] for fr in det["frames"]}

    cap = cv2.VideoCapture(video)
    fps = data["fps"]
    types = KEEP[only]
    tiles = []

    for n, e in enumerate(data["events"]):
        if types is not None and e["type"] not in types:
            continue
        if indices is not None and n not in indices:
            continue
        hx, hy, hw, hh = e["hoop"]
        rim_y = hy - 0.5 * hh
        rim_x1, rim_x2 = hx - 0.4 * hw, hx + 0.4 * hw
        net_y = rim_y + hh
        # Tight crop on the rim, so the ball's path through the opening is unambiguous.
        x1, x2 = int(hx - 1.2 * hw), int(hx + 1.2 * hw)
        y1, y2 = int(rim_y - 1.3 * hh), int(rim_y + 1.6 * hh)
        row = []
        for off in OFFSETS:
            frame_no = e["frame"] + off
            cap.set(cv2.CAP_PROP_POS_FRAMES, frame_no)
            ret, frame = cap.read()
            if not ret:
                continue
            crop = frame[max(0, y1):y2, max(0, x1):x2].copy()
            scale = 300 / crop.shape[1]
            crop = cv2.resize(crop, None, fx=scale, fy=scale, interpolation=cv2.INTER_LINEAR)

            def pt(x, y):
                return (int((x - x1) * scale), int((y - y1) * scale))

            # Mark the rim opening the detector accepts, the rim plane it tests, and the net
            # bottom the ball must still be inside.
            for edge in (rim_x1, rim_x2):
                cv2.line(crop, pt(edge, y1), pt(edge, y2), (0, 200, 0), 1)
            cv2.line(crop, pt(rim_x1, net_y), pt(rim_x2, net_y), (255, 0, 255), 1)
            cv2.line(crop, pt(x1, rim_y), pt(x2, rim_y), (0, 255, 255), 1)
            # Draw what the model actually saw, so a wrong verdict traces to a bad detection
            # rather than to the rule.
            for k in range(frame_no - TRAIL, frame_no + 1):
                for _, bx, by, _bw, _bh, _c in balls.get(k, []):
                    now = k == frame_no
                    cv2.circle(crop, pt(bx, by), 5 if now else 2,
                               (0, 0, 255) if now else (255, 255, 0), -1 if now else 1)
            label = f"#{n} {e['type']} f{frame_no}"
            crop = cv2.copyMakeBorder(crop, 20, 0, 0, 0, cv2.BORDER_CONSTANT, value=(0, 0, 0))
            cv2.putText(crop, label, (3, 15), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 255, 255), 1)
            row.append(crop)
        if row:
            height = max(t.shape[0] for t in row)
            row = [cv2.copyMakeBorder(t, 0, height - t.shape[0], 0, 0, cv2.BORDER_CONSTANT, value=(0, 0, 0))
                   for t in row]
            tiles.append(np.hstack(row))
    cap.release()

    for s in range(0, len(tiles), PER_SHEET):
        block = tiles[s:s + PER_SHEET]
        width = max(t.shape[1] for t in block)
        block = [cv2.copyMakeBorder(t, 0, 0, 0, width - t.shape[1], cv2.BORDER_CONSTANT, value=(0, 0, 0))
                 for t in block]
        out = os.path.join(FIXTURES, f"{prefix}_sheet{s // PER_SHEET + 1}.png")
        cv2.imwrite(out, np.vstack(block))
        print(out)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("video", nargs="?", default=os.path.join(ROOT, "video_test_5.mp4"))
    parser.add_argument("--only", choices=sorted(KEEP), default="all")
    parser.add_argument("--events", default=None, help="comma-separated event indices to render")
    args = parser.parse_args()
    stem = os.path.splitext(os.path.basename(args.video))[0]
    indices = None if args.events is None else {int(v) for v in args.events.split(",")}
    sheet(args.video, os.path.join(FIXTURES, f"{stem}_events.json"),
          os.path.join(FIXTURES, f"{stem}_detections.json"), f"inspection_{stem}",
          args.only, indices)
