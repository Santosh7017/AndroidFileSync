# AndroidFileSync

A free, native macOS app to transfer files between your Mac and Android phone — over USB or WiFi.

No cloud. No Google account needed. Plug in via USB or connect wirelessly over WiFi.

![SwiftUI](https://img.shields.io/badge/SwiftUI-macOS%2013%2B-blue)
![Version](https://img.shields.io/badge/version-2.0.0-green)

**[📥 Download Latest Version](#installation) • [🖼️ View Preview](#screenshots)**

---

## What Can It Do?

- 📁 **Browse your phone like Finder** — Navigate folders, search, sort by name/size/type
- 🖱️ **Drag & Drop** — Drag files from your Mac straight to your phone (and back)
- 📶 **USB or WiFi** — Connect with a cable, or wirelessly over your home network
- 👁️ **Preview files** — Double-click to view images, videos, and PDFs without downloading
- 🚀 **Fast transfers** — Upload and download multiple files at the same time
- ⚠️ **Duplicate detection** — Warns you before overwriting files that already exist
- 🗑️ **Trash & Restore** — Deleted something by accident? Restore it, just like on macOS
- ✂️ **Copy, Cut, Paste** — Move files between folders on your phone with clipboard shortcuts
- 📝 **Rename & Batch operations** — Rename files, change extensions, delete in bulk
- 💾 **SD Card support** — Browse and manage files on your external SD card
- 📱 **App Manager** — Install, uninstall, disable and manage apps (System/User) on your Android device

---

## What You Need

- A Mac running **macOS 13.0 (Ventura)** or later
- An Android phone with a USB cable
- For wireless: Android 11 or later

That's it. The app comes with everything else built in.

---

## Installation

### Download (Recommended)

1. Go to [**Releases**](https://github.com/Santosh7017/AndroidFileSync/releases) and download the latest `.dmg` file
2. Open the DMG and drag **AndroidFileSync** into your **Applications** folder
3. Open **Terminal** (search for it in Spotlight) and paste this command:

   ```bash
   xattr -cr /Applications/AndroidFileSync.app
   ```

4. Launch the app — you're ready to go!

> **Why step 3?** macOS blocks apps that aren't from the App Store by default. This command tells your Mac it's safe to open. The app is fully open source — you can inspect every line of code yourself.

### Build from Source (For Developers)

```bash
git clone https://github.com/Santosh7017/AndroidFileSync.git
cd AndroidFileSync
open AndroidFileSync.xcodeproj
```

Press ⌘R in Xcode to build and run. To create a DMG: `./build-dmg.sh`


## Setting Up Your Android Phone (One-Time)

Before the app can talk to your phone, you need to enable a hidden developer setting. This only takes a minute and you only have to do it once.

> **These first two steps are required for both USB and WiFi connections.**

### Step 1: Unlock Developer Options

1. Open **Settings** on your Android phone
2. Scroll down and tap **About Phone**
3. Find **Build Number** and tap it **7 times** quickly
4. You'll see a message: _"You are now a developer!"_

> **Samsung phones:** Go to **Settings → About Phone → Software Information → Build Number**

### Step 2: Turn On USB Debugging

1. Go back to **Settings**
2. Search and Tap **Developer Options**
3. Find **USB Debugging** and turn it **ON**
4. Tap **OK** when it asks you to confirm

Now choose your connection method below:

---

### 🔌 Option A: USB Connection (Wired)

The simplest way to connect. Just plug in a cable.

1. Connect your phone to your Mac with a USB cable
2. On your phone, you'll see a prompt: **"Allow USB debugging?"**
3. Check **"Always allow from this computer"**
4. Tap **Allow**
5. Pull down the notification shade and tap the USB notification
6. Select **File Transfer / MTP**
7. Launch AndroidFileSync on your Mac — your phone will appear automatically

> **Tip:** If you don't see the "Allow USB debugging?" prompt, try unplugging and replugging the cable, or use a different USB port on your Mac.

---

### 📶 Option B: WiFi Connection (Wireless)

No cable needed. Your phone and Mac must be on the **same WiFi network**. Requires **Android 11** or later.

#### Extra Setup: Turn On Wireless Debugging

1. On your phone: go to **Settings → Developer Options**
2. Find **Wireless Debugging** and turn it **ON**
3. Tap on **Wireless Debugging** to open its settings

#### Auto-Discovery Pairing (Easiest)

1. Inside the Wireless Debugging settings, tap **Pair device with pairing code**
2. In the Mac app: click the **WiFi** button — the **Auto-Discovery** tab will automatically detect your phone and pre-fill the connection details
3. Type the **6-digit code** shown on your phone and click **Pair & Connect**

> **Got multiple phones?** A dropdown will appear letting you pick which device to connect to.

#### Advanced Pairing (Manual)

If Auto-Discovery doesn't find your phone (for example, on a corporate network or VPN):

1. Inside the Wireless Debugging settings, tap **Pair device with pairing code** — note the IP address, port, and code shown
2. In the Mac app: click the **WiFi** button → **Advanced** tab → type in the IP, port, and code manually

---

## How to Use

1. **Connect** your phone via USB or WiFi (using the steps above)
2. **Launch** AndroidFileSync — it will automatically detect your device
3. **Browse** your phone's files just like you would in Finder
4. **Drag & drop** files from your Mac into the app window to upload them
5. **Double-click** any file to preview it (images, videos, PDFs, documents)
6. **Right-click** any file for more options (Download, Rename, Delete, Copy, Cut)

> A connection badge appears at the top: **blue** for USB, **green** for WiFi.

---

## Preview

<p align="center">
  <img src="docs/2026-05-15_18-47-43.png" width="800" alt="AndroidFileSync File Browser Screenshot">
  <br><br>
  <img src="docs/2026-05-15_18-50-22.png" width="800" alt="AndroidFileSync App Manager Screenshot">
  <br><br>
  <img src="docs/2026-05-15_18-52-42.png" width="800" alt="AndroidFileSync Wireless Connection Screenshot">
</p>

---

## Troubleshooting

| Problem                             | What to Do                                                                                  |
| ----------------------------------- | ------------------------------------------------------------------------------------------- |
| "Scanning for Device..." won't stop | Make sure USB Debugging is enabled and you tapped "Allow" on your phone                     |
| Phone not showing up                | Try a different USB cable — some cables only charge and can't transfer data                 |
| WiFi pairing fails                  | Make sure both your Mac and phone are on the same WiFi network                              |
| Pairing code not working            | Go back to Wireless Debugging on your phone and tap "Pair device" again to get a fresh code |
| Transfers are slow                  | Use a USB 3.0 cable and plug into a USB 3.0 port on your Mac                                |
| Trash won't empty                   | Disconnect and reconnect your device, then try again                                        |
| App won't launch                    | Make sure you're on macOS 13.0 or newer, and that you ran the `xattr` command from step 3   |

---

## All Features

### Connectivity

- **USB Connection** — Plug in and go, zero setup
- **Wireless ADB (Android 11+)** — Connect over WiFi without a cable
- **Auto-Discovery** — Automatically finds your phone on the network
- **Advanced Pairing** — Manually enter connection details for complex network setups
- **Multi-Device Selector** — Switch between multiple Android devices from a dropdown
- **Context-Aware Disconnect** — Cleanly disconnect wireless devices when you're done

### File Management

- **File Browser** — Browse your phone's storage like a native Finder window
- **SD Card Support** — Browse and manage files on your external SD card
- **Drag & Drop** — Drag files from Finder straight to your phone
- **Parallel Transfers** — Upload and download multiple files at the same time
- **Conflict Resolution** — Detects duplicate files during uploads, lets you Skip or Replace
- **Collision Prevention** — Automatically generates unique names when renaming or pasting to avoid overwrites
- **Smart Sidebar** — Quick access to Camera, Downloads, Pictures, Music, SD Card — hides folders that don't exist on your device
- **Native macOS Dialogs** — Polished rename and new folder prompts that feel right at home on Mac
- **Search & Sort** — Search files instantly, sort by name, size, date, or type
- **Batch Operations** — Change extensions or delete multiple files at once
- **Copy, Cut & Paste** — Clipboard operations across folders on the device
- **Trash & Restore** — Move files to trash and restore them later, just like macOS
- **Delete Permanently** — Bypass Trash and permanently erase files/folders instantly
- **File Preview** — Double-click to preview images, videos, PDFs, and documents
- **Resizable Transfer Panel** — Collapsible, draggable progress view

### App Management

- **App Browser** — View all installed apps (User, System, Disabled) with icons and labels
- **Install APK** — Sideload APK files directly from your Mac
- **Uninstall Apps** — Remove user-installed apps with confirmation
- **Disable System Apps** — Disable built-in system apps without rooting
- **Re-enable Apps** — Restore previously disabled apps with one click
- **Batch Actions** — Select multiple apps and uninstall/disable/enable them at once
- **App Icons** — Real app icons extracted from APKs, with letter-avatar fallbacks
- **Force Stop & Clear Data** — Stop misbehaving apps or wipe their data and cache
- **Backup APK** — Save an app's APK file to your Mac before uninstalling

### Safety

- **Confirmation Dialogs** — All destructive actions (uninstall, disable, clear data) ask before proceeding
- **Context-aware actions** — System tab shows Disable; Disabled tab shows Enable; User tab shows Uninstall

---

## Tech Stack

- **SwiftUI** — Native macOS interface
- **ADB** — Android Debug Bridge (bundled with the app)
- **Swift Concurrency** — Async/await for parallel transfers
- **Network.framework** — mDNS service discovery for wireless pairing
- **CoreImage** — Image processing and thumbnail generation
- **Quick Look** — Native file preview via macOS default apps
