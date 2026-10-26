"""Dump the references the live camera path is validated against.

The on-device pipeline (`flutter_app/lib/domain/letterbox.dart` + `yolo_post.dart`) has to
reproduce what ultralytics does to the same frame, but it sees an NV21 camera buffer instead of
a decoded BGR array, so nothing can be compared by eye. This writes, per sampled frame:

  fixtures/live_reference.json        letterbox geometry table + expected detections
  fixtures/live_frame_<i>.bin         the raw `output0` tensor, for the pure-Dart NMS test
  fixtures/live_frame_<i>.nv21.gz     the frame as the camera would deliver it, for the test
                                      that runs the real model through ONNX Runtime on the host

  python tools/dump_live_reference.py --frames 6

The NV21 buffers are OpenCV's BT.601 encoding of the same pixels the Python letterbox resized,
so feeding one through the Dart preprocessor and comparing the detections measures the whole
live path - colour maths, subsampling, padding, decode, NMS - not just one step of it.
"""

import argparse
import gzip
import json
import os
import sys

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

FIXTURES = os.path.join(ROOT, "fixtures")

from tools.export_onnx import CONF, IMGSZ, IOU, STRIDE, detect_onnx
from ultralytics.data.augment import LetterBox

GEOMETRY_SIZES = [
    (1280, 720), (1920, 1080), (640, 480), (1440, 1080), (800, 600),
    (320, 240), (1080, 1920), (720, 1280), (640, 640), (13, 7),
]


def measure_letterbox(frame_w, frame_h):
    """Read the padding ultralytics actually produced, off the padded image itself.

    The source is all zeros, so any 114 run at an edge is the `copyMakeBorder` pad and the
    interior tells us where the resized image really landed.
    """
    img = np.zeros((frame_h, frame_w, 3), np.uint8)
    out = LetterBox(new_shape=(IMGSZ, IMGSZ), auto=True, stride=STRIDE)(image=img)
    blob_h, blob_w = out.shape[:2]

    pad_row = (out == 114).all(axis=(1, 2))
    pad_col = (out == 114).all(axis=(0, 2))
    top = int(np.argmax(~pad_row)) if (~pad_row).any() else blob_h
    left = int(np.argmax(~pad_col)) if (~pad_col).any() else blob_w
    unpad_h = int((~pad_row).sum())
    unpad_w = int((~pad_col).sum())

    # A wrong reading of the formula shows up here rather than in a silent fixture.
    ratio = min(IMGSZ / frame_h, IMGSZ / frame_w)
    assert round(frame_w * ratio) == unpad_w, (frame_w, frame_h, unpad_w, ratio)
    assert round(frame_h * ratio) == unpad_h, (frame_h, frame_h, unpad_h, ratio)

    return {
        "frame_w": frame_w, "frame_h": frame_h,
        "blob_w": blob_w, "blob_h": blob_h,
        "unpad_w": unpad_w, "unpad_h": unpad_h,
        "left": left, "top": top,
        "ratio": ratio,
    }


def to_nv21(frame):
    """BGR -> NV21 (Y plane, then V,U pairs) the way an Android camera buffer is laid out."""
    i420 = cv2.cvtColor(frame, cv2.COLOR_BGR2YUV_I420)
    h, w = frame.shape[:2]
    y = i420[:h, :]
    u = i420[h : h + h // 4, :].reshape(h // 2, w // 2)
    v = i420[h + h // 4 :, :].reshape(h // 2, w // 2)
    vu = np.empty((h // 2, w), np.uint8)
    vu[:, 0::2] = v
    vu[:, 1::2] = u
    return np.concatenate([y.ravel(), vu.ravel()]).astype(np.uint8)


def rows_of(onnx_boxes):
    """Same integerisation as tools/dump_reference.py: truncate the box, then take its centre."""
    rows = []
    for cls, x1, y1, x2, y2, conf in onnx_boxes:
        ix1, iy1, ix2, iy2 = (int(v) for v in (x1, y1, x2, y2))
        w, h = ix2 - ix1, iy2 - iy1
        rows.append([int(cls), ix1 + w // 2, iy1 + h // 2, w, h, round(conf, 4)])
    return rows


def main():
    import onnxruntime as ort
    from ultralytics import YOLO

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("video", nargs="?", default=os.path.join(ROOT, "video_test_5.mp4"))
    parser.add_argument("--frames", type=int, default=6)
    parser.add_argument("--weights", default=os.path.join(ROOT, "best.pt"))
    args = parser.parse_args()

    onnx_path = os.path.splitext(args.weights)[0] + ".onnx"
    assert os.path.exists(onnx_path), f"{onnx_path} missing - run tools/export_onnx.py first"
    session = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    model = YOLO(args.weights)

    cap = cv2.VideoCapture(args.video)
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    entries = []
    for k in range(args.frames):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int((k + 0.5) * total / args.frames))
        ok, frame = cap.read()
        if not ok:
            break
        raw = session.run(None, {session.get_inputs()[0].name: blob_of(frame)})[0]
        raw.astype(np.float32).tofile(os.path.join(FIXTURES, f"live_frame_{k}.bin"))
        with gzip.open(os.path.join(FIXTURES, f"live_frame_{k}.nv21.gz"), "wb") as f:
            f.write(to_nv21(frame).tobytes())
        entries.append({
            "index": k,
            "tensor": f"live_frame_{k}.bin",
            "nv21": f"live_frame_{k}.nv21.gz",
            "detections": rows_of(detect_onnx(session, frame)),
        })
        print(f"  frame {k}: {len(entries[-1]['detections'])} boxes", flush=True)
    cap.release()

    payload = {
        "video": os.path.basename(args.video),
        "width": width,
        "height": height,
        "imgsz": IMGSZ,
        "stride": STRIDE,
        "conf_floor": CONF,
        "iou": IOU,
        "geometry": [measure_letterbox(w, h) for (w, h) in GEOMETRY_SIZES],
        "frames": entries,
    }
    path = os.path.join(FIXTURES, "live_reference.json")
    with open(path, "w") as f:
        json.dump(payload, f)
    print(f"wrote {path} ({len(entries)} frames, {len(payload['geometry'])} geometry rows)")
    return 0


def blob_of(frame):
    """The model input ultralytics would build for this frame - same call as export_onnx.py."""
    img = LetterBox(new_shape=(IMGSZ, IMGSZ), auto=True, stride=STRIDE)(image=frame)[..., ::-1].transpose(2, 0, 1)
    return np.ascontiguousarray(img)[None].astype(np.float32) / 255.0


if __name__ == "__main__":
    sys.exit(main())
