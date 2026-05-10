# 🎉 AndroidFileSync v2.0.0

A native macOS application for managing files and apps on Android devices via USB or WiFi.

---

## ✨ What's New in v2.0.0

### New Features
- 📱 **App Manager** — Browse, install, uninstall, disable and manage all apps (User, System, Disabled) on your Android device
- 💾 **SD Card Support** — Browse and manage files on your device's external SD card
- 🎨 **App Icons** — Real icons extracted from APKs with smart letter-avatar fallbacks (unique color per app)
- 🗑️ **Delete Permanently** — New option in the file selection toolbar to bypass Trash and erase files instantly
- 🛡️ **Confirmation Dialogs** — Destructive actions (uninstall, disable, clear data, clear cache) now ask before proceeding
- 🎯 **Context-Aware Batch Actions** — System tab shows Disable; Disabled tab shows Enable; User/All tab shows Uninstall


---

## ✨ What's New in v1.1.0

- ⚡ **Conflict Resolution** — Upload now detects duplicate files before transfer. Choose to Replace, Skip, or Cancel per batch.
- 🌐 **Wireless ADB Support** — Connect over WiFi using Android 11+ Wireless Debugging. No cable required.
- 🔍 **Auto-Discovery Pairing** — Automatically detects nearby Android devices on the same network. Enter the 6-digit code to pair instantly.
- 📡 **Advanced Pairing Mode** — Manually enter IP, port, and code for complex network setups.
- 📂 **Smart Quick Access Sidebar** — Jump to Camera, Downloads, Music, Pictures. Auto-hides folders that don't exist on your device.
- 🪟 **Native macOS Dialogs** — Renamed and New Folder actions now use polished native panels instead of alerts.
- 🔄 **Collision Prevention** — Safe rename and paste operations automatically generate unique names or warn before overwriting.
- 📊 **Multi-Device WiFi Selector** — Seamlessly switch between multiple Android devices on the same network from a dropdown.

---

## ✨ All Features

### Connectivity

- 🔌 **USB Connection** — Plug in and go, zero config
- 📶 **Wireless ADB (Android 11+)** — Connect over WiFi without a cable
- 🔍 **Auto-Discovery** — Instantly detects pairable devices on the network
- ⚙️ **Advanced Pairing** — Manually enter IP, port, and code for any setup
- 📱 **Multi-Device Selector** — Switch between multiple connected Android devices

### File Management

- 📁 Browse and navigate files on your Android device
- 💾 **SD Card Support** — Browse and manage files on external SD card
- 📤 **Upload files** from Mac to Android with progress tracking
- 📥 **Download files** from Android to Mac with progress tracking
- ❌ **Cancel transfers** in progress with one click
- ✂️ Copy, cut, and paste files within the device
- 📝 Create new files and folders
- 🔄 Rename files and change extensions
- 🗑️ Trash system with restore capability
- 🔥 **Delete Permanently** — Bypass Trash for instant, irreversible deletion
- ⚠️ **Conflict Detection** — Warns before overwriting existing files
- 🛡️ **Collision Prevention** — Safe unique-name generation on paste/rename

### App Management

- 📱 **App Browser** — View all installed apps (User, System, Disabled) with icons and labels
- 📦 **Install APK** — Sideload APK files directly from your Mac
- 🗑️ **Uninstall Apps** — Remove user-installed apps with confirmation
- 🚫 **Disable System Apps** — Disable built-in apps without rooting
- ✅ **Re-enable Apps** — Restore previously disabled apps with one click
- 📋 **Batch Actions** — Select multiple apps and uninstall/disable/enable them at once
- 🎨 **App Icons** — Real icons from APKs, with letter-avatar fallbacks
- ⛔ **Force Stop & Clear Data** — Stop misbehaving apps or wipe their data/cache
- 💾 **Backup APK** — Save an app's APK to your Mac before uninstalling

### User Experience

- 🎯 Drag & drop files from Finder to upload
- 🔍 Live search to filter files
- 📊 Sort by name, size, or type
- 📍 Smart Quick Access Sidebar for common locations
- 👁️ File Preview — Double-click images, videos, PDFs, and documents
- ⌨️ Keyboard shortcuts (⌘N, ⌘V, ⌘R, ⌘F)
- 🪟 Native macOS Dialogs for rename and folder creation

### Safety

- 🛡️ **Confirmation Dialogs** — Uninstall, disable, clear data/cache all ask before acting
- 🎯 **Context-Aware Actions** — System → Disable, Disabled → Enable, User → Uninstall

### Technical

- 🚀 Built with SwiftUI for native macOS experience
- 📦 ADB bundled — no additional installation needed
- 🔒 Clean logging (errors only in production)
- 💾 Supports macOS 13.0 (Ventura) and later

---

## 📥 Installation

1. Download `AndroidFileSync.dmg`
2. Open the DMG → Drag app to **Applications**
3. Remove macOS quarantine flag:
   ```bash
   xattr -cr /Applications/AndroidFileSync.app
   ```
4. Launch the app

## 🔧 Setup (One-time)

Enable USB Debugging on your Android device:
1. Settings → About Phone → Tap "Build Number" 7 times
2. Settings → Developer Options → Enable "USB Debugging"

For WiFi: Also enable **Wireless Debugging** in Developer Options (Android 11+).

## ⚡ Quick Start

1. Connect Android device via USB or WiFi
2. Launch AndroidFileSync
3. Accept USB debugging prompt on phone
4. Start managing files!

---

**Full Changelog**: https://github.com/Santosh7017/AndroidFileSync/compare/v1.1.0...v2.0.0
