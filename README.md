# MyUltron

[English](./README.md) | [中文](./README-zh.md) 

![MyUltron Screenshot](MyUltron_screen_shot_1.png)

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
| Push Notifications | Send custom push messages to connected app | ✅ |
| Network Monitor | Real-time network monitoring with Mock support | ✅ |
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

Feature modules can be shown/hidden. Settings are persisted in NSUserDefaults.

## MCP (Model Context Protocol)

MyUltron can expose its debugging tools as an MCP server, enabling AI assistants like **Claude Code** to interact directly with iOS devices — taking screenshots, reading sandbox files, querying databases, and more.

### Enabling MCP

1. In the MyUltron app, connect to a device and select an app (TCP status turns green)
2. Click the **MCP** button in the toolbar — a green dot appears when the server is running on `localhost:9021`

### Connecting from Claude Code

```bash
claude mcp add --scope project myultron nc localhost 9021
```

This writes a `.mcp.json` config file to your project root, which can be committed to git.

### Available MCP Tools

| Tool | Description | Requires App |
|------|-------------|:---:|
| `list_devices` | List connected iOS devices and booted simulators | No |
| `device_info` | Get detailed device information | No |
| `list_apps` | List installed apps on the device | No |
| `take_screenshot` | Take a screenshot and save to `~/Desktop/` | Yes |
| `list_sandbox_dir` | List sandbox directory contents | Yes |
| `read_sandbox_file` | Read a file from the sandbox | Yes |
| `delete_sandbox_file` | Delete a file or directory from the sandbox | Yes |
| `list_user_defaults` | List all NSUserDefaults keys | Yes |
| `get_user_default` | Get a specific UserDefaults value | Yes |
| `set_user_default` | Set a UserDefaults value | Yes |
| `delete_user_default` | Delete a UserDefaults key | Yes |
| `list_sqlite_dbs` | List SQLite databases in the sandbox | Yes |
| `list_sqlite_tables` | List tables in a database | Yes |
| `query_sqlite` | Query data from a table | Yes |
| `send_push` | Send a simulated push notification | Yes |
| `list_network_requests` | List captured network requests | Yes |
| `url_encode` | URL-encode a string | No |
| `url_decode` | URL-decode a string | No |
| `base64_encode` | Base64-encode a string | No |
| `base64_decode` | Base64-decode a string | No |
| `md5_hash` | Compute MD5 hash of a string | No |

## Requirements

- macOS 13+
- Xcode 14+
- libimobiledevice (for real device communication)
