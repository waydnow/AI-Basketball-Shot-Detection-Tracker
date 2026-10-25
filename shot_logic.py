"""Shot state machine, free of cv2/torch so it can be replayed from stored detections.

This is the reference implementation the Dart port in flutter_app/ is validated
against (see tools/dump_reference.py and flutter_app/test/parity_test.dart).
Everything here works on integer pixel coordinates and frame indices.
"""

import math

from utils import score, detect_down, detect_up, in_hoop_region, clean_ball_pos, clean_hoop_pos

BALL = 0
HOOP = 1


class ShotTracker:
    """Feed one frame of detections at a time with add_frame(); it returns shot events.

    A point tuple is ((x, y), frame, w, h, conf) throughout, matching the reference.
    Hoop points are appended before ball points so that a frame's own hoop detection
    is visible to the ball's near-hoop confidence test, making the result independent
    of the order YOLO happens to emit boxes in.
    """

    def __init__(self, fps=30.0, ball_conf=0.3, ball_conf_near_hoop=0.15, hoop_conf=0.5,
                 attempt_cooldown_s=1.5, explain=False):
        self.fps = fps
        self.ball_conf = ball_conf
        self.ball_conf_near_hoop = ball_conf_near_hoop
        self.hoop_conf = hoop_conf
        self.cooldown_frames = max(1, int(round(attempt_cooldown_s * fps)))
        self.explain = explain

        self.ball_pos = []
        self.hoop_pos = []

        self.makes = 0
        self.attempts = 0
        self.events = []

        self.up = False
        self.down = False
        self.up_frame = 0
        self.down_frame = 0
        self.last_attempt_frame = None

        self.frame_balls = []
        self.frame_hoops = []

    def add_frame(self, frame_index, detections):
        """detections: iterable of (class_id, center_x, center_y, w, h, conf)."""
        balls, hoops = [], []
        for cls, cx, cy, w, h, conf in detections:
            conf = math.ceil(conf * 100) / 100
            point = ((int(cx), int(cy)), frame_index, int(w), int(h), conf)
            (balls if cls == BALL else hoops).append(point)

        self.frame_balls, self.frame_hoops = [], []

        for hoop in hoops:
            if hoop[4] > self.hoop_conf:
                self.hoop_pos.append(hoop)
                self.frame_hoops.append(hoop)

        for ball in balls:
            near_hoop = in_hoop_region(ball[0], self.hoop_pos) and ball[4] > self.ball_conf_near_hoop
            if ball[4] > self.ball_conf or near_hoop:
                self.ball_pos.append(ball)
                self.frame_balls.append(ball)

        self.ball_pos = clean_ball_pos(self.ball_pos, frame_index, self.fps)
        if len(self.hoop_pos) > 1:
            self.hoop_pos = clean_hoop_pos(self.hoop_pos, self.fps)

        return self._detect_shots(frame_index)

    def _detect_shots(self, frame_index):
        if not self.hoop_pos or not self.ball_pos:
            return []

        if not self.up and self._cooldown_over(frame_index):
            self.up = detect_up(self.ball_pos, self.hoop_pos)
            if self.up:
                self.up_frame = self.ball_pos[-1][1]

        if self.up and not self.down:
            self.down = detect_down(self.ball_pos, self.hoop_pos)
            if self.down:
                self.down_frame = self.ball_pos[-1][1]

        # The original polled this on `frame_count % 10 == 0`, which delayed every event by
        # up to 9 frames and silently dropped it whenever the sampled frames missed the gate.
        if self.up and self.down and self.up_frame < self.down_frame:
            self.up = False
            self.down = False
            self.last_attempt_frame = frame_index
            self.attempts += 1

            made, why = score(self.ball_pos, self.hoop_pos)
            event = {
                "frame": self.down_frame,
                "t_us": int(self.down_frame * 1_000_000 / self.fps),
                "type": "make" if made else "miss",
                "up_frame": self.up_frame,
                "hoop": list(self.hoop_pos[-1][0]) + [self.hoop_pos[-1][2], self.hoop_pos[-1][3]],
            }
            if self.explain:
                event["why"] = why
            if made:
                self.makes += 1
            self.events.append(event)
            return [event]

        return []

    def _cooldown_over(self, frame_index):
        return (self.last_attempt_frame is None
                or frame_index - self.last_attempt_frame >= self.cooldown_frames)
