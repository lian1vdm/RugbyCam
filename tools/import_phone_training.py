#!/usr/bin/env python3
"""
import_phone_training.py - add the pictures you checked in the RugbyCam app to
your dataset, and train the ball model again.

Put this file in the same folder as train.py (your Downloads folder) and run,
in Command Prompt in that folder:

    python import_phone_training.py

What it does:
  1. Looks for RugbyCam-training-*.zip files in your iCloud Drive (and in the
     folder you run it from). These are made by the app: Settings > Training >
     Send checked pictures to the PC > Save to Files > iCloud Drive.
  2. Adds their pictures and labels to frames_out\\dataset (each zip only once).
  3. Keeps a copy of your current model, then trains on top of it with
     train.py (your NVIDIA card, roughly 30-90 minutes).

Options:
    python import_phone_training.py --no-train      only add the pictures
    python import_phone_training.py --epochs 60     train longer
    python import_phone_training.py --frames D:\\frames_out --icloud D:\\iCloudDrive

Nothing is uploaded anywhere.
"""

import argparse
import datetime
import glob
import os
import shutil
import subprocess
import sys
import zipfile


def find_zips(folders):
    found = []
    for folder in folders:
        if folder and os.path.isdir(folder):
            found += glob.glob(os.path.join(folder, "RugbyCam-training-*.zip"))
    # The same zip may sit in two places; keep one per name.
    unique = {}
    for path in sorted(found):
        unique.setdefault(os.path.basename(path), path)
    return list(unique.values())


def import_zip(path, dataset):
    images = os.path.join(dataset, "images")
    labels = os.path.join(dataset, "labels")
    os.makedirs(images, exist_ok=True)
    os.makedirs(labels, exist_ok=True)
    added = 0
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        label_names = {os.path.splitext(os.path.basename(n))[0]: n
                       for n in names if "/labels/" in "/" + n and n.endswith(".txt")}
        for n in names:
            if "/images/" not in "/" + n or not n.lower().endswith(".jpg"):
                continue
            base = os.path.splitext(os.path.basename(n))[0]
            if base not in label_names:
                continue          # never checked: skip
            with z.open(n) as src, open(os.path.join(images, base + ".jpg"), "wb") as dst:
                shutil.copyfileobj(src, dst)
            with z.open(label_names[base]) as src, open(os.path.join(labels, base + ".txt"), "wb") as dst:
                shutil.copyfileobj(src, dst)
            added += 1
    return added


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser()
    p.add_argument("--frames", default=os.path.join(here, "frames_out"),
                   help="your frames folder (the one that holds dataset)")
    p.add_argument("--icloud", default=os.path.join(os.path.expanduser("~"), "iCloudDrive"))
    p.add_argument("--epochs", type=int, default=40)
    p.add_argument("--no-train", action="store_true")
    a = p.parse_args()

    dataset = os.path.join(a.frames, "dataset")
    if not os.path.isdir(dataset):
        sys.exit("Cannot find %s. Use --frames to point at your frames_out folder." % dataset)

    done_list = os.path.join(dataset, "imported_phone_zips.txt")
    done = set()
    if os.path.exists(done_list):
        done = set(line.strip() for line in open(done_list, encoding="utf-8") if line.strip())

    zips = [z for z in find_zips([a.icloud, here, os.getcwd()]) if os.path.basename(z) not in done]
    total = 0
    for z in zips:
        n = import_zip(z, dataset)
        print("%s: %d pictures added" % (os.path.basename(z), n))
        total += n
        with open(done_list, "a", encoding="utf-8") as f:
            f.write(os.path.basename(z) + "\n")
    if not zips:
        print("No new RugbyCam-training zip files found in:")
        print("  ", a.icloud)
        print("  ", here)
    count = len(glob.glob(os.path.join(dataset, "images", "*.jpg")))
    phone = len(glob.glob(os.path.join(dataset, "images", "phone_*.jpg")))
    print("Dataset now: %d pictures (%d from the phone)." % (count, phone))

    if a.no_train:
        return
    if total == 0:
        answer = input("Nothing new was added. Train anyway? (y/n) ").strip().lower()
        if answer != "y":
            return

    weights = os.path.join(dataset, "runs", "ball", "weights")
    best = os.path.join(weights, "best.pt")
    start_from = "yolov8m.pt"
    if os.path.exists(best):
        # train.py writes into the same folder, so keep the current model safe first.
        stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M")
        keep = os.path.join(dataset, "model_before_%s.pt" % stamp)
        shutil.copyfile(best, keep)
        start_from = keep
        print("Your current model was copied to", keep)
        print("Training continues from it.")

    train_py = os.path.join(here, "train.py")
    if not os.path.exists(train_py):
        sys.exit("train.py must be in the same folder as this file.")
    command = [sys.executable, train_py, a.frames, "--model", start_from, "--epochs", str(a.epochs)]
    print("Running:", " ".join(command))
    result = subprocess.run(command)
    if result.returncode != 0:
        sys.exit("Training stopped with an error (see above).")

    if os.path.exists(best):
        print()
        print("New model:", best)
        if os.path.isdir(a.icloud):
            target = os.path.join(a.icloud, "best_new.pt")
            shutil.copyfile(best, target)
            print("A copy is in your iCloud Drive as best_new.pt.")
        print("Next: convert it for the iPhone (Colab, as before) and copy")
        print("BallDetector.mlmodel into Files > On My iPhone > RugbyCam.")


if __name__ == "__main__":
    main()
