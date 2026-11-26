#!/usr/bin/env python3
"""
label_players.py - find the players in all your training pictures with the big
YOLO model, so the next model learns players as well as the ball, and work out
your framing examples again with proper player boxes.

Put this file in the same folder as train.py (your Downloads folder) and run,
in Command Prompt in that folder:

    python label_players.py

What it does:
  1. Adds new RugbyCam-training-*.zip files from iCloud Drive (like
     import_phone_training.py does).
  2. Looks for people in every picture of frames_out\\dataset with yolov8x.pt.
     It looks at the whole picture and at four overlapping parts of it, so
     small players far away are found too. Each player is written into the
     picture's label file as class 1 (the ball stays class 0).
     The first run keeps a copy of the old labels in labels_ball_only_backup.
  3. Saves 30 pictures with the boxes drawn in frames_out\\player_check, so you
     can look at a few and see whether the players were found.
  4. Takes the frames you drew in the app (framing.jsonl in the zips), counts
     the players again in those pictures and works out how you like each
     situation framed. The result is FramingLearned.json in your iCloud Drive.
     Copy it to the iPhone (Files > On My iPhone > RugbyCam) together with the
     new model; the app reads it when you tap "Look for model files again".

Then train:   python train.py frames_out --model frames_out\\dataset\\runs\\ball\\weights\\best.pt
train.py sees the player boxes and trains a model with two classes: ball and player.

Options:
    python label_players.py --redo          look at all pictures again
    python label_players.py --conf 0.35     only surer players (default 0.30)
    python label_players.py --no-framing    skip step 4

Nothing is uploaded anywhere.
"""

import argparse
import glob
import json
import os
import random
import shutil
import sys
import zipfile

PLAYER = 1
HEIGHT_OVER_WIDTH = 9.0 / 16.0
SITUATIONS = ["open", "pile", "lineout", "kick", "breakaway"]


# ---------------------------------------------------------------- zips

def find_zips(folders):
    found = {}
    for folder in folders:
        if folder and os.path.isdir(folder):
            for path in sorted(glob.glob(os.path.join(folder, "RugbyCam-training-*.zip"))):
                found.setdefault(os.path.basename(path), path)
    return list(found.values())


def import_new_zips(dataset, zips):
    """Adds pictures from zips that were not added yet. Uses import_phone_training.py."""
    done_list = os.path.join(dataset, "imported_phone_zips.txt")
    done = set()
    if os.path.exists(done_list):
        done = set(line.strip() for line in open(done_list, encoding="utf-8") if line.strip())
    new = [z for z in zips if os.path.basename(z) not in done]
    if not new:
        return
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    try:
        import import_phone_training as importer
    except ImportError:
        sys.exit("import_phone_training.py must be in the same folder as this file.")
    for z in new:
        added = importer.import_zip(z, dataset)
        print("%s: %d pictures added" % (os.path.basename(z), added))
        with open(done_list, "a", encoding="utf-8") as f:
            f.write(os.path.basename(z) + "\n")


def save_framing_files(dataset, zips):
    """Keeps a copy of each zip's framing.jsonl in dataset\\framing."""
    folder = os.path.join(dataset, "framing")
    os.makedirs(folder, exist_ok=True)
    for path in zips:
        target = os.path.join(folder, os.path.splitext(os.path.basename(path))[0] + ".jsonl")
        if os.path.exists(target):
            continue
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                if name.endswith("framing.jsonl"):
                    with z.open(name) as src, open(target, "wb") as dst:
                        shutil.copyfileobj(src, dst)
    return sorted(glob.glob(os.path.join(folder, "*.jsonl")))


# ---------------------------------------------------------------- people

def tiles(width, height):
    """The whole picture plus four overlapping parts (left/right x top/bottom)."""
    parts = [(0, 0, width, height)]
    tw, th = int(width * 0.62), int(height * 0.62)
    if tw >= 320 and th >= 240:
        for x in (0, width - tw):
            for y in (0, height - th):
                parts.append((x, y, tw, th))
    return parts


def find_people(model, image, conf, device):
    import torch
    import torchvision

    height, width = image.shape[:2]
    boxes = []
    scores = []
    for (x0, y0, w, h) in tiles(width, height):
        crop = image[y0:y0 + h, x0:x0 + w]
        size = 1920 if (w, h) == (width, height) else 1280
        result = model.predict(crop, imgsz=size, conf=conf, classes=[0], device=device, verbose=False)[0]
        for b, s in zip(result.boxes.xyxy.tolist(), result.boxes.conf.tolist()):
            bx0, by0, bx1, by1 = b
            # Skip people cut by the edge of a part (the whole picture or another part has them whole).
            if (x0, y0, w, h) != (0, 0, width, height):
                margin = 3
                if (bx0 < margin and x0 > 0) or (by0 < margin and y0 > 0) \
                        or (bx1 > w - margin and x0 + w < width) or (by1 > h - margin and y0 + h < height):
                    continue
            boxes.append([bx0 + x0, by0 + y0, bx1 + x0, by1 + y0])
            scores.append(s)
    if not boxes:
        return []
    t = torch.tensor(boxes, dtype=torch.float32)
    keep = torchvision.ops.nms(t, torch.tensor(scores, dtype=torch.float32), 0.5).tolist()
    people = []
    for i in keep:
        x0, y0, x1, y1 = boxes[i]
        w = (x1 - x0) / width
        h = (y1 - y0) / height
        if h < 0.012 or w <= 0:
            continue      # specks
        people.append(((x0 + x1) / 2.0 / width, (y0 + y1) / 2.0 / height, w, h))
    return people


def write_labels(label_path, people):
    lines = []
    if os.path.exists(label_path):
        for line in open(label_path, encoding="utf-8"):
            parts = line.split()
            if len(parts) == 5 and parts[0] != str(PLAYER):
                lines.append(line.strip())
    for (cx, cy, w, h) in people:
        lines.append("%d %.6f %.6f %.6f %.6f" % (PLAYER, cx, cy, w, h))
    with open(label_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))


def read_players(label_path):
    """Player boxes as top-left x, y, w, h (the app's picture coordinates)."""
    players = []
    if os.path.exists(label_path):
        for line in open(label_path, encoding="utf-8"):
            parts = line.split()
            if len(parts) == 5 and parts[0] == str(PLAYER):
                cx, cy, w, h = map(float, parts[1:])
                players.append({"x": cx - w / 2.0, "y": cy - h / 2.0, "w": w, "h": h})
    return players


def draw_checks(dataset, names, out_folder, count=30):
    import cv2
    os.makedirs(out_folder, exist_ok=True)
    for old in glob.glob(os.path.join(out_folder, "*.jpg")):
        os.remove(old)
    pick = random.Random(1).sample(names, min(count, len(names)))
    for base in pick:
        image = cv2.imread(os.path.join(dataset, "images", base + ".jpg"))
        if image is None:
            continue
        height, width = image.shape[:2]
        for line in open(os.path.join(dataset, "labels", base + ".txt"), encoding="utf-8"):
            parts = line.split()
            if len(parts) != 5:
                continue
            cls = int(parts[0])
            cx, cy, w, h = map(float, parts[1:])
            p0 = (int((cx - w / 2) * width), int((cy - h / 2) * height))
            p1 = (int((cx + w / 2) * width), int((cy + h / 2) * height))
            colour = (0, 220, 255) if cls == PLAYER else (0, 0, 255)
            cv2.rectangle(image, p0, p1, colour, 2)
        cv2.imwrite(os.path.join(out_folder, base + ".jpg"), image, [cv2.IMWRITE_JPEG_QUALITY, 80])


# ---------------------------------------------------------------- framing (same maths as the app)

def centre(b):
    return (b["x"] + b["w"] / 2.0, b["y"] + b["h"] / 2.0)


def union(a, b):
    x0 = min(a["x"], b["x"])
    y0 = min(a["y"], b["y"])
    x1 = max(a["x"] + a["w"], b["x"] + b["w"])
    y1 = max(a["y"] + a["h"], b["y"] + b["h"])
    return {"x": x0, "y": y0, "w": x1 - x0, "h": y1 - y0}


def frame_distance(p, q):
    dx = p[0] - q[0]
    dy = (p[1] - q[1]) * HEIGHT_OVER_WIDTH
    return (dx * dx + dy * dy) ** 0.5


def median(values):
    s = sorted(values)
    return s[len(s) // 2] if s else 0.0


def compact_cluster(players):
    if len(players) < 2:
        return (1.0 if players else 0.0), (players[0] if players else None)
    height = median([p["h"] for p in players]) * HEIGHT_OVER_WIDTH
    radius = max(height * 2.0, 0.02)
    best, best_count = 0, -1
    for i, p in enumerate(players):
        n = sum(1 for o in players if frame_distance(centre(p), centre(o)) <= radius)
        if n > best_count:
            best, best_count = i, n
    c = centre(players[best])
    box, members = None, 0
    for o in players:
        if frame_distance(c, centre(o)) <= radius:
            box = o if box is None else union(box, o)
            members += 1
    return members / float(len(players)), box


def trimmed(players):
    if len(players) < 5:
        return players
    drop = max(1, len(players) // 10)
    by_x = sorted(players, key=lambda p: centre(p)[0])
    return by_x[drop:len(by_x) - drop]


def action_box(players, ball, situation):
    box = None
    if situation == "pile":
        box = compact_cluster(players)[1]
    if box is None:
        for p in trimmed(players):
            box = p if box is None else union(box, p)
    if ball:
        box = ball if box is None else union(box, ball)
    return box


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def lesson(action, frame):
    if frame["w"] <= 0.01 or frame["h"] <= 0.01:
        return None
    fill = clamp(max(action["w"] / frame["w"], action["h"] / frame["h"]), 0.1, 0.98)
    offset = clamp((centre(frame)[0] - centre(action)[0]) / frame["w"], -0.35, 0.35)
    return fill, offset


def learn_framing(dataset, framing_files, icloud):
    examples = []
    for path in framing_files:
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line:
                try:
                    examples.append(json.loads(line))
                except ValueError:
                    pass
    examples.sort(key=lambda e: e.get("created", ""))
    learned = {}
    used = skipped = 0
    for e in examples:
        situation = e.get("situation", "open")
        if situation not in SITUATIONS:
            continue
        players = e.get("players") or []
        if e.get("source") == "picture" and e.get("pictureID"):
            label = os.path.join(dataset, "labels", e["pictureID"] + ".txt")
            if os.path.exists(label):
                players = read_players(label)
        if len(players) < 2:
            skipped += 1
            continue
        action = action_box(players, e.get("ball"), situation)
        result = lesson(action, e["chosenFrame"]) if action else None
        if result is None:
            skipped += 1
            continue
        fill, offset = result
        m = learned.setdefault(situation, {"fill": fill, "offsetX": offset, "count": 0})
        m["count"] += 1
        step = 1.0 / min(m["count"], 12)
        m["fill"] += (fill - m["fill"]) * step
        m["offsetX"] += (offset - m["offsetX"]) * step
        used += 1

    print()
    print("Framing examples: %d used, %d without enough players." % (used, skipped))
    for s in SITUATIONS:
        if s in learned:
            m = learned[s]
            print("  %-10s action fills %3d %% of the frame, side %+.2f  (%d examples)"
                  % (s, round(m["fill"] * 100), m["offsetX"], m["count"]))
    if not learned:
        return
    target_folder = icloud if os.path.isdir(icloud) else dataset
    target = os.path.join(target_folder, "FramingLearned.json")
    with open(target, "w", encoding="utf-8") as f:
        json.dump(learned, f, indent=1)
    print("Saved", target)
    print("Copy it to the iPhone: Files > On My iPhone > RugbyCam.")


# ---------------------------------------------------------------- main

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser()
    p.add_argument("--frames", default=os.path.join(here, "frames_out"))
    p.add_argument("--icloud", default=os.path.join(os.path.expanduser("~"), "iCloudDrive"))
    p.add_argument("--model", default=os.path.join(here, "yolov8x.pt"))
    p.add_argument("--conf", type=float, default=0.30)
    p.add_argument("--redo", action="store_true")
    p.add_argument("--no-framing", action="store_true")
    a = p.parse_args()

    dataset = os.path.join(a.frames, "dataset")
    if not os.path.isdir(dataset):
        sys.exit("Cannot find %s. Use --frames to point at your frames_out folder." % dataset)

    zips = find_zips([a.icloud, here, os.getcwd()])
    import_new_zips(dataset, zips)
    framing_files = save_framing_files(dataset, zips)

    try:
        import cv2
        import torch
        from ultralytics import YOLO
    except ImportError:
        sys.exit("ultralytics / torch are not installed.")
    if not os.path.exists(a.model):
        print("%s not found; downloading yolov8x.pt." % a.model)
        a.model = "yolov8x.pt"

    labels = os.path.join(dataset, "labels")
    backup = os.path.join(dataset, "labels_ball_only_backup")
    if not os.path.isdir(backup):
        shutil.copytree(labels, backup)
        print("Old labels kept in", backup)

    done_path = os.path.join(dataset, "players_labelled.txt")
    done = set()
    if os.path.exists(done_path) and not a.redo:
        done = set(line.strip() for line in open(done_path, encoding="utf-8") if line.strip())

    names = sorted(os.path.splitext(os.path.basename(x))[0]
                   for x in glob.glob(os.path.join(dataset, "images", "*.jpg")))
    todo = [n for n in names if n not in done]
    device = 0 if torch.cuda.is_available() else "cpu"
    print("Looking for players in %d of %d pictures (%s)..."
          % (len(todo), len(names), "NVIDIA GPU" if device == 0 else "CPU, slow"))

    model = YOLO(a.model)
    total_people = 0
    with open(done_path, "a", encoding="utf-8") as done_file:
        for i, base in enumerate(todo, 1):
            image = cv2.imread(os.path.join(dataset, "images", base + ".jpg"))
            if image is None:
                continue
            people = find_people(model, image, a.conf, device)
            write_labels(os.path.join(labels, base + ".txt"), people)
            total_people += len(people)
            done_file.write(base + "\n")
            if i % 50 == 0 or i == len(todo):
                print("  %d / %d pictures, %.1f players per picture" % (i, len(todo), total_people / float(i)))

    check = os.path.join(a.frames, "player_check")
    draw_checks(dataset, names, check)
    print("Pictures to check (players yellow, ball red):", check)

    if not a.no_framing:
        learn_framing(dataset, framing_files, a.icloud)

    print()
    print("Next: python train.py %s --model %s"
          % (a.frames, os.path.join(dataset, "runs", "ball", "weights", "best.pt")))


if __name__ == "__main__":
    main()
