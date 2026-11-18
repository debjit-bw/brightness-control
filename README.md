# BrightnessKeys

Menu-bar app that makes the Mac's brightness keys control an external monitor (via DDC/CI) when the cursor is on it. Apple Silicon only.

## Install

```sh
./build.sh
open ~/Applications/BrightnessKeys.app
```

Grant Accessibility access when prompted. After a rebuild, if the keys stop working, remove and re-add the app in System Settings → Privacy & Security → Accessibility.

Option+Shift+brightness keys adjust in finer steps.
