#!/usr/bin/env python3
"""
export_coreml.py - turn your trained ball model (best.pt) into a model the
iPhone app can run (BallDetector.mlpackage).

Core ML export does NOT work on Windows. Run this on a Mac, on Linux, or in
Google Colab (free, in the browser):

    pip install ultralytics coremltools
    python export_coreml.py best.pt

Options:
    python export_coreml.py best.pt 1280     model input width (default 1280)
    python export_coreml.py best.pt 960      smaller = faster on the phone, worse on far balls

Then copy the BallDetector.mlpackage FOLDER to the iPhone:
    Files app > On My iPhone > RugbyCam
(or with a USB cable: Apple Devices / iTunes on Windows > your iPhone > Files >
RugbyCam), and tap "Look for model files again" in the app's settings.

NOTE: this script was written without being run, because the tools it needs
could not be installed where the app was written. If the export fails, send
the error message.
"""

import math
import os
import shutil
import sys


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else "best.pt"
    width = int(sys.argv[2]) if len(sys.argv) > 2 else 1280
    if not os.path.exists(source):
        sys.exit("Cannot find %s. Give the path to your trained best.pt." % source)

    try:
        from ultralytics import YOLO
    except ImportError:
        sys.exit("Install the tools first:  pip install ultralytics coremltools")

    # The camera picture is 16:9. Model sizes must be multiples of 32.
    width = int(math.ceil(width / 32.0) * 32)
    height = int(math.ceil(width * 9.0 / 16.0 / 32.0) * 32)
    print("Exporting %s for a %d x %d picture" % (source, width, height))

    model = YOLO(source)
    # nms=True makes the model report finished boxes, which is what the app expects.
    # half=True stores 16-bit numbers: half the file size, same accuracy in practice.
    exported = model.export(format="coreml", nms=True, imgsz=(height, width), half=True)

    target = "BallDetector.mlpackage"
    if os.path.abspath(str(exported)) != os.path.abspath(target):
        if os.path.exists(target):
            shutil.rmtree(target)
        shutil.move(str(exported), target)
    print()
    print("Done:", os.path.abspath(target))
    print("Copy that whole folder to the iPhone: Files > On My iPhone > RugbyCam")


if __name__ == "__main__":
    main()
