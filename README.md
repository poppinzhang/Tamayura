<div align="center">

<img src="assets/branding/app_icon.png" width="112" alt="Tamayura app icon">

# Tamayura · 玉响

### Your photos, within reach.

**Browse the photos and videos on your own devices.**<br>
Share folders over your local network, browse previews even when a device is offline,<br>
and save the originals you want with a tap.

![Android](https://img.shields.io/badge/Android-16%2B-3DDC84?logo=android&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-15%2B-111111?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-x64-0078D4)
[![License](https://img.shields.io/badge/license-Apache--2.0-111111)](LICENSE)

**[Quick start](#quick-start)** &nbsp;·&nbsp; **[Documentation](#documentation)** &nbsp;·&nbsp; **[Changelog](CHANGELOG.md)** &nbsp;·&nbsp; **English** · [简体中文](README.zh-CN.md)

<br>

<img src="docs/screenshots/macos-prototype.png" width="900" alt="Tamayura desktop interface showing photo collections grouped by device and shared folder">

<sub>Desktop interface preview with sample collections.</sub>

</div>

## Is Tamayura for you?

Your phone holds the everyday photos. Your computer holds the trips, videos, and older albums. Tamayura brings their previews together so you can find a moment and bring the original to the device in your hands.

- **Choose what to share.** Add one or more folders, including their subfolders, on each device.
- **Browse before downloading.** Previously synced previews stay available when the source device is offline.
- **Keep the originals you want.** Tap a photo or video to download it into your chosen folder.

It is for browsing and transferring media between your own devices on the same local network. It does not automatically copy entire albums or track edits to file contents.

## Quick start

Tamayura is in early development. The published **0.9.0** packages for Android, macOS, and Windows are available as a [Pre-release](https://github.com/poppinzhang/Tamayura/releases/tag/v0.9.0). See the [0.9.0 release record](docs/releases/0.9.0.md) for installation and validation scope. Use the **same build** on all devices; compatibility between releases is not guaranteed before v1.0.0, and protocol v4 does not connect to 0.5.0.

The current **0.9.6 source** adds 90-degree image rotation, previous/next preview navigation with downloads only for the item you visit, and double-tap navigation to return Albums, Devices, or Settings to the top. It also refreshes interface icons and motion and fixes local previews for some Sony ARW images on macOS. **0.9.6 release validation and packages are still pending**; these changes are not in the published 0.9.0 packages. The [0.9.5 release attempt](docs/releases/0.9.5.md) did not produce public packages. See the [0.9.6 release record](docs/releases/0.9.6.md) for current status and limitations.

**1 · Install and connect.** Choose the package for your platform from the [0.9.0 Pre-release](https://github.com/poppinzhang/Tamayura/releases/tag/v0.9.0), and read the [installation notes](docs/releases/0.9.0.md#安装与数据). To run from source, see the [source build instructions](AGENTS.md#本地开发). Android 0.9.0 keeps the release certificate used since 0.6.1 and can update an app with the same signature. Uninstall a 0.5.0 or earlier trial app with the old signature first; this clears app data and folder permissions. Connect both devices to the same local network and open Tamayura. Allow local network access when prompted; on Windows, allow the app through the firewall on your trusted private network.

**2 · Choose your folders.** In **Settings (设置)**, add the folders you want to share and choose where downloaded files should go. For example, share `DCIM` and receive files in `Pictures/Tamayura`. Subfolders are included automatically. On Android, choose a subfolder rather than the storage root or the `Download` root.

**3 · Find your other device.** Open **Devices (设备)** and wait for automatic discovery. When a new device is found, Tamayura asks whether to sync its album; if you choose not to, you can turn syncing on later from its card. You can also enter the address shown on the other device, or scan its QR code on Android and macOS; these connect and sync right away.

**4 · Open an album.** In **Albums (相册)**, choose a shared collection and tap a photo or video to download its original. The source device must be online for downloads. After adding or removing media, refresh the source device, then refresh the receiving device to update its album immediately.

## Check for updates

Open **Settings → Check for updates** to check GitHub Releases, including pre-releases. Tamayura asks for your confirmation before proceeding. Android downloads and verifies the APK, then opens the system installation flow; allow this installation source when prompted and confirm the update. Windows downloads and verifies the full ZIP, replaces the complete application folder, and restarts. It requires a complete release bundle in a dedicated writable local folder whose parent is also writable; it does not provide a separate installer or automatically request administrator access. macOS opens the selected release page for you to download and install the update yourself.

If you already have 0.8.0 installed, use Check for updates to find 0.9.0. Users of 0.7.0 or earlier need to install 0.9.0 manually. Checking and downloading updates requires internet access. Updating interrupts sharing and transfers; interrupted media downloads can be retried after reopening the app. See the [0.9.0 release record](docs/releases/0.9.0.md) for limitations and the remaining device acceptance work.

## Supported platforms

| Platform | Requirements | Package |
| :-- | :-- | :-- |
| Android | Android 16+ · API 36+ | APK |
| macOS | macOS Sequoia 15.0+, including Tahoe 26 and later | Universal app for Apple silicon and Intel |
| Windows | Windows 10 1809+ / Windows 11 · x64 | ZIP; Visual C++ x64 runtime required |

The macOS Pre-release app uses ad-hoc signing and is not notarized; the Windows ZIP is unsigned. Installation details and validation limits are in the [0.9.0 release record](docs/releases/0.9.0.md). iOS and Linux are planned but do not yet have runnable or downloadable builds.

Windows can display a connection QR code, open downloaded files in the default app, and reveal them in Explorer. Camera scanning and the system share sheet are available on Android and macOS.

## How it fits together

Each device chooses its shared folders and remembers the other devices it has connected to. To remove a device together with its offline album, choose **Forget device** from its menu on the Devices page; files you have already downloaded stay on your device. Tamayura first syncs the media list and small previews. Originals stay on their source device until you choose to download them.

Devices discover each other with mDNS / DNS-SD and transfer media directly over gRPC. There is no account or cloud relay to set up.

## What it does

### Your folders, your albums

Each shared folder becomes a collection, including media in its subfolders. Browse across devices, sort a collection by date or name, and choose a compact grid or a detailed view. On mobile, drag the scroll handle to move through a large collection. Downloaded photos use the local image for a clearer preview.

### Previews that stay with you

Synced thumbnails remain available offline. During a sync, photos appear as they arrive; interrupted syncs keep their progress so you can continue later. Automatic sync defaults to **10 minutes**; Settings accepts a whole number from **1 to 525600 minutes** (up to one year). If the last sync with a device failed, Tamayura retries as soon as that device appears on the network again. Refresh manually whenever you need an update, and check each device's last successful sync time.

When upgrading to 0.7.0, the previous hour-based setting is not carried over; without a saved minute-based setting, the default is 10 minutes. Mobile fast scrolling supports continuous drags and hides automatically after release. Windows uses available embedded RAW previews and keeps recently generated thumbnails in memory to reduce repeated decoding; format support still depends on installed system codecs.

### Originals on demand

Tap to download a photo or video. Files are saved under **device / shared folder / original subfolders**, keeping their names and folder structure. Files larger than **50 MiB** use parallel downloads. You can pause, retry, or cancel a download and remove its temporary data; interrupted transfers can resume from saved progress.

Already saved media can be removed from this device in the app. This leaves the source file and cached preview intact, so you can download it again later.

### Keep sharing in the background

On Android, enable **Settings → Background sharing (后台共享)** to serve files while the phone is locked. Availability depends on the system's battery settings. Downloads can also continue in the background.

On macOS and Windows, closing the window keeps Tamayura in the menu bar or system tray. Background sharing follows its setting, and downloads can continue while the app is running and the computer is awake. Quitting the app or putting the computer to sleep interrupts transfers.

### Simplified Chinese, Japanese, and English

**0.9.0** supports Simplified Chinese, Japanese, and English interfaces. Tamayura follows the first supported language in your system's preferences by default, using English when none is supported. You can switch at any time in **Settings → Appearance → Language**, and your choice is saved. Notification text, menu bar or system tray menus, and folder picker titles follow the same choice.

Existing error messages keep their original language. On Android, downloads already in progress may continue to produce error messages in the previous language. Some system dialogs and buttons follow the operating system's language. See [Interface languages](docs/多语言.md) for the full scope and limitations.

### Light, dark, or your system's choice

A quiet black, white, and gray interface, with a saved theme preference across sessions.

<div align="center">
<img src="docs/screenshots/theme-light.png" width="280" alt="Tamayura settings in light mode">
&nbsp;
<img src="docs/screenshots/theme-dark.png" width="280" alt="Tamayura settings in dark mode">
<br>
<sub>Settings previews with sample folders.</sub>
</div>

## Documentation

Most detailed documentation is currently in Chinese.

| Guide | What it covers |
| :-- | :-- |
| [Changelog](CHANGELOG.md) | Released and unreleased changes |
| [GitHub Releases](https://github.com/poppinzhang/Tamayura/releases) | Published packages and checksums |
| [0.9.6 release record](docs/releases/0.9.6.md) | Current source: preview rotation and navigation, interface changes; release pending |
| [0.9.5 release record](docs/releases/0.9.5.md) | Unpublished release attempt |
| [0.9.0 release record](docs/releases/0.9.0.md) | Language support, installation impact, and validation scope |
| [0.8.0 release record](docs/releases/0.8.0.md) | Previous release: update feature and installation requirements |
| [Sync behavior](docs/自动与手动同步.md) | Automatic intervals, manual refresh, and sync status |
| [New and forgotten devices](docs/新设备确认与忘记设备.md) | Confirming newly discovered devices, retrying when a device comes back, and forgetting devices |
| [Downloads and storage](docs/下载存储与清理.md) | Resuming downloads, temporary files, and cleanup |
| [Interface languages](docs/多语言.md) | Language selection, translated content, and limits |
| [Background sharing](docs/后台共享.md) | Android background availability and battery settings |
| [Development guide](AGENTS.md) | Setup, tests, builds, and implementation references |

## Privacy

Media and previews travel directly between devices on your local network. Each device stores the synced media information and thumbnails locally so you can browse them offline. You choose which folders to share and where to save downloads.

Tamayura currently uses **IPv4 local networks without authentication or transport encryption (TLS)**. Use it only on a trusted network. Guest Wi-Fi and client isolation may prevent devices from connecting.

Before v1.0.0, updates may reset settings, cached albums, and download records. Files in your shared and receiving folders are preserved, but you may need to choose the folders and connect your devices again.

## License

[Apache License 2.0](LICENSE). Third-party components retain their own licenses, available in the app under **Settings → About → Third-party licenses**.
