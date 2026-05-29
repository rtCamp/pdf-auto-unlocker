# Privacy Policy

PDF Auto Unlocker is a macOS utility published by rtCamp Inc. This policy explains what data the app handles and how.

_Last updated: 2026-05-29_

## Summary

PDF Auto Unlocker does not collect any personal data. There is no analytics, no telemetry, no advertising, and no server-side component. Everything happens on your Mac.

## Data Handled by the App

- **PDF passwords.** Passwords you enter in Settings are stored in the macOS Keychain on your Mac. They are not transmitted to rtCamp or any third party.
- **Monitored folder selection.** Stored locally as a security-scoped bookmark in the app's sandbox container.
- **App preferences.** Stored locally in macOS UserDefaults.

## iCloud Keychain Sync

The app marks passwords as synchronizable so the macOS Keychain can replicate them to your other Macs through iCloud Keychain. This sync happens entirely between your devices via Apple's iCloud — rtCamp never sees or receives your passwords. You can disable iCloud Keychain in System Settings → Apple ID → iCloud → Passwords & Keychain.

## File Access

The app watches one folder you choose (Downloads by default) for new PDF files. When a new PDF appears, the app attempts to unlock it locally using your saved passwords and saves the unlocked copy in place. No file contents leave your Mac.

## Network Access

The app makes no network requests.

## Changes

If this policy changes, the updated version will be published in this repository with a new "Last updated" date.

## Contact

For questions or issues, open a GitHub issue:
https://github.com/rtCamp/pdf-auto-unlocker/issues
