# AndroidFileSync

A native macOS app for managing files on your Android device via USB.

![macOS](https://img.shields.io/badge/macOS-13.0+-blue.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

## Quick Start

### Step 1: Download & Install

1. Download `AndroidFileSync.dmg` from [**Releases**](../../releases)
2. Open the DMG → Drag **AndroidFileSync** to **Applications**
3. First launch: Right-click → **Open** → Click **"Open"**

> **Note**: ADB is bundled - no additional installation needed!

---

### Step 2: Enable USB Debugging on Android

1. Open **Settings** → **About Phone**
2. Tap **Build Number** 7 times (enables Developer Options)
3. Go back to **Settings** → **Developer Options**
4. Enable **USB Debugging**

---

### Step 3: Connect & Use

1. Connect your Android device via USB cable
2. Launch **AndroidFileSync**
3. On your Android, tap **"Allow"** when USB debugging prompt appears
4. Start managing your files!

---

## How to Use

### Browse Files
- Click folders to navigate into them
- Click **← Back** button or breadcrumb to go up
- Use the **sidebar** for quick access to common locations

### Upload Files (Mac → Android)
- Click **Upload** button → Select files
- **OR** Drag & drop files from Finder directly into the app
- Progress bar shows transfer status
- Click **✕** to cancel upload

### Download Files (Android → Mac)  
- Select file(s) → Click **Download**
- Choose save location on your Mac
- Click **✕** to cancel download

### Copy / Move Files
- Select file(s) → Click **Copy** or **Cut**
- Navigate to destination folder
- Click **Paste**

### Create New Items
- **New Folder**: Click folder icon or ⌘N
- **New File**: Click file icon → Enter name

### Delete Files
- Select file(s) → Click **Delete**
- Files go to **Trash** (30-day retention)
- Go to Trash → **Restore** or **Delete Permanently**

### Rename Files
- Select a file → Click **Rename**
- Enter new name → Press Enter

### Search & Sort
- Type in search bar to filter files
- Click column headers to sort by Name, Size, or Type

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘N | New Folder |
| ⌘V | Paste |
| ⌘R | Refresh |
| ⌘F | Focus Search |
| Esc | Clear Search |
| ⌘A | Select All |

---

## Troubleshooting

### Device Not Detected
1. Check USB cable is connected properly
2. Try a different USB port
3. Ensure USB Debugging is enabled
4. Unlock your phone and check for permission prompts

### "Allow USB Debugging" Not Appearing
1. Disconnect and reconnect the cable
2. On Android: Revoke USB debugging authorizations and reconnect

### Transfer Stuck
- Click **✕** to cancel and retry
- Check available storage on device

---

## Build from Source

```bash
git clone https://github.com/Santosh7017/AndroidFileSync.git
cd AndroidFileSync
open AndroidFileSync.xcodeproj
# Press ⌘R to build and run
```

## License

MIT License - see [LICENSE](LICENSE)
