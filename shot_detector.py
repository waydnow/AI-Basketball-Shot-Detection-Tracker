# Avi Shah - Basketball Shot Detector/Tracker - July 2023
# Rendering and inference wrapper; the shot decision logic lives in shot_logic.py.

import argparse
import os

import cv2
import cvzone
import numpy as np
from ultralytics import YOLO

from shot_logic import ShotTracker
from utils import get_device


class ShotDetector:
    def __init__(self, source="video_test_5.mp4", output_path=None, stride=1, show=True):
        self.model = YOLO("best.pt")
        self.class_names = ['Basketball', 'Basketball Hoop']
        self.device = get_device()

        # Video file path, or webcam index (e.g. 0)
        self.source = source
        self.cap = cv2.VideoCapture(source)
        self.stride = max(1, int(stride))

        fps = self.cap.get(cv2.CAP_PROP_FPS)
        self.tracker = ShotTracker(fps=fps if fps and fps < 1000 else 30.0)

        # When set, annotated frames are written to this file instead of an on-screen window
        self.output_path = output_path
        self.writer = None
        self.show = show

        self.frame = None
        self.overlay_text = "Waiting..."
        self.overlay_color = (0, 0, 0)
        self.fade_frames = 20
        self.fade_counter = 0

        self.run()

    def run(self):
        if self.output_path:
            # VideoWriter fails silently when the target directory is missing
            os.makedirs(os.path.dirname(os.path.abspath(self.output_path)), exist_ok=True)
            width = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            height = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            self.writer = cv2.VideoWriter(self.output_path, cv2.VideoWriter_fourcc(*"mp4v"),
                                          self.cap.get(cv2.CAP_PROP_FPS), (width, height))

        frame_index = -1
        while True:
            ret, self.frame = self.cap.read()
            if not ret:
                break
            frame_index += 1
            if frame_index % self.stride != 0:
                continue

            detections = []
            for r in self.model(self.frame, stream=True, device=self.device):
                for box in r.boxes:
                    x1, y1, x2, y2 = (int(v) for v in box.xyxy[0])
                    w, h = x2 - x1, y2 - y1
                    detections.append((int(box.cls[0]), x1 + w // 2, y1 + h // 2,
                                       w, h, float(box.conf[0])))

            events = self.tracker.add_frame(frame_index, detections)
            for event in events:
                self.overlay_text = "Make" if event["type"] == "make" else "Miss"
                self.overlay_color = (0, 255, 0) if event["type"] == "make" else (255, 0, 0)
                self.fade_counter = self.fade_frames

            self.draw()

            if self.writer:
                self.writer.write(self.frame)
                continue

            if self.show:
                cv2.imshow('Frame', self.frame)
                if cv2.waitKey(1) & 0xFF == ord('q'):
                    break

        self.cap.release()
        if self.writer:
            self.writer.release()
        print(f"{self.tracker.makes} / {self.tracker.attempts} "
              f"({'%.1f' % (self.tracker.makes * 100.0 / self.tracker.attempts) if self.tracker.attempts else '0.0'}%)"
              f"{(' -> ' + self.output_path) if self.output_path else ''}")
        for event in self.tracker.events:
            print(f"  {event['t_us'] / 1e6:7.2f}s  frame {event['frame']:5d}  {event['type']}")
        cv2.destroyAllWindows()

    def draw(self):
        for point in self.tracker.frame_balls + self.tracker.frame_hoops:
            (cx, cy), _, w, h, _ = point
            cvzone.cornerRect(self.frame, (cx - w // 2, cy - h // 2, w, h))

        for point in self.tracker.ball_pos:
            cv2.circle(self.frame, point[0], 2, (0, 0, 255), 2)

        if len(self.tracker.hoop_pos) > 1:
            cv2.circle(self.frame, self.tracker.hoop_pos[-1][0], 2, (128, 128, 0), 2)

        text = f"{self.tracker.makes} / {self.tracker.attempts}"
        cv2.putText(self.frame, text, (50, 125), cv2.FONT_HERSHEY_SIMPLEX, 3, (255, 255, 255), 6)
        cv2.putText(self.frame, text, (50, 125), cv2.FONT_HERSHEY_SIMPLEX, 3, (0, 0, 0), 3)

        if self.fade_counter > 0:
            alpha = 0.2 * (self.fade_counter / self.fade_frames)
            self.frame = cv2.addWeighted(self.frame, 1 - alpha,
                                         np.full_like(self.frame, self.overlay_color), alpha, 0)
            self.fade_counter -= 1
            if self.fade_counter == 0:
                # Without this the last shot's verdict stays on screen until the next one.
                self.overlay_text = "Waiting..."
        elif self.overlay_text != "Waiting...":
            self.overlay_text = "Waiting..."

        if self.overlay_text != "Waiting...":
            (text_width, _), _ = cv2.getTextSize(self.overlay_text, cv2.FONT_HERSHEY_SIMPLEX, 3, 6)
            cv2.putText(self.frame, self.overlay_text, (self.frame.shape[1] - text_width - 40, 100),
                        cv2.FONT_HERSHEY_SIMPLEX, 3, self.overlay_color, 6)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Detect basketball shots in a video or from a webcam.")
    parser.add_argument("--video", default="video_test_5.mp4", help="input video path")
    parser.add_argument("--webcam", type=int, metavar="INDEX", help="use a webcam instead of a video")
    parser.add_argument("--output", help="write annotated frames to this file instead of a window")
    parser.add_argument("--stride", type=int, default=1, help="analyse every Nth frame")
    parser.add_argument("--no-window", action="store_true", help="process without opening a window")
    args = parser.parse_args()

    source = args.webcam if args.webcam is not None else args.video
    ShotDetector(source, args.output, args.stride, show=not args.no_window)
