# TNFNavigationHelper

Runtime helper for TrollNFC that preserves card list scroll position and adds horizontal navigation to the record view without modifying the original `.tipa` bundle.

## Features

- Remembers card list scroll offset, restoring it on return so large collections stay manageable.
- Highlights the last opened card inside the list for quick visual recall.
- Wraps TrollNFC's record screen in a `UIPageViewController` to enable swipe and arrow-key navigation between cards.
- Prefetches adjacent controllers while capping the in-memory cache to three pages to stay lean on jailbroken devices.

## Building

1. Install [Theos](https://github.com/theos/theos) on your macOS or Linux build machine.
2. Create a tweak project and drop `TNFNavigationHelper.m` into the project source folder.
3. Make sure your `Makefile` links against UIKit (`Tweak.xm`/`Files` entry) and sets the target to iOS 14+ (matching TrollNFC's minimum).
4. Compile the tweak:
   ```sh
   make package FINALPACKAGE=1
   ```
5. Sign the resulting `.dylib` with `ldid` if required and copy it to your TrollStore device.

## Deployment

- Place the built `.dylib` inside TrollNFC's app bundle under `TrollNFC.app/Frameworks/` (or any writable location) and use a launch daemon or a loader such as Choicy to inject it at launch.
- Alternatively, bundle the helper inside a TrollStore plug-in and inject with `launchctl` using `DYLD_INSERT_LIBRARIES`.
- Respring or relaunch TrollNFC. The helper will auto-install its swizzles once the UI loads.

## Keyboard Support

The helper registers left/right arrow `UIKeyCommand` handlers so horizontal navigation also works on Mac Catalyst and keyboard-enabled iPads.

## Notes

- The helper relies on runtime inspection of TrollNFC's Swift classes. If future updates rename `CardListController`, `RecordListController`, or `CardView`, update the class lookup strings at the top of `TNFNavigationHelper.m`.
- For best stability, keep only one copy of the helper injected at any time.
