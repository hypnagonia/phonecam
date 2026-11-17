# PhoneCam

**Use your iPhone as a Mac webcam with full manual camera control.**

![iOS 17+](https://img.shields.io/badge/iOS-17%2B-000000?logo=apple&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-relay%20%2B%20OBS-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)
![AVFoundation](https://img.shields.io/badge/AVFoundation-camera-0A84FF)
![OBS](https://img.shields.io/badge/OBS-virtual%20camera-302E31?logo=obsstudio&logoColor=white)
![No dependencies](https://img.shields.io/badge/dependencies-none-2EA44F)
![Output](https://img.shields.io/badge/stream-1080p%2030fps-6E40C9)

macOS Continuity Camera gives you the picture but almost no control over it: there are no focus, exposure or white balance
settings. PhoneCam runs the camera on the iPhone itself and serves a control page and an MJPEG video stream over USB or
Wi‑Fi. A small Mac app adds a **PhoneCam** camera to macOS for Zoom, Meet, Telegram, FaceTime and other apps, with no
OBS needed.

```mermaid
flowchart LR
    A["iPhone<br/>PhoneCam app<br/>camera · face detection · Core Image"] -- "USB / Wi‑Fi<br/>MJPEG + JSON" --> B["Mac<br/>PhoneCam menu bar app<br/>relay on localhost:4747"]
    B --> E["PhoneCam camera<br/>(camera extension)<br/>Zoom · Meet · Telegram · FaceTime"]
    B --> C["Browser<br/>control page"]
    B -.-> D["OBS<br/>Browser Source (optional)"]
```

## Features

| | |
|---|---|
| **Focus** | Follows your face (default), continuous auto or locked. Click the picture to focus on a point; manual distance slider |
| **Exposure** | Lock (default) keeps the metered brightness but moves the shutter to 1/30 s and lowers ISO for less noise. Also auto with EV, or manual ISO and shutter |
| **White balance** | **Skin** (default) keeps the face a natural tone under colored light. Also auto, lock, or a Kelvin slider |
| **Auto-frame** | A crop of the full picture calmly follows your face and keeps you centred, with a dead zone and slow easing |
| **Color** | Saturation, contrast, black level. Graded in sRGB on the GPU |
| **Video** | Ultra-wide / wide / tele / front lens, zoom, 720p / 1080p / 4K capture (default 4K), 30 / 60 fps, JPEG quality, rotation. The stream is always 1920×1080 |
| **Background blur** | Vision person segmentation (run in parallel, never slows the stream) with adjustable strength |
| **Reliability** | The control page and `/obs` reconnect by themselves after the app restarts. Settings persist |

## Requirements

- An iPhone on iOS 17+ and a Mac with Xcode
- An Apple developer account; a free one is enough to run the app on your own phone
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [OBS Studio](https://obsproject.com), to use PhoneCam as a webcam in other apps

## Build and install

```sh
cp Local.xcconfig.example Local.xcconfig   # set your DEVELOPMENT_TEAM and a bundle id
xcodegen generate
open PhoneCam.xcodeproj                    # pick your iPhone, press Run
```

1. On the iPhone, enable Developer Mode: Settings → Privacy & Security.
2. On first launch, allow camera and local network access.
3. Keep the app in the foreground, because iOS stops the camera in the background. The screen stays on while the app
   runs; the **Dim screen** button keeps the phone cool.

## Mac app and camera

```sh
xcodebuild -project PhoneCam.xcodeproj -scheme PhoneCamMac -destination 'platform=macOS' \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
ditto build/Build/Products/Debug/PhoneCam.app /Applications/PhoneCam.app   # system extensions install only from /Applications
open /Applications/PhoneCam.app
```

The app lives in the menu bar. It relays `localhost:4747` to the phone (USB first) and installs the **PhoneCam**
camera extension. Approve the extension once in System Settings → General → Login Items & Extensions → Camera
Extensions, then pick **PhoneCam** as the camera in any app. When the phone app is closed, the camera shows a
"no signal" card. The menu has "Start at login".

## Usage

The app shows its Wi‑Fi address, for example `http://192.168.1.20:4747`.

| Path | What |
|---|---|
| `/` | Control page with the live picture |
| `/obs` | The bare video, for an OBS Browser Source |
| `/video` | Raw MJPEG stream |
| `/state`, `/set?key=value` | JSON API used by the page |

> **USB is recommended.** Over a cable the phone also has a link-local address (`169.254.x.x`) with about 1 ms latency
> and enough bandwidth for full quality at 30 fps. Wi‑Fi works too, but may need a lower **Quality** setting.

### Relay for macOS 15+

If a browser shows "address unreachable", macOS has not given it Local Network permission. The Mac app's relay solves
this: open `http://localhost:4747`. Without the Mac app, the Python relay does the same:

```sh
python3 mac/relay.py                                   # then open http://localhost:4747
PHONECAM_HOST=My-iPhone.local python3 mac/relay.py     # if auto-discovery fails
```

### OBS (optional)

Not needed with the Mac app. To use OBS anyway:

1. Sources → **+** → **Browser**. Set the URL to `http://localhost:4747/obs`, the size to 1920×1080 and a custom frame
   rate of 30.
2. Click **Start Virtual Camera**, then pick **OBS Virtual Camera** in your call app.

## How it works

| File | Role |
|---|---|
| `PhoneCam/Camera.swift` | AVFoundation capture and device controls, face detection (`AVCaptureMetadataOutput`), Skin white balance (a feedback loop on the white balance gains, using the face's average color), auto-frame crop, Core Image grading and JPEG encoding |
| `PhoneCam/Server.swift` | Small HTTP server on Network.framework: pages, MJPEG broadcast (slow clients skip frames), JSON API |
| `PhoneCam/Page.swift` | Control page and the OBS page |
| `mac/PhoneCamMac/` | Menu bar app: localhost relay (Network.framework), camera extension installer, start at login |
| `mac/CameraExtension/` | CoreMediaIO camera extension: reads the MJPEG stream from localhost, sends 1920×1080 frames, shows a "no signal" card when the phone is gone |
| `mac/relay.py` | Optional Python relay (standard library only) for use without the Mac app |
| `scripts/hooks/pre-push` | Blocks pushes that would publish private data; enable with `git config core.hooksPath scripts/hooks` |
| `project.yml` | XcodeGen spec. Signing settings live in the git-ignored `Local.xcconfig` |
