# CalculatorVault

A native iOS calculator (SwiftUI, iOS 17+) with a hidden photo and video vault.
The app has no third-party dependencies.

## Build

Open `CalculatorVault.xcodeproj` in Xcode 16 or later and run the `CalculatorVault` scheme on an iPhone simulator.

## PIN flow

1. On the first launch, the app shows the **Set PIN** screen. Enter a PIN of 4 to 8 digits and confirm it.
   The first digit must not be 0, because the calculator drops leading zeros.
2. The app makes a random 256-bit master key. It derives a key from the PIN with PBKDF2-HMAC-SHA256
   (200 000 rounds, random 16-byte salt) and wraps the master key with AES-256-GCM under that key.
   The Keychain item holds a version byte, the salt, and the wrapped master key. The app does not store the PIN.
3. To open the vault, type the PIN on the calculator and press `%`.
   The app derives the key from the PIN and unwraps the master key. A wrong PIN fails the AES-GCM tag check,
   and `%` works as the percent operator. Each try costs about 0.2 s.
4. To change the PIN, open the vault, tap the `...` menu, and tap **Change PIN**.
   The form asks for the current PIN, the new PIN, and a confirmation. The app wraps the same master key
   under the new PIN. The vault files do not change.

The Keychain survives a reinstall. The app clears the old item on the first launch after an install,
so the setup screen shows again. It keeps the item when the vault directory exists, because that is a restore.

## File storage

The Import button opens the system `PhotosPicker`. The app does not request access to the photo library.
The app encrypts each selected item with AES-256-GCM under the master key and writes it to
`Application Support/Vault/` inside the app sandbox. The directory and every file use `NSFileProtectionComplete`.
The file keeps its extension. The app keeps the original bytes, so photos and videos keep their resolution and quality.

File format: the magic `CVLT`, the plaintext length (UInt64), an 8-byte nonce prefix, then chunks.
A chunk holds up to 1 MiB of plaintext and is stored as ciphertext plus a 16-byte tag.
The nonce of a chunk is the prefix plus the chunk index. The header is the additional authenticated data of every chunk.
The app writes to a hidden `.part` file and renames it when the write completes. It writes no plaintext copy.

Thumbnails and the full-screen photo come from ImageIO on the decrypted data in memory.
Videos play through an `AVAssetResourceLoader` delegate that decrypts byte ranges on demand.
The app does not store thumbnails or decrypted files on disk. Share is the one exception:
it decrypts the item to `tmp/share/`, and the app deletes that copy at the next lock.
An item that the app cannot open shows a warning icon in the grid.

## Vault lock

The vault locks and the calculator shows again when:

- you tap the lock button,
- the app goes to the background,
- 60 seconds pass with no touch on the screen. A running video does not count as a touch.

When the app becomes inactive, a calculator view covers the window, so the app switcher does not show the vault.

## Backup

The iCloud device backup includes the vault files and the Keychain item. The app needs no entitlement
and shows no iCloud UI for this. After a restore on a new device, the calculator shows.
Type the same PIN and press `%` to open the vault.

The backup holds only ciphertext, the salt, and the wrapped master key. It never holds the PIN or the
master key in plaintext. Advanced Data Protection on the iCloud account makes the backup end-to-end encrypted.

## Folders

- `CalculatorVault/Calculator/` — calculator engine and view.
- `CalculatorVault/Vault/` — gallery grid and full-screen viewer.
- `CalculatorVault/Security/` — Keychain PIN store and PIN setup form.
- `CalculatorVault/Storage/` — vault directory, encryption, import, delete, thumbnails, video loader.

## Out of scope

iCloud sync, Face ID, and decoy vaults.
