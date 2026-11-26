# RugbyCam

An iPhone app that films rugby in 4K at 60 frames per second, finds the ball and the players with your own model, zooms by itself with the phone's real lenses, turns the XbotGo Chameleon mount, and can send the picture live to YouTube.

**Read this first.** The app's code has never been compiled, because no iPhone compiler was available where it was written. Expect error messages the first time it is built. Send them back and they will be fixed. The section "What has and has not been tested" says exactly where things stand.

---

## What the app does today

| Part | State |
|---|---|
| Record 4K 60 (HEVC) with sound | Written |
| Zoom by hand: lens buttons (0.5, 1, 2, tele) and a slider | Written |
| Find the ball with your model, with a fallback to the players | Written. Needs your model converted (Step 4) |
| Auto zoom: tight play zooms in, open play zooms out | Written. Logic tested in simulation |
| Turn the Chameleon mount | **Not yet.** The mount's commands are unknown, so the app only listens to it ("tripod mode") |
| Live stream to YouTube or to your home PC | Written. This is the least certain part |

Until the mount's commands are captured, the app works like a camera on a tripod: it records, tracks and zooms, but the mount does not turn.

---

## Step 1: Build the app (no Mac needed)

GitHub can build iPhone apps on its own Macs for free.

1. Make a free account at github.com.
2. Create a new repository called `RugbyCam`. Choose **Public**. Public repositories build for free. Private ones only get a small monthly allowance of Mac build time, as far as I know. The code holds no passwords: your stream key is typed into the app, not stored here.
3. Unzip `RugbyCam-app.zip` on your PC and open the `RugbyCam-app` folder.
4. On the new repository's page, click **uploading an existing file**. Select everything inside the folder, including the `.github` folder, and drag it into the browser. Click **Commit changes**.
5. Open the **Actions** tab. A run called "Build iPhone app" starts by itself and takes about 10 to 20 minutes. If none appears, pick the workflow on the left and click **Run workflow**.
6. The run builds two versions:
   - **RugbyCam-Lite**: everything except live streaming.
   - **RugbyCam**: the full app with the streaming library.
7. A green tick means it built. Open the run, scroll to **Artifacts** and download `RugbyCam-Lite-ipa` (or `RugbyCam-ipa`). Inside the zip is the `.ipa` file, which is the app.
8. A red cross means it did not build. Open the failed job, open the step **Show only the errors**, copy the text and send it to me.

**If you have a Mac with Xcode 26 or newer:** open `RugbyCam-Lite.xcodeproj`, click the project, open *Signing & Capabilities*, pick your Apple ID as the team, change the bundle identifier to something of your own, plug in the iPhone and press Run. A free Apple ID is enough. Your 2017 MacBook Pro is probably too old for this.

## Step 2: Put the app on the iPhone (from Windows)

The `.ipa` from Step 1 is unsigned. A sideloading tool signs it with your own Apple ID and installs it. I have not tested this route myself.

**AltStore** is the one I would use. Its own guide is at <https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows>. In short:

1. Install iTunes and iCloud from Apple's website (not from the Microsoft Store), then install AltServer on the PC.
2. Connect the iPhone by cable. Click the AltServer icon near the clock, choose **Install AltStore**, and pick your iPhone.
3. On the iPhone: *Settings > General > VPN & Device Management*, trust your Apple ID. Then *Settings > Privacy & Security > Developer Mode*, switch it on and restart.
4. Get the `.ipa` onto the phone (iCloud Drive works). Open AltStore, go to **My Apps**, tap **+** and choose the file.

Things to know:

- AltStore asks for your Apple ID and password, because Apple signs the app for that account. Some people make a second Apple ID just for this.
- With a free Apple ID the app stops opening after **7 days**. Open AltStore while the PC with AltServer is on the same Wi-Fi and tap **Refresh**. Your recordings and settings are kept.
- A free Apple ID can hold three such apps at a time. AltStore is one of them.

## Step 3: First start

1. Hold or mount the phone **sideways with the charging port on the right**. The app only works in this position.
2. Allow the camera and the microphone.
3. You should see the live picture, round lens buttons and a zoom slider at the bottom, and a red record button on the right.
4. The top row shows the video format, what the tracking is doing, the mount and the stream.

## Step 4: Add your ball model

The app cannot read `best.pt`. The model has to be converted once. The conversion does not run on Windows, so use Google Colab, which is free and runs in the browser. I could not test this conversion script.

1. Go to colab.research.google.com and make a new notebook.
2. Click the folder icon on the left and upload two files: your `best.pt` (in your training folder under `runs\ball\weights\best.pt`) and `tools/export_coreml.py` from this folder.
3. Paste this into the first cell and run it:
   ```
   !pip install -q ultralytics coremltools
   !python export_coreml.py best.pt
   !zip -qr BallDetector.zip BallDetector.mlpackage
   ```
4. Download `BallDetector.zip` from the folder list and unzip it on your PC. You get a folder called `BallDetector.mlpackage`.
5. Copy that whole folder onto the iPhone into the app's own folder. With a cable: open the *Apple Devices* app (or iTunes) on Windows, pick the iPhone, open *Files*, and drag the folder onto *RugbyCam*. Without a cable: put it in iCloud Drive, then in the iPhone's Files app move it to *On My iPhone > RugbyCam*.
6. In the app: *Settings > Models > Look for model files again*. It should show the model's name and size.

Whenever you retrain, repeat this. The app does not need rebuilding.

### Ball + player model

The people detector built into iOS misses players far away. `tools/label_players.py` finds the players in all training pictures on the PC with the big `yolov8x.pt` model (whole picture plus four overlapping parts), writes them into the labels as class 1, and works out your framing examples again (`FramingLearned.json` in iCloud Drive). `train.py` then trains a model with two classes, ball and player. Convert it as above; the app sees that the model knows players and stops using the built-in detector. Copy `FramingLearned.json` into the same RugbyCam folder on the iPhone and tap *Look for model files again*.

How fast your model runs on the phone is unknown until you try it. The top row shows the time per look. If it is slow, export a smaller picture size (`!python export_coreml.py best.pt 960`) or lower *Looks per second*.

---

## Using the app

- **Record button**: starts and stops. Recordings go to Photos, or stay in *Files > RugbyCam > Recordings* if you switch Photos off. The file is closed in pieces every 10 seconds, so a crash should not lose the whole match.
- **Lens buttons and slider**: zoom by hand. Touching them switches Auto zoom off.
- **Auto zoom**: zooms in when the players bunch up and out when they spread or reach the edge of the picture. It never zooms in on one or two people, or on the ball alone.
- **Follow**: turns the mount towards the play. It does nothing until the mount's commands are known.
- **What you see drawn on the picture**: thin cyan boxes are players, the dashed green box is what the camera is framing, the red ring is the ball (orange until it has been seen twice in a row), the yellow box is where the ball search looked, and the white cross is where the camera aims.

Useful settings:

- *Only use the real lenses*: auto zoom then jumps between 0.5x, 1x, 2x and tele, and never enlarges the picture digitally in between.
- *Widest / tightest auto zoom*: the range auto zoom may use. It starts at 1x to 4x.
- *How tightly to frame the players*, *Looks per second*, *Ball search zoom*: tuning.

## The mount

In *Settings > Mount*, tap **Connect to the XbotGo mount**. Close the XbotGo app first, because the mount accepts one connection at a time. The first time, the app links to the XbotGo mount with the strongest signal and remembers it, so it will not grab another team's mount later.

The app then shows every message the mount sends in a small log. It never writes to the mount. To make the mount turn, the commands the XbotGo app sends have to be captured (Bluetooth sniffer dongle, or an Android phone's Bluetooth log). Send me the capture and I will fill in `RugbyCam/Mount/ChameleonProtocol.swift`. That is the only file that has to change.

## Live streaming

Streaming is only in the full **RugbyCam** build, not in Lite. The recording on the phone is always full quality. The stream is a smaller copy.

**Straight to YouTube (simplest):**

1. In YouTube Studio click *Create > Go live*. A new channel has to wait up to 24 hours before it may go live.
2. On the *Stream* tab copy the **Stream key**.
3. In the app: *Settings > Live stream*. The address is already YouTube's. Paste the key.
4. Start with 1080p, 60 fps, 9 Mbit/s. That needs about 12 Mbit/s of upload at the pitch. Use 720p or 30 fps if the signal is weak.
5. On the main screen tap **Go live**.

**Through your home PC (I have not run this chain):**

1. Install Tailscale on the PC and on the iPhone and sign both into the same account. This gives the PC an address the phone can reach from anywhere.
2. Run MediaMTX on the PC with its standard settings. It accepts streams on port 1935.
3. In the app set the address to `rtmp://<the PC's Tailscale address>:1935/live` and the key to `pitch`.
4. In OBS add a *Media Source*, untick *Local File*, and enter `rtmp://127.0.0.1:1935/live/pitch`. Then let OBS stream to YouTube.

The direct route has one less thing that can fail. The PC route only makes sense if you want OBS to add a scoreboard or graphics.

---

## What has and has not been tested

**Tested**

- The tracking and camera-control logic (which detection is the ball, where to aim, how far to zoom, lens steps). It was run in a simulation of a match with a moving mount: `reference/simulate.py` and `reference/test_logic.py`. The Swift files in `RugbyCam/Tracking` are a line-for-line copy of that logic.
- The two Xcode project files and `Info.plist`: checked for structure by `tools/check_project.py`.

**Not tested**

- The Swift code has never been compiled or run on a phone.
- The live-stream code uses an outside library (HaishinKit 2.2.5). Every call it makes was checked by hand against that version's source code, but it was not compiled. If only the full build fails, this is still the likely place.
- The model conversion script, the GitHub build and the AltStore install.
- How well iOS's built-in people detector finds small, distant players. If it finds too few, a separate player model can be added as `PlayerDetector.mlpackage` in the same folder as the ball model.
- Your ball model was trained on 1080p footage from the XbotGo app. On 4K pictures from this app the ball looks different in size, so expect to retrain with recordings made by this app.

## What is in this folder

| Path | What it is |
|---|---|
| `RugbyCam/` | The app's source code |
| `RugbyCam/Mount/ChameleonProtocol.swift` | Where the mount's commands go once they are known |
| `RugbyCam.xcodeproj` | The full app (with live streaming) |
| `RugbyCam-Lite.xcodeproj` | The same app without the streaming library |
| `.github/workflows/build.yml` | Tells GitHub how to build the app |
| `tools/export_coreml.py` | Converts `best.pt` for the iPhone |
| `tools/make_xcodeproj.py` | Rewrites the project files after Swift files are added or removed |
| `tools/check_project.py` | Checks the project files without a Mac |
| `reference/` | The tracking logic in Python, with its simulation and tests |
