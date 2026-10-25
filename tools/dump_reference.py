"""Generate the golden files that the Dart port is validated against.

Two stages, so algorithm tuning never re-runs inference:

  python tools/dump_reference.py infer  video_test_5.mp4     # slow: YOLO over every frame
  python tools/dump_reference.py replay                       # instant: re-run the state machine

`infer` writes fixtures/<stem>_detections.json holding raw, unfiltered boxes (above a low
confidence floor) in original-frame coordinates, so both implementations apply identical gating.
`replay` feeds those boxes to shot_logic.ShotTracker and writes fixtures/<stem>_events.json.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

CONF_FLOOR = 0.05
FIXTURES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "fixtures")


def stem(path):
    return os.path.splitext(os.path.basename(path))[0]


def detections_path(video):
    return os.path.join(FIXTURES, f"{stem(video)}_detections.json")


def events_path(video):
    return os.path.join(FIXTURES, f"{stem(video)}_events.json")


def infer(video, stride, device):
    import cv2
    from ultralytics import YOLO

    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        sys.exit(f"cannot open {video}")

    fps = cap.get(cv2.CAP_PROP_FPS)
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    model = YOLO(os.path.join(os.path.dirname(FIXTURES), "best.pt"))
    frames = []
    index = -1
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        index += 1
        if index % stride != 0:
            continue
        boxes = []
        for r in model(frame, stream=True, device=device, verbose=False):
            for box in r.boxes:
                conf = float(box.conf[0])
                if conf < CONF_FLOOR:
                    continue
                x1, y1, x2, y2 = (int(v) for v in box.xyxy[0])
                w, h = x2 - x1, y2 - y1
                boxes.append([int(box.cls[0]), x1 + w // 2, y1 + h // 2, w, h, round(conf, 4)])
        frames.append({"i": index, "d": boxes})
        if index % 500 == 0:
            print(f"  {index} frames", flush=True)
    cap.release()

    os.makedirs(FIXTURES, exist_ok=True)
    payload = {
        "video": os.path.basename(video),
        "fps": round(fps, 6),
        "width": width,
        "height": height,
        "analyzed_frames": len(frames),
        "stride": stride,
        "conf_floor": CONF_FLOOR,
        "frames": frames,
    }
    with open(detections_path(video), "w") as f:
        json.dump(payload, f)
    print(f"wrote {detections_path(video)} ({payload['analyzed_frames']} frames)")


def replay(video, params, quiet=False, explain=False):
    from shot_logic import ShotTracker

    with open(detections_path(video)) as f:
        data = json.load(f)

    tracker = ShotTracker(fps=data["fps"], explain=explain, **params)
    for frame in data["frames"]:
        tracker.add_frame(frame["i"], [tuple(d) for d in frame["d"]])

    payload = {
        "video": data["video"],
        "fps": data["fps"],
        "tracker_params": params,
        "makes": tracker.makes,
        "attempts": tracker.attempts,
        "events": tracker.events,
    }
    with open(events_path(video), "w") as f:
        json.dump(payload, f, indent=1)

    if not quiet:
        rate = tracker.makes * 100.0 / tracker.attempts if tracker.attempts else 0.0
        print(f"{tracker.makes} / {tracker.attempts} ({rate:.1f}%) -> {events_path(video)}")
        for event in tracker.events:
            print(f"  {event['t_us'] / 1e6:7.2f}s  frame {event['frame']:5d}  {event['type']}")
            if explain:
                print(f"           {event['why']}")
    return payload


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("stage", choices=["infer", "replay", "all"])
    parser.add_argument("video", nargs="?", default="video_test_5.mp4")
    parser.add_argument("--stride", type=int, default=1, help="analyse every Nth frame (inference only)")
    parser.add_argument("--device", default=None, help="cpu / mps / cuda (default: auto)")
    parser.add_argument("--ball-conf", type=float, default=0.3)
    parser.add_argument("--ball-conf-near-hoop", type=float, default=0.15)
    parser.add_argument("--hoop-conf", type=float, default=0.5)
    parser.add_argument("--attempt-cooldown-s", type=float, default=1.5)
    parser.add_argument("--explain", action="store_true",
                        help="print why each event scored make/miss (not written to the golden)")
    args = parser.parse_args()

    from utils import get_device
    params = {
        "ball_conf": args.ball_conf,
        "ball_conf_near_hoop": args.ball_conf_near_hoop,
        "hoop_conf": args.hoop_conf,
        "attempt_cooldown_s": args.attempt_cooldown_s,
    }

    if args.stage in ("infer", "all"):
        infer(args.video, args.stride, args.device or get_device())
    if args.stage in ("replay", "all"):
        replay(args.video, params, explain=args.explain)
