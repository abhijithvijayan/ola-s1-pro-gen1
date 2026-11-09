# HMI Dashboard APK Analysis

## Summary

The main dashboard APK (`HHMIC.apk`, 410MB at `/system/priv-app/HHMIC/HHMIC.apk`) renders the entire scooter UI using the [Kanzi](https://www.rightware.com/kanzi) 3D engine. This document covers its structure, data flow, and what it means for customization.

## Pulling the APK

```bash
# Requires ADB access (see adb-key-injection.md)
adb pull /system/priv-app/HHMIC/HHMIC.apk
# ~410MB, takes about 70s at ~5.4 MB/s over Wi-Fi
```

## Overview

| Attribute | Value |
|-----------|-------|
| Package | `com.olaelectric.hmiclient` |
| Version | 4.6.14 |
| UID | `android.uid.system` (runs as system) |
| SDK | 29 (Android 10) |
| Size | 410 MB (1050 files) |
| OpenGL ES | 2.0 required |
| Arch | arm64-v8a only |

## File Breakdown

| Extension | Count | Purpose |
|-----------|-------|---------|
| .xml | 482 | Data contexts, configs |
| .png | 374 | UI icons and images |
| .kzb | 9 | Kanzi compiled scene graph files |
| .mp4 | 8 | Theme intro animations |
| .so | 17 | Native libraries (Kanzi engine + plugins) |
| .dex | 3 | Java/Kotlin bytecode (9.2 + 6.9 + 3.0 MB) |
| .otf/.ttf | 19 | Fonts |
| .proto | 61 | Google standard protobuf definitions |

### Largest Files

| File | Size | Purpose |
|------|------|---------|
| `ola_electric.kzb` | **217 MB** | Main Kanzi scene graph |
| `Care_Dark.mp4` | 14 MB | Care theme dark animation |
| Theme_packs/*.kzb | 2-10 MB each | 8 theme scene variants |
| `classes.dex` | 9.2 MB | Primary DEX |
| `libkzcoreui.so` | 8.1 MB | Kanzi core UI library |

## The Kanzi Scene Graph

The dashboard is NOT standard Android Views. It's a **single Kanzi 3D scene** compiled into `ola_electric.kzb` (217MB). The text dump (`ola_electric.kzb.txt`, 15589 lines) lists all property bindings.

This means:
- You cannot modify the UI at runtime
- `input tap` does not work on it (Kanzi has its own hit-test)
- Theme switching uses pre-compiled `.kzb` packs
- Editing requires Kanzi Studio (proprietary) or replacing the entire app

## Theme Packs

8 pre-compiled themes in `assets/Theme_packs/`:

| Theme | Modes | Animation |
|-------|-------|-----------|
| Default | Dark, Light | — |
| Bolt | Dark, Light | Bolt_Dark.mp4, Bolt_Light.mp4 |
| Vintage | Dark, Light | Vintage_Dark.mp4, Vintage_Light.mp4 |
| CareGulmohar | Dark, Light | Care_Dark.mp4, Care_Light.mp4 |

Plus Eclipse animations (Eclipse_Dark.mp4, Eclipse_Light.mp4).

## Native Libraries

| Library | Purpose |
|---------|---------|
| `libkanzi.so` (5.0 MB) | Kanzi 3D rendering engine |
| `libkzcoreui.so` (8.1 MB) | Kanzi core UI |
| `libkzui.so` (2.9 MB) | Kanzi UI toolkit |
| `libXML_data_source.so` (2.1 MB) | **Bridges Android data to Kanzi properties** |
| `libEnergyGraph.so` | Battery/energy graph renderer |
| `libMoodSwitchProto.so` | Theme switching with protobuf |
| `libWidgetList.so` | Widget list component |
| `libSlideShow2D.so` | Carousel/slideshow |
| `libScrollTextBlock.so` | Scrolling text |
| `libTrajectoryText.so` | Animated text |
| `libCustomClickListener.so` | Click handler |
| `libNode2D_plugin.so` | 2D node rendering |

`libXML_data_source.so` is the key bridge — it reads the data context XMLs and feeds values from Android services into Kanzi property bindings.

## Data Context XMLs

These XML files (extracted to `schemas/` in this repo) define **every data binding** between the Android backend and the Kanzi UI. They're the complete API specification for building a replacement dashboard.

See the [`schemas/`](../schemas/) directory — all 21 XML data context files plus the Kanzi scene node listing.

| File | Contents |
|------|----------|
| `VehicleDataContext.xml` | Speed, indicators, lights, drive mode, lock, trunk, regen, hill hold, faults, popups |
| `ChargingDataContext.xml` | Battery %, charge time, hypercharger billing, temperature |
| `BTDataContext.xml` | BT state, media controls, caller info, proximity passcode, concert mode |
| `RidingDataContext.xml` | Feature toggles: APB, fall detect, tow/tamper, regen, headlights, hazards |
| `NavigationDataContext.xml` | Navigation state and routing |
| `OTADataContext.xml` | OTA update state |
| `SettingsDataContext.xml` | Settings screen state |
| `WifiDataContext.xml` | Wi-Fi connection state |
| `AboutSettingsContext.xml` | All firmware versions (VSW, MoveOS, VDP, HMI, BCM, BMS, MCU, HBC, HU, BLE), bootloader versions, MAC addresses, VIN, ICCID |
| `ConcertDataContext.xml` | Concert mode (multi-scooter music sync over Wi-Fi): scooter discovery, song selection, light sync |
| `ContactDataContext.xml` | BT caller display: name, number, initials, icon |
| `FencingDataContext.xml` | Geofence and time-fence: riding time windows, per-day restrictions, sport/hyper mode locks |
| `ManufactureAppDataContext.xml` | Factory test interface with QR code generation |
| `PartyModeContext.xml` | Party mode: 6-band audio level visualizer, activation state |
| `SoundSettingsDataContext.xml` | Engine sound customization: Bolt, Vintage, Eclipse presets with tunable parameters |
| `TechPackDataContext.xml` | MoveOS+ subscription: trial status, upgrade gates, feature unlock popups |
| `UserProfileDataContext.xml` | User profiles, passcode management, multi-rider access, driver documents, vehicle selection |
| `VoiceDataContext.xml` | Voice assistant state and error handling |
| `WidgetDataContext.xml` | Dashboard widgets: acceleration, range, energy, RPM, power, torque, CO2, trips, weather, money saved (per-theme variants) |
| `BluetoothListElements.xml` | BT list structures: recent calls, contacts, favorites, paired devices, widget grid |
| `DynamicWidget.xml` | Widget layout engine: Kanzi prefab URLs for each theme (Bolt, Vintage, Eclipse, Care) and navigation minimized state |
| `ola_electric.kzb.txt` | Complete Kanzi scene graph (15,589 lines): every node, property binding, and prefab reference in the compiled UI |

## Manifest Permissions

The HMI runs as `android.uid.system` with:

- `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`
- `BLUETOOTH`, `BLUETOOTH_ADMIN`, `BLUETOOTH_CONNECT`
- `INJECT_EVENTS` — can simulate touch/key events system-wide
- `MEDIA_CONTENT_CONTROL` — can control media playback
- `READ_CONTACTS`, `WRITE_CONTACTS`, `READ_SMS`, `SEND_SMS`
- `WAKE_LOCK`, `READ/WRITE_EXTERNAL_STORAGE`, `CLEAR_APP_USER_DATA`

## Customization Paths

Since the Kanzi `.kzb` scene is compiled and uneditable:

1. **Custom Android launcher** — Register your own app as HOME and disable `hmiclient`.
2. **Theme animations** — The `.mp4` files are easier to replace than the scene graph (bind-mount over them).

## Decompiling Java Code

```bash
brew install jadx
jadx -d decompiled/ HHMIC.apk
```

The 3 DEX files contain the Java/Kotlin code that handles vehicle data parsing, CAN communication, cloud connectivity, and Kanzi data binding.
