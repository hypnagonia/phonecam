# PhoneCam

**Your iPhone as a Mac webcam, with full control over focus, exposure and colour.**

A **PhoneCam** camera appears on the Mac in Zoom, Meet, Telegram, FaceTime, OBS and other apps. You adjust the
picture from a page in the browser. Video goes only over the USB cable or a direct Wi‑Fi link, never through the
router.

## Features

- Focus stays on your face (or click to focus); auto exposure that doesn't blow out the background
- Natural skin under coloured lights; auto framing and horizon levelling
- Colour controls: warmth, tint, saturation, contrast, HSL, looks and `.cube` LUTs; presets
- 4K / 10-bit capture, sent as 1080p HEVC at 30 fps; no flicker bands; cools down when the iPhone gets hot

## Setup

Needs iOS 17+, macOS 13+, Xcode and a free Apple developer account.

```sh
brew install xcodegen
cp Local.xcconfig.example Local.xcconfig   # Team ID, bundle id, random key
xcodegen generate
```

1. **iPhone:** open `PhoneCam.xcodeproj` → scheme `PhoneCam` → Run on your iPhone. Allow camera and local network.
2. **Mac:**

   ```sh
   xcodebuild -project PhoneCam.xcodeproj -scheme PhoneCamMac -configuration Release -destination 'platform=macOS' \
     -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
   ditto build/Build/Products/Release/PhoneCam.app /Applications/PhoneCam.app
   open /Applications/PhoneCam.app
   ```

   Then enable **PhoneCam Camera** in System Settings → General → Login Items & Extensions → Camera Extensions.
3. **Use:** keep the app open on the iPhone, pick **PhoneCam** as the camera, adjust at `http://localhost:4747`.

**Tips:** use the USB cable when you can; good light in front of your face matters most; stop the camera from the
menu bar icon when you don't need it.

## Developers

iPhone app captures, processes and encodes HEVC → UDP → Mac menu bar app (`localhost:4747`) → camera extension
(decodes only) and the browser control page.

| Path | Role |
|---|---|
| `PhoneCam/` | iPhone app: capture, picture pipeline, encoder, UDP streamer, HTTP server, control page |
| `mac/PhoneCamMac/` | Menu bar app: finds the phone, receives video, relays requests with the key |
| `mac/CameraExtension/` | CoreMediaIO camera extension |
| `Core/` | Shared logic with unit tests (`swift test --package-path Core`) |
| `scripts/hooks/pre-push` | Blocks pushes with private data (`git config core.hooksPath scripts/hooks`) |

Endpoints: `/` control page · `/state`, `/set?key=value` API · `/hevc` camera stream · `/video` MJPEG (OBS
Browser Source) · `/obs` full-size video page.

Notes: signing and the key live in the git-ignored `Local.xcconfig`. An updated camera extension with the same bundle
id starts only after a reboot; to skip it, change the bundle id suffix in `project.yml` and `mac/PhoneCamMac/App.swift`.
