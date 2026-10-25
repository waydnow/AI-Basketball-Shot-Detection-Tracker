"""Export best.pt to ONNX and prove the exported graph reproduces the PyTorch detections.

The Android app runs the ONNX file through ONNX Runtime Mobile, so any numeric drift introduced
by the export would silently change every shot marker. This script samples frames from a video,
runs both paths with identical pre/post-processing, and reports the worst per-frame difference.

  python tools/export_onnx.py video_test_5.mp4 --frames 40
"""

import argparse
import os
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from ultralytics.data.augment import LetterBox
from ultralytics.nn.autobackend import check_class_names
from ultralytics.utils.ops import non_max_suppression, scale_boxes
from ultralytics import YOLO

IMGsz = 640
CONF = 0.05   # low floor on purpose: the shot logic cares about weak near-hoop detections too
IOU = 0.7


def preprocess(frame, letterbox):
    img = letterbox(image=frame)
    img = img[..., ::-1].transpose(2, 0, 1)
    return np.ascontiguousarray(img)[None].astype(np.float32) / 255.0


def to_boxes(ort_boxes, img_shape, original_shape, names):
    """ORT output is [1, 4+nc, anchors]; turn it into original-frame boxes like ultralytics does."""
    pred = np.transpose(np.asarray(ort_boxes)[0], (1, 0))
    keep = pred[:, 4:].max(axis=1) > CONF
    pred = pred[keep]
    if pred.shape[0] == 0:
        return []
    nms = non_max_suppression(pred[:, :4], pred[:, 4:], 0.5, IOU, single_cls=len(names) == 1)[0]
    out = []
    for det in nms.cpu().numpy():
        x1, y1, x2, y2 = scale_boxes(img_shape, det[:4], original_shape).tolist()
        out.append((int(det[5]), x1, y1, x2, y2, float(det[4])))
    return out


def iou(a, b):
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    inter = max(0, min(ax2, bx2) - max(ax1, bx1)) * max(0, min(ay2, by2) - max(ay1, by1))
    union = (ax2 - ax1) * (ay2 - ay1) + (bx2 - bx1) * (by2 - by1) - inter
    return inter / union if union > 0 else 0.0


def compare(torch_boxes, onnx_boxes):
    """Greedy match by class + IoU; return (matched, worst_iou_gap, worst_conf_gap, missed, extra)."""
    onnx_left = list(onnx_boxes)
    matched, worst_iou, worst_conf, missed = 0, 0.0, 0.0, 0
    for tb in torch_boxes:
        best, best_iou = None, 0.0
        for i, ob in enumerate(onnx_left):
            if ob[0] != tb[0]:
                continue
            v = iou(tb[1:5], ob[1:5])
            if v > best_iou:
                best, best_iou = i, v
        if best is None or best_iou < 0.5:
            missed += 1
            continue
        ob = onnx_left.pop(best)
        matched += 1
        worst_iou = max(worst_iou, 1.0 - best_iou)
        worst_conf = max(worst_conf, abs(ob[5] - tb[5]))
    return matched, worst_iou, worst_conf, missed, len(onnx_left)


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
        YOLO(args.weights).export(format="onnx", imgsz=IMGsz, opset=17, simplify=True, dynamic=False)

    import onnxruntime as ort

    names = check_class_names(YOLO(args.weights).names)
    providers = ["CPUExecutionProvider"]
    session = ort.InferenceSession(onnx_path, providers=providers)
    input_name = session.get_inputs()[0].name
    letterbox = LetterBox(new_shape=(IMGsz, IMGsz))

    cap = cv2.VideoCapture(args.video)
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    torch_model = YOLO(args.weights)

    totals = [0, 0.0, 0.0, 0, 0]
    for k in range(args.frames):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(k * total / args.frames))
        ret, frame = cap.read()
        if not ret:
            break

        tb = []
        for r in torch_model(frame, verbose=False, conf=CONF, iou=IOU, device="cpu")[0]:
            for box in r.boxes:
                x1, y1, x2, y2 = box.xyxy[0].tolist()
                tb.append((int(box.cls[0]), x1, y1, x2, y2, float(box.conf[0])))

        blob = preprocess(frame, letterbox)
        ob = to_boxes(session.run(None, {input_name: blob})[0], blob.shape[2:], frame.shape[:2], names)

        stats = compare(tb, ob)
        totals = [a + b for a, b in zip(totals, stats)]
        print(f"  frame {k:3d}: torch={len(tb):2d} onnx={len(ob):2d} "
              f"matched={stats[0]:2d} iou_gap={stats[1]:.4f} conf_gap={stats[2]:.4f}", flush=True)
    cap.release()

    matched, worst_iou, worst_conf, missed, extra = totals
    print(f"\n{onnx_path}  ({os.path.getsize(onnx_path) / 1e6:.1f} MB)")
    print(f"matched={matched} missed={missed} extra={extra} "
          f"worst_iou_gap={worst_iou:.4f} worst_conf_gap={worst_conf:.4f}")
    ok = missed == 0 and extra == 0 and worst_iou < 0.01 and worst_conf < 0.01
    print("PASS: ONNX export is numerically equivalent" if ok else "FAIL: investigate before using on-device")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
