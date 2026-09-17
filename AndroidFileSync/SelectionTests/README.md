Run `python3 SelectionTests/run.py` from the AndroidFileSync directory for selection
logic and responder checks, including range reversal, list and tile drag reversal,
boundaries, sorting, filtering, Command-click, and text editing.

To check the actual rendered browser, build the app and run the integration harness:

```sh
xcodebuild -project AndroidFileSync.xcodeproj -scheme AndroidFileSync -configuration Debug -derivedDataPath /private/tmp/afs-selection-build CODE_SIGNING_ALLOWED=NO build
python3 SelectionTests/run.py --browser
```

The integration harness imports that built app module and launches an isolated
test app through macOS. It verifies clicks, repeated Shift + arrows, shrinking a
range, and dragging down then back up in both layouts with mixed files and folders.
It uses an offscreen window, briefly takes keyboard focus, and restores the previous
app afterward. It uses isolated preferences and no phones or ADB. A logged-in macOS
session and access to WindowServer are required.
