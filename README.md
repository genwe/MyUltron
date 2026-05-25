# MyUltron

iOS debugging desktop client. Connects to the MyUltronServer embedded in an iOS app via USB or simulator, providing device info, sandbox management, log monitoring, database browsing, and more.

## Device Connection

- **Real Device** — USB connection via libimobiledevice + usbmuxd port forwarding
- **Simulator** — localhost TCP connection, port configurable in Preferences (default 62345)
- Auto-discovery of booted simulators and USB-connected real devices
- Drag-and-drop `.app` / `.ipa` installation to connected devices

## Features

| Feature | Description | Status |
|---|---|---|
| Device Info | Display basic device info (name, OS version, UDID, etc.) | ✅ |
| App List | List installed user apps (name, Bundle ID, version) | ✅ |
| Screenshot | Real-time iOS device screenshot capture | ✅ |
| Sandbox | Browse, create, delete, upload, download sandbox files | ✅ |
| MMKV Data | Browse and manage MMKV key-value data | 🚧 |
| UserDefaults | Browse and manage NSUserDefaults data | ✅ |
| SQLite Browser | Select databases, browse table data, CRUD operations | ✅ |
| Codec | Base64 / URL encode-decode and other encoding tools | ✅ |
| Push Notifications | Send custom push messages to connected app | 🚧 |
| Network Monitor | Real-time network request monitoring | 🚧 |
| Log Monitor | Real-time console log viewing | ✅ |
| Analytics Monitor | Monitor analytics tracking events | 🚧 |
| IM Session Monitor | Monitor IM session messages | 🚧 |
| Route Validation | Validate app routing configuration | 🚧 |
| Environment Switch | Switch app runtime environment (dev/test/prod) | 🚧 |
| Crash Logs | View and export app crash logs | 🚧 |
| Hotfix | Manage app hotfix patches | 🚧 |
| Grayscale Tasks | Manage grayscale release tasks | 🚧 |
| Log Parser | Parse xlog/mars encrypted log files | 🚧 |

## Sidebar Customization

Feature modules can be shown/hidden and reordered via drag-and-drop. Settings are persisted in NSUserDefaults.

## Requirements

- macOS 13+
- Xcode 14+
- libimobiledevice (for real device communication)
