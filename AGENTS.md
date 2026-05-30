# AGENTS.md

This file provides guidance to AI coding agents when working with the MyUltron macOS desktop client.

## Project overview

MyUltron is the macOS desktop debugging client for iOS apps. It connects to the iOS device via:
- **USB** — libimobiledevice + usbmuxd
- **Simulator** — localhost TCP

The iOS app must have [MyUltronServer](https://github.com/genwe/MyUltronServer) integrated as the server-side counterpart.

## Build

Open `MyUltron.xcodeproj`, select the MyUltron scheme, build. The app links against static libraries under `ios_lib_arm64/`.

## Architecture

```
ViewController (main window, sidebar, feature routing)
  └── FeatureViewController (base class)
        └── DeviceInfoViewController       (libimobiledevice lockdown)
        └── DeviceScreenshotViewController (TCP screenshot)
        └── SandboxViewController          (file browser)
        └── NetworkMonitorViewController   (HTTP monitor + mock)
        └── MessagePushViewController      (push simulation)
        └── LogMonitorViewController       (live log viewer)
        └── ...
```

Core transport layer:
```
ViewController
  └── MyUltronClient (TCP client, binary packet protocol)
        └── MyUltronPacketBuilder (C++ encode/decode)
```

## Key patterns

- Features access `MyUltronClient` via `((ViewController *)self.parentViewController).client`
- Messages use `{ version, messageType, content }` JSON envelope
- Binary responses arrive via `didReceiveBinaryData:` (dynamically dispatched)
- Feature VCs are cached — switching tabs doesn't create new instances

## Code conventions

- ObjC prefix: `MyUltron*` for custom classes
- `.mm` for ObjC++, `.m` for plain ObjC
- Features live under `MyUltron/Features/`
- Core under `MyUltron/Core/`
