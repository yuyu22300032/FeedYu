---
name: deploy-device
description: Build FeedYu and install/launch it on a connected physical iPhone via CLI. Use when asked to deploy, "build and let me test", install on device, or when a device signing expiry (app stopped launching after ~7 days) needs a re-install.
---

# Deploy FeedYu to a connected iPhone

## Steps

1. Find the device UUID (state must be "connected", not just "paired"):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun devicectl list devices
```

2. Build (signs and embeds the FeedYuShare extension too):

```sh
xcodebuild -project FeedYu.xcodeproj -scheme FeedYu \
  -destination "platform=iOS,id=<DEVICE-UUID>" -allowProvisioningUpdates build
```

3. Install + launch. **Gotcha:** more than one `FeedYu-*` DerivedData
   directory may exist — a glob then contains two paths and install fails
   with a confusing "CoreDevice bookmark" error. Take the app path from the
   build log, or the most recently modified match:

```sh
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/FeedYu-*/Build/Products/Debug-iphoneos/FeedYu.app | head -1)
xcrun devicectl device install app --device <DEVICE-UUID> "$APP"
xcrun devicectl device process launch --device <DEVICE-UUID> com.yuyu.FeedYu
```

## Known failure modes

- **"device was not, or could not be, unlocked"** on launch → install
  succeeded; the phone is just locked. Tell the user to unlock and open
  the app manually. Not an error worth retrying.
- **Free-account signing expires after 7 days** — the installed app stops
  launching. Re-run build+install; user data survives.
- First-ever deploy needs one-time phone setup (Developer Mode, trust
  dialogs) — see docs/DEVELOPMENT.md "Deploying to a physical iPhone".
- Never deploy without running the test suite first if code changed.
