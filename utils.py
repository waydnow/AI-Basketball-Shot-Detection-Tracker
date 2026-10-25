import math
import torch


def get_device():
    """Automatically select devices -> cuda -> mps（Mac） -> cpu"""
    if torch.cuda.is_available():
        device = 'cuda'
    elif torch.backends.mps.is_available():
        device = 'mps'
    else:
        device = 'cpu'
    return device


# The hoop box spans rim + net, with the rim at its top edge. These are expressed as
# multiples of the box so they survive a change of camera distance or resolution.
# 0.5 = the box's full width, which is the rim itself (the net tapers below it), so the
# opening is not an arbitrary shrink of the detection.
RIM_HALF_W = 0.5
NET_DEPTH = 1.0       # bottom of the net, measured down from the rim plane
X_TOLERANCE = 0.1     # slack allowed while the ball falls, for box-centre jitter


def rim_geometry(hoop):
    """Rim plane y and opening x-range of a hoop tuple ((x, y), frame, w, h, conf)."""
    hoop_x, hoop_y = hoop[0]
    hoop_w, hoop_h = hoop[2], hoop[3]
    return hoop_y - 0.5 * hoop_h, hoop_x - RIM_HALF_W * hoop_w, hoop_x + RIM_HALF_W * hoop_w


# A make is the ball centre passing down *through the cylinder* dropped from the rim opening:
# it must cross the rim plane inside the opening and stay inside it all the way to the bottom
# of the net. Crossing a single plane is not enough - a ball that grazes the right rim and
# falls away to the right still crosses that plane inside the opening.
# The previous version fitted a line through two arbitrary points and then accepted anything
# within a further +/-10px "rebound zone", which made every attempt score as a make.
def score(ball_pos, hoop_pos):
    """Return (made, reason). The reason exists so a wrong call can be traced to a bad box."""
    rim_y, rim_x1, rim_x2 = rim_geometry(hoop_pos[-1])
    hoop_w, hoop_h = hoop_pos[-1][2], hoop_pos[-1][3]
    net_y = rim_y + NET_DEPTH * hoop_h
    tolerance = X_TOLERANCE * hoop_w

    for i in reversed(range(len(ball_pos) - 1)):
        x1, y1 = ball_pos[i][0]
        x2, y2 = ball_pos[i + 1][0]
        if y1 < rim_y <= y2:  # downward crossing of the rim plane
            t = (rim_y - y1) / (y2 - y1)
            cross_x = x1 + (x2 - x1) * t
            if not rim_x1 < cross_x < rim_x2:
                return False, (f"crossed rim y={rim_y:.0f} at x={cross_x:.0f}, "
                               f"outside opening [{rim_x1:.0f},{rim_x2:.0f}]")
            # Every sample from the rim down to the first one at or past the net bottom has to
            # stay in the cylinder. Checking only the deepest sample lets a ball that falls
            # through the net in one frame (or is occluded inside it) score unchecked; checking
            # only the in-between samples lets one that exits the side of the net through.
            lo, hi = rim_x1 - tolerance, rim_x2 + tolerance
            for j in range(i + 1, len(ball_pos)):
                bx, by = ball_pos[j][0]
                if not lo < bx < hi:
                    return False, (f"drifted to x={bx:.0f} at y={by:.0f}, "
                                   f"outside cylinder [{lo:.0f},{hi:.0f}]")
                if by >= net_y:
                    break
            return True, f"stayed in the cylinder from rim y={rim_y:.0f} to net bottom y={net_y:.0f}"

    return False, f"no downward crossing of rim y={rim_y:.0f}"


# Detects if the ball is below the net - used to detect shot attempts
def detect_down(ball_pos, hoop_pos):
    hoop_x, hoop_y = hoop_pos[-1][0]
    hoop_h = hoop_pos[-1][3]
    return ball_pos[-1][0][1] > hoop_y + 0.5 * hoop_h


# Detects if the ball is above the rim, near this basket - start of a shot attempt.
# The horizontal span used to be +/-4 hoop widths, so dribbling anywhere on the
# visible half-court counted as an attempt.
def detect_up(ball_pos, hoop_pos):
    hoop_x, hoop_y = hoop_pos[-1][0]
    hoop_w, hoop_h = hoop_pos[-1][2], hoop_pos[-1][3]

    x1 = hoop_x - 1.5 * hoop_w
    x2 = hoop_x + 1.5 * hoop_w
    y1 = hoop_y - 2 * hoop_h
    y2 = hoop_y - 0.5 * hoop_h

    ball_x, ball_y = ball_pos[-1][0]
    return x1 < ball_x < x2 and y1 < ball_y < y2


# Checks if center point is near the hoop
def in_hoop_region(center, hoop_pos):
    if len(hoop_pos) < 1:
        return False
    x, y = center
    hoop_x, hoop_y = hoop_pos[-1][0]
    hoop_w, hoop_h = hoop_pos[-1][2], hoop_pos[-1][3]

    x1 = hoop_x - 1 * hoop_w
    x2 = hoop_x + 1 * hoop_w
    y1 = hoop_y - 1 * hoop_h
    y2 = hoop_y + 0.5 * hoop_h

    return x1 < x < x2 and y1 < y < y2


# Removes inaccurate data points. Windows are expressed in seconds and converted with the
# video's fps, so the filters keep working when frames are skipped during analysis.
def clean_ball_pos(ball_pos, frame_count, fps=30.0):
    jump_window = max(1, int(round(0.17 * fps)))
    history = max(1, int(round(1.0 * fps)))

    if len(ball_pos) > 1:
        w1, h1 = ball_pos[-2][2], ball_pos[-2][3]
        x1, y1 = ball_pos[-2][0]
        x2, y2 = ball_pos[-1][0]
        w2, h2 = ball_pos[-1][2], ball_pos[-1][3]
        f_dif = ball_pos[-1][1] - ball_pos[-2][1]

        dist = math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)
        max_dist = 4 * math.sqrt(w1 ** 2 + h1 ** 2)

        # Ball should not move 4x its diameter within ~0.17s
        if (dist > max_dist) and (f_dif < jump_window):
            ball_pos.pop()

        # Ball should be relatively square
        elif (w2 * 1.4 < h2) or (h2 * 1.4 < w2):
            ball_pos.pop()

    if len(ball_pos) > 0 and frame_count - ball_pos[0][1] > history:
        ball_pos.pop(0)

    return ball_pos


def clean_hoop_pos(hoop_pos, fps=30.0):
    jump_window = max(1, int(round(0.17 * fps)))
    history = max(1, int(round(0.83 * fps)))

    # Prevents jumping from one hoop to another
    if len(hoop_pos) > 1:
        x1, y1 = hoop_pos[-2][0]
        x2, y2 = hoop_pos[-1][0]
        w1, h1 = hoop_pos[-2][2], hoop_pos[-2][3]
        w2, h2 = hoop_pos[-1][2], hoop_pos[-1][3]
        f_dif = hoop_pos[-1][1] - hoop_pos[-2][1]

        dist = math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)
        max_dist = 0.5 * math.sqrt(w1 ** 2 + h1 ** 2)

        # Hoop should not move 0.5x its diameter within ~0.17s
        if dist > max_dist and f_dif < jump_window:
            hoop_pos.pop()

        # Hoop should be relatively square
        if (w2 * 1.3 < h2) or (h2 * 1.3 < w2):
            hoop_pos.pop()

    while len(hoop_pos) > history:
        hoop_pos.pop(0)

    return hoop_pos
