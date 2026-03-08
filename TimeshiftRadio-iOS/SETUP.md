# TimeshiftRadio iOS — Setup Guide

## Prerequisites
- Xcode 15+ installed
- Apple Developer account (free account works for running on your own device via USB)

---

## Step 1 — Create the Xcode project

1. Open **Xcode → File → New → Project**
2. Choose **iOS → App**
3. Fill in:
   - Product Name: `TimeshiftRadio`
   - Team: your Apple ID
   - Bundle Identifier: `com.yourname.TimeshiftRadio`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Uncheck "Include Tests"
4. Save it inside this `TimeshiftRadio-iOS/` folder

---

## Step 2 — Replace/add source files

Delete the auto-generated `ContentView.swift` Xcode creates.

Drag all these files from this folder into the Xcode project navigator (choose **"Copy items if needed"** → **"Add to target: TimeshiftRadio"**):

- `TimeshiftRadio/TimeshiftRadioApp.swift`
- `TimeshiftRadio/ContentView.swift`
- `TimeshiftRadio/Models.swift`
- `TimeshiftRadio/RadioAPI.swift`
- `TimeshiftRadio/PlayerViewModel.swift`

---

## Step 3 — Configure Info.plist

In Xcode, open your project's `Info.plist` and add:

| Key | Type | Value |
|-----|------|-------|
| Required background modes | Array | Item 0: `App plays audio or streams audio/video using AirPlay` |
| App Transport Security Settings | Dictionary | Allow Arbitrary Loads = YES |

Or replace the generated `Info.plist` with the one in this folder.

---

## Step 4 — Set Background Audio capability

1. Click your project in the navigator → select the **TimeshiftRadio** target
2. Go to **Signing & Capabilities** tab
3. Click **+ Capability** → add **Background Modes**
4. Check **Audio, AirPlay, and Picture in Picture**

---

## Step 5 — Update the backend URL

Open `TimeshiftRadio/RadioAPI.swift` and update line 7:

```swift
static var baseURL = "https://YOUR-APP-NAME.onrender.com"
```

Replace with your actual Render URL (from the Render deploy step).

---

## Step 6 — Run on your iPhone

1. Plug in your iPhone via USB
2. Select your device in the Xcode toolbar
3. Press **Run (⌘R)**
4. First time: go to **iPhone Settings → General → VPN & Device Management** and trust your developer certificate

---

## Features
- All 8 DR channels (P1–P8 Jazz)
- Background playback — audio continues when you lock the screen
- Lock screen / Control Center controls
- Auto-refreshes every 3 minutes to track show changes
- Dark mode
