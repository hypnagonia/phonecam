# PhoneCam

**Your iPhone as a Mac webcam, with full control over focus, exposure and colour.**

A **PhoneCam** camera appears on the Mac in Zoom, Meet, Telegram, FaceTime, OBS and other apps. You adjust the
picture from a page in the browser. Video goes only over the USB cable or a direct Wi‑Fi link, never through the
router.

## Features

- Focus stays on your face (or click to focus); auto exposure that doesn't blow out the background
- Natural skin under coloured lights; horizon levelling; auto framing that follows you calmly, like a camera
  operator (ignores small moves and leaning in, then pans slowly)
- Colour controls: warmth, tint, saturation, contrast, HSL; presets
- Records Apple Log where the iPhone has it (15 Pro and later), so almost none of the iPhone's own picture processing,
  and develops it to Rec.709 itself: colours outside Rec.709 eased in, the contrast a screen needs, highlights that
  fade into white; the exposure follows your face. **Vibrance** makes weak colours richer
- Your own developing: a `.cube` LUT made for Apple Log footage (Apple Log in, Rec.709 out) instead of the built-in
  one; a wide manual black point for haze from a window
- The iPhone's own HDR picture, as before Apple Log, is still there on the page's **Legacy** tab
- `/set?chart=1` shows a test chart for 12 s, to check that colours arrive unchanged at the Mac camera
- **HSL auto 2:** you stand out from the room. Clothes get richer and cleaner colours, skin a warm tan (neither red
  nor green), one small colourful thing behind you becomes the accent if there is one, big coloured walls get
  calmer, milky blacks get deeper. Decided slowly from the last half minute
- Whiter teeth when your mouth is open (Teeth slider)
- 4K / 10-bit capture, sent as 1080p HEVC at 30 fps; no flicker bands; cools down when the iPhone gets hot
- Saves the iPhone: with nobody watching the camera sleeps, the screen goes dark after 10 s untouched

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

**Tips:** use the USB cable when you can; good light in front of your face matters most; keep PhoneCam in front on
the iPhone (iOS stops the camera in the background; it restarts by itself, and the menu bar icon and the control
page show why it stopped); stop the camera from the menu bar icon when you don't need it. The menu bar icon is green
while the camera works, grey when it is stopped or the phone isn't found, red when something needs your attention.

## Developers

iPhone app captures, processes and encodes HEVC → UDP → Mac menu bar app (`localhost:4747`) → camera extension
(decodes only) and the browser control page.

| Path | Role |
|---|---|
| `PhoneCam/` | iPhone app: capture, picture pipeline, encoder, UDP streamer, HTTP server, control page; `Camera+Teeth.swift` finds the mouth with Vision face landmarks |
| `mac/PhoneCamMac/` | Menu bar app: finds the phone, receives video, relays requests with the key |
| `mac/CameraExtension/` | CoreMediaIO camera extension |
| `Core/` | Shared pure logic with unit tests (`swift test --package-path Core`): stream format, UDP packets, orientation and levelling, bitrate, colour (HSL, auto accents, HSL auto 2, skin tan, auto tone), presets |
| `scripts/hooks/pre-push` | Blocks pushes with private data (`git config core.hooksPath scripts/hooks`) |

Endpoints: `/` control page · `/state`, `/set?key=value` API · `/hevc` camera stream · `/video` MJPEG (OBS
Browser Source) · `/obs` full-size video page.

Notes: signing and the key live in the git-ignored `Local.xcconfig`. An updated camera extension with the same bundle
id starts only after a reboot; to skip it, change the bundle id suffix in `project.yml` and `mac/PhoneCamMac/App.swift`.
