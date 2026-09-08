# CalculatorVault

A native iOS calculator (SwiftUI, iOS 17+) with a hidden photo and video vault.
The app has no third-party dependencies.

## Build

Open `CalculatorVault.xcodeproj` in Xcode 16 or later and run the `CalculatorVault` scheme on an iPhone simulator.

## PIN flow

1. On the first launch, the app shows the **Set PIN** screen. Enter a PIN of 4 to 8 digits and confirm it.
   The first digit must not be 0, because the calculator drops leading zeros.
2. The app stores a random 16-byte salt and a SHA-256 hash of `salt + PIN` in the Keychain.
   The PIN is not stored in plaintext or in UserDefaults. The setup screen does not show again.
3. To open the vault, type the PIN on the calculator and press `%`.
   With any other number, `%` works as the percent operator.
4. To change the PIN, open the vault, tap the `...` menu, and tap **Change PIN**.
   The form asks for the current PIN, the new PIN, and a confirmation.

The Keychain survives a reinstall. The app clears the old PIN on the first launch after an install,
so the setup screen shows again.

## File storage

The Import button opens the system `PhotosPicker`. The app does not request access to the photo library.
The app copies each selected item into `Application Support/Vault/` inside the app sandbox.
The directory and every file use `NSFileProtectionComplete`. The copy keeps the original file,
so photos and videos keep their resolution and quality.

Thumbnails and the full-screen view come from `QLThumbnailGenerator`. The app does not store thumbnails on disk.

## Vault lock

The vault locks and the calculator shows again when:

- you tap the lock button,
- the app goes to the background,
- 60 seconds pass with no touch on the screen. A running video does not count as a touch.

When the app becomes inactive, a calculator view covers the window, so the app switcher does not show the vault.

## Folders

- `CalculatorVault/Calculator/` — calculator engine and view.
- `CalculatorVault/Vault/` — gallery grid and full-screen viewer.
- `CalculatorVault/Security/` — Keychain PIN store and PIN setup form.
- `CalculatorVault/Storage/` — vault directory, import, delete, thumbnails.

## Out of scope

iCloud sync, Face ID, decoy vaults, and cloud backup.
