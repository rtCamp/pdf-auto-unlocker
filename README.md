<p align="center">
  <img src="PDF%20Unlocker/Assets.xcassets/AppIcon.appiconset/256-mac.png" width="128" alt="PDF Auto Unlocker">
</p>

<h1 align="center">PDF Auto Unlocker</h1>

A menubar macOS app that automatically unlocks encrypted PDFs using a saved list of passwords.

If you receive encrypted PDFs such as bank, credit card, or investment statements, store their passwords once and let the app open them for you.

<h3 align="center">Settings</h3>

<p align="center">
  <img width="432" height="684" alt="PDF Auto Unlocker Settings" src="https://github.com/user-attachments/assets/5fe9849c-b2c1-4175-9328-d690bc25e9ee" />
</p>

Once you turn on **Start PDF Monitoring**, the app keeps running in the background and relaunches at login.

## Features

- **Keychain storage** — passwords saved securely in the macOS Keychain.
- **iCloud Keychain sync** — passwords follow you across Macs signed into the same iCloud account.
- **Customizable monitored folder** — watch any folder you choose, not just Downloads.
- **Open PDFs even if not encrypted** — optional toggle to auto-open every new PDF in the watched folder.
- **Hardened Runtime + Apple Developer signing** — passes Gatekeeper on signed builds.

## Installation

1. [Download PDF-Auto-Unlocker.zip](https://github.com/rtCamp/pdf-auto-unlocker/releases/latest/download/PDF-Auto-Unlocker.zip)
2. Unzip the file. You'll see `PDF Auto Unlocker.app`.
3. Drag `PDF Auto Unlocker.app` into your `Applications` folder.
4. Double click `PDF Auto Unlocker.app` to launch the menu bar app.
5. Click the menu bar icon to open Settings, add passwords, choose a folder, and start monitoring.

## Credits

* [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) by sindresorhus
* [FileWatcher](https://github.com/eonist/FileWatcher) by eonist
* [SettingsAccess](https://github.com/orchetect/SettingsAccess) by orchetect
* [Unlock App Icon](https://thenounproject.com/icon/unlock-89653/) by Noun Project
