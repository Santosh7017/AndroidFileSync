# AndroidFileSync

A native macOS application for managing files on Android devices via USB using ADB (Android Debug Bridge).

![macOS](https://img.shields.io/badge/macOS-13.0+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

## Features

- 📁 **File Browser** - Navigate and browse files on your Android device
- 📤 **Upload & Download** - Transfer files between Mac and Android
- ✂️ **Copy, Cut & Paste** - Move files within the Android device
- 📝 **Create Files & Folders** - Create new files and directories
- 🔄 **Rename & Change Extension** - Rename files and batch change extensions
- 🗑️ **Trash System** - Soft delete with restore capability (30-day retention)
- 🔍 **Search & Filter** - Find files quickly with live search
- 📊 **Sort Options** - Sort by name, size, or type
- 🎨 **Native macOS UI** - Built with SwiftUI for a seamless Mac experience

## Installation

### Option A: Download Pre-built App (Easiest)

1. Go to [**Releases**](../../releases) and download `AndroidFileSync.dmg`
2. Open the DMG and drag **AndroidFileSync** to **Applications**
3. **First launch**: Right-click the app → **Open** → Click **"Open"**

**That's it!** ADB is bundled inside the app - no additional installation needed.

---

### Option B: Build from Source

#### Prerequisites

1. **macOS 13.0 or later**
2. **Xcode 15+** (free from Mac App Store)

### Step 1: Install ADB

Using Homebrew (recommended):
```bash
brew install android-platform-tools
```

Or download manually from [Android SDK Platform Tools](https://developer.android.com/studio/releases/platform-tools)

### Step 2: Enable USB Debugging on Android

1. Go to **Settings → About Phone**
2. Tap **Build Number** 7 times to enable Developer Options
3. Go to **Settings → Developer Options**
4. Enable **USB Debugging**

### Step 3: Clone and Build the App

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/AndroidFileSync.git

# Open in Xcode
cd AndroidFileSync
open AndroidFileSync.xcodeproj
```

In Xcode:
1. Select **"My Mac"** as the build target (top toolbar)
2. Press **⌘R** (or Product → Run) to build and run
3. The app will launch automatically

### Step 4: First Run (One-time Security Setup)

If you see a security warning:
1. Go to **System Settings → Privacy & Security**
2. Scroll down and click **"Open Anyway"** next to AndroidFileSync
3. Or: Right-click the app → **Open** → Click **"Open"**

### Optional: Install to Applications

After building, you can find the app at:
```
~/Library/Developer/Xcode/DerivedData/AndroidFileSync-xxx/Build/Products/Release/AndroidFileSync.app
```

Drag it to your **Applications** folder for easy access.

## Usage

1. Connect your Android device via USB
2. Launch AndroidFileSync
3. Accept the USB debugging prompt on your Android device
4. Browse, upload, download, and manage your files!

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘N | New Folder |
| ⌘V | Paste |
| ⌘R | Refresh |
| ⌘F | Focus Search |
| Esc | Clear Search |

## Screenshots

*Coming soon*

## Architecture

- **SwiftUI** - Modern declarative UI framework
- **ADB** - Android Debug Bridge for device communication
- **File Provider** - macOS File Provider extension for Finder integration

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built with ❤️ using SwiftUI
- Uses Android Debug Bridge (ADB) for device communication
