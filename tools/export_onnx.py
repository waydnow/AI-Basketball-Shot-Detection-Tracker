"""Export best.pt to ONNX and prove the exported graph reproduces the PyTorch detections.

The Android app runs the ONNX file through ONNX Runtime Mobile on the CPU, so this compares the
PyTorch weights against an explicit CPUExecutionProvider session - the same engine the phone
uses - and reports the worst per-frame difference. Any numeric drift introduced by the export
would silently change every shot marker.

  python tools/export_onnx.py video_test_5.mp4 --frames 40
"""

import argparse
import os
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from ultralytics import YOLO
from ultralytics.data.augment import LetterBox
from ultralytics.utils.ops import non_max_suppression, scale_boxes

IMGSZ = 640
STRIDE = 32       # YOLOv8 downsamples 32x; ultralytics rounds the letterbox up to this
CONF = 0.05   # low floor on purpose: the shot logic cares about weak near-hoop detections too
IOU = 0.7


def detect_torch(model, frame):
    out = []
    for box in model(frame, verbose=False, conf=CONF, iou=IOU, device="cpu")[0].boxes:
        x1, y1, x2, y2 = box.xyxy[0].tolist()
        out.append((int(box.cls[0]), x1, y1, x2, y2, float(box.conf[0])))
    return out


def detect_onnx(session, frame):
    """Run the ONNX graph on CPU and reproduce ultralytics' post-processing.

    Deliberately not `YOLO("best.onnx")`: AutoBackend hands onnxruntime its whole provider
    list, which on a Mac puts CoreMLExecutionProvider first and runs the graph in fp16. That
    drift would be the provider's, not the export's. ONNX Runtime Mobile on Android is
    CPU/XNNPACK, so CPU is the comparison that actually predicts on-device behaviour.

    The letterbox has to use auto=True with the model stride, not a square 640x640:
    ultralytics pads .pt inference to a stride multiple (640x384 for this 16:9 source), and
    the goldens were produced that way. Feeding the graph a differently shaped input moves
    detections by more than any export error - a 0.24 confidence gap on one basketball.
    """
    import torch

    img = LetterBox(new_shape=(IMGSZ, IMGSZ), auto=True, stride=STRIDE)(image=frame)[..., ::-1].transpose(2, 0, 1)
    blob = np.ascontiguousarray(img)[None].astype(np.float32) / 255.0
    raw = session.run(None, {session.get_inputs()[0].name: blob})[0]

    # Arguments copied from ultralytics' own detect/predict.py, which passes neither
    # multi_label nor nc - anything else changes which boxes survive NMS.
    nms = non_max_suppression(torch.from_numpy(raw), CONF, IOU)
    out = []
    for det in nms[0].numpy():
        x1, y1, x2, y2 = scale_boxes(blob.shape[2:], det[:4], frame.shape[:2]).tolist()
        out.append((int(det[5]), x1, y1, x2, y2, float(det[4])))
    return out


def iou(a, b):
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    inter = max(0, min(ax2, bx2) - max(ax1, bx1)) * max(0, min(ay2, by2) - max(ay1, by1))
    union = (ax2 - ax1) * (ay2 - ay1) + (bx2 - bx1) * (by2 - by1) - inter
    return inter / union if union > 0 else 0.0


def compare(torch_boxes, onnx_boxes):
    """Match same-class pairs best-IoU first.

    Greedy per-box matching mis-pairs two basketballs in the same frame: the first torch box
    grabs the nearer-looking onnx box and the second is then forced onto the wrong one, which
    reads as a huge confidence gap that the export never caused.
    """
    pairs = sorted(
        ((iou(tb[1:5], ob[1:5]), ti, oi)
         for ti, tb in enumerate(torch_boxes)
         for oi, ob in enumerate(onnx_boxes)
         if tb[0] == ob[0] and iou(tb[1:5], ob[1:5]) >= 0.5),
        reverse=True,
    )
    used_t, used_o, worst_iou, worst_conf = set(), set(), 0.0, 0.0
    for v, ti, oi in pairs:
        if ti in used_t or oi in used_o:
            continue
        used_t.add(ti)
        used_o.add(oi)
        worst_iou = max(worst_iou, 1.0 - v)
        worst_conf = max(worst_conf, abs(torch_boxes[ti][5] - onnx_boxes[oi][5]))
    return (len(used_t), worst_iou, worst_conf,
            len(torch_boxes) - len(used_t), len(onnx_boxes) - len(used_o))


def main():
    import cv2

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("video", nargs="?", default=os.path.join(ROOT, "video_test_5.mp4"))
    parser.add_argument("--frames", type=int, default=40, help="how many frames to sample")
    parser.add_argument("--weights", default=os.path.join(ROOT, "best.pt"))
    args = parser.parse_args()

    onnx_path = os.path.splitext(args.weights)[0] + ".onnx"
    if not os.path.exists(onnx_path):
        print(f"exporting {args.weights} -> {onnx_path}")
        # dynamic=True because ultralytics letterboxes .pt inputs to a stride multiple, so a
        # fixed 640x640 graph could never reproduce the goldens for a 16:9 source.
        YOLO(args.weights).export(format="onnx", imgsz=IMGSZ, opset=17, simplify=True, dynamic=True)

    torch_model = YOLO(args.weights)

    import onnxruntime as ort

    session = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])

    cap = cv2.VideoCapture(args.video)
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    totals = [0, 0.0, 0.0, 0, 0]
    worst = (0.0, 0.0, -1)
    for k in range(args.frames):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(k * total / args.frames))
        ret, frame = cap.read()
        if not ret:
            break

        tb = detect_torch(torch_model, frame)
        ob = detect_onnx(session, frame)

        stats = compare(tb, ob)
        # matched/missed/extra accumulate; the gaps are per-frame maxima, not sums.
        totals[0] += stats[0]
        totals[1] = max(totals[1], stats[1])
        totals[2] = max(totals[2], stats[2])
        totals[3] += stats[3]
        totals[4] += stats[4]
        if stats[1] > worst[0] or stats[2] > worst[1]:
            worst = (stats[1], stats[2], k)
        print(f"  frame {k:3d}: torch={len(tb):2d} onnx={len(ob):2d} "
              f"matched={stats[0]:2d} iou_gap={stats[1]:.4f} conf_gap={stats[2]:.4f}", flush=True)
    cap.release()

    matched, worst_iou, worst_conf, missed, extra = totals
    print(f"\n{onnx_path}  ({os.path.getsize(onnx_path) / 1e6:.1f} MB)")
    print(f"matched={matched} missed={missed} extra={extra} "
          f"worst_iou_gap={worst_iou:.4f} worst_conf_gap={worst_conf:.4f} (frame {worst[2]})")
    ok = missed == 0 and extra == 0 and worst_iou < 0.01 and worst_conf < 0.01
    print("PASS: ONNX export is numerically equivalent" if ok else "FAIL: investigate before using on-device")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
