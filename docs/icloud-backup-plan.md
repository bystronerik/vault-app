# Plan: iCloud backup with encrypted vault files

Status: implemented on 2026-09-08. Section 8 tests 1 to 5 and 7 to 10 pass on the simulator.

## 1. Summary

- Use the iCloud device backup as the transport. Add no entitlement, no capability, and no iCloud UI.
- Encrypt every vault file with AES-256-GCM under one random master key.
- Derive a key-encryption key (KEK) from the PIN with PBKDF2-HMAC-SHA256. Wrap the master key with the KEK.
- Keep the salt and the wrapped master key in one Keychain item that migrates with the backup. Remove the separate PIN hash.
- On a new device, the calculator unlock path is the restore path. No new screen.
- No backward compatibility. Old installs are uninstalled first.
- The calculator disguise does not change. The only new UI is a warning icon on items that the app cannot open.

## 2. iCloud mechanism

**Chosen: iCloud device backup.** iOS puts `Library/Application Support` and Keychain items without `ThisDeviceOnly` into the device backup by default. The goal is that the vault survives a restore from this backup. The device backup needs no entitlement, no transport code, and no UI. The app encrypts the files, so the backup holds only ciphertext.

Rejected:

- iCloud Drive ubiquity container: it syncs files between devices instead of a backup, and it needs an entitlement and conflict handling.
- CloudKit: it needs a container entitlement, a record schema, asset upload code, and account-state handling for a result that the device backup already gives.

Settings > iCloud > Backups lists the app name and the backup size for every app. This is the same for all three mechanisms. The plan does not change it.

## 3. Cryptographic design

### 3.1 Keys

| Name | Size | Source | Where it lives |
| --- | --- | --- | --- |
| Master key | 256 bit | `SymmetricKey(size: .bits256)`, random | Only wrapped, in the Keychain item. In memory while the vault is open. |
| Key-encryption key (KEK) | 256 bit | PBKDF2-HMAC-SHA256(PIN, salt, 200 000 rounds), 32 bytes | Never stored. Derived at each unlock. |
| Salt | 16 bytes | Random | In the Keychain item, next to the wrapped master key. |

KDF: PBKDF2 with HMAC-SHA256. CryptoKit has no PBKDF2 function. The plan builds it from `HMAC<SHA256>`. The output is 32 bytes, so PBKDF2 is one block, and the code is one loop of about ten lines. A DEBUG self-test compares the output with the first 32 bytes of the RFC 7914 section 11 test vector.

Rounds: 200 000. See section 3.5 for the reason and the limits.

Wrap: `AES.GCM.seal(masterKey, using: kek)` with a random 12-byte nonce. The KEK encrypts one message only, so a random nonce is safe. Store `sealedBox.combined` (12-byte nonce + 32-byte ciphertext + 16-byte tag = 60 bytes).

PIN change: unwrap the master key with the old PIN. Make a new salt. Derive a new KEK from the new PIN. Wrap the same master key. Write the Keychain item. No vault file changes.

### 3.2 Keychain item

The item replaces the current `salt + hash` item. It keeps the service and the account name `pin`. Any item that is not 77 bytes with version 1 counts as absent.

| Bytes | Content |
| --- | --- |
| 0 | Version, value 1 |
| 1 to 16 | Salt |
| 17 to 76 | AES-GCM sealed box of the master key, combined form |

Accessibility: `kSecAttrAccessibleWhenUnlocked`. This item migrates in the iCloud device backup and restores on a new device. The current item uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and does not restore. The plan changes this.

So the salt and the wrapped master key go to iCloud, inside the device backup. The PIN and the master key in plaintext never go to iCloud.

The item is also the PIN check. A wrong PIN gives a wrong KEK, and the AES-GCM tag check fails. The app keeps no separate PIN hash. A separate fast hash would be a faster brute-force oracle than the KDF, which would cancel the rounds. So no hash exists, and no hash can be reused as a key.

The version byte lets a later version change the rounds or the KDF. The unlock code reads the version and selects the parameters.

### 3.3 Vault file format

Cipher: AES-256-GCM with the master key. The app encrypts files in chunks. This keeps the memory at 2 MiB for a large video and gives random access for video playback.

| Bytes | Content |
| --- | --- |
| 0 to 3 | Magic `CVLT` |
| 4 to 11 | Plaintext length, UInt64 little-endian |
| 12 to 19 | File nonce prefix, 8 random bytes |
| 20 to end | Chunks |

Each chunk holds up to 1 MiB (1 048 576 bytes) of plaintext. On disk, a chunk is the ciphertext followed by the 16-byte tag. The last chunk can be shorter.

- Nonce of chunk `i`: file nonce prefix (8 bytes) + `i` as UInt32 big-endian (4 bytes). This is unique for each chunk of each file. A prefix collision between two files needs about 2^32 files.
- Additional authenticated data of each chunk: the 20-byte header. This detects a change of the length field and a truncation at a chunk boundary.
- Chunk `i` starts at offset `20 + i * (1 048 576 + 16)`. This gives random access.

The magic identifies the format. No media format starts with the bytes `CVLT`. File names and extensions do not change, so `VaultItem.isVideo` and the sort order stay as they are.

The write path writes to a hidden file `.<name>.part` in the vault directory, then renames it. A crash leaves a `.part` file and never a half file under the final name. The directory listing skips hidden files.

### 3.4 What the app decrypts, and when

| Place | Action |
| --- | --- |
| Grid thumbnail, photo | Decrypt the whole file to memory. Downsample with ImageIO to the thumbnail size. Keep the result in the memory cache. |
| Grid thumbnail, video | Ask `AVAssetImageGenerator` for the first frame. The asset reads decrypted byte ranges through the resource loader (section 5). |
| Viewer, photo | Decrypt the whole file to memory. Decode with ImageIO at not more than 4096 pixels, as now. |
| Viewer, video | `AVPlayer` reads decrypted byte ranges on demand through the resource loader. |
| Share | Decrypt to a temporary file in `tmp/share/`. See section 9, decision 1. |
| Import | Read the picker file in 1 MiB chunks. Encrypt each chunk. Write the encrypted file. The app writes no plaintext copy. |

`QLThumbnailGenerator` needs a file URL with plaintext, so the plan removes it. `ItemViewer` already has the ImageIO decode code. The plan moves that function to `VaultCrypto` and uses it for the grid and the viewer.

The app never writes a decrypted cache to disk. The vault locks after 60 seconds without touch, in the background, and on the lock button. The lock clears the master key from memory, so every decrypt stops.

### 3.5 Low entropy of the PIN

The PIN has 4 to 8 digits and the first digit is not 0. That gives 9 000 to 90 000 000 values. Rounds slow an attacker by a constant factor only.

Estimates from public hashcat benchmarks for PBKDF2-HMAC-SHA256 on one high-end GPU, at 200 000 rounds (about 40 000 guesses per second):

| PIN length | Values | Time to search all |
| --- | --- | --- |
| 4 | 9 000 | seconds |
| 6 | 900 000 | under a minute |
| 8 | 90 000 000 | under an hour |

No round count makes a 4-digit PIN safe against an offline attacker who holds the wrapped master key. The plan handles the low entropy with the location of the wrapped master key, not with the rounds:

- The wrapped master key is in the Keychain, not in a vault file. An attacker with the vault files alone has ciphertext under a random 256-bit key and no PIN oracle.
- The rounds still cost the attacker who holds the Keychain data. 200 000 is the highest value that keeps the `%` key fast (section 5, CalculatorView).
- A stronger in-app secret would be a passphrase. The PIN rules exclude it. The plan does not add one.
- Outside the app: Advanced Data Protection on the iCloud account makes the device backup end-to-end encrypted. Then Apple, and an account thief without a trusted device, cannot read the Keychain part of the backup.

### 3.6 Attack model

Attacker with the iCloud device backup and not the PIN. With standard data protection, this includes Apple, a party with legal access, and a person who controls the iCloud account.

The attacker can learn:

- The number of vault files.
- The plaintext size of each file, from the ciphertext size.
- The import date and time of each file, from the file name and from the file modification date.
- The media type of each file, from the file extension.
- The salt, the wrapped master key, and the KDF parameters.

The attacker cannot learn the content of any file without the master key. The attacker can search the PIN space offline against the wrapped master key at the rate in section 3.5.

Attacker with the vault files alone (a copy of the app container, or an unencrypted Finder backup): the same metadata, no PIN oracle, no key.

The plan does not hide file names, dates, or types. That would need opaque names and an encrypted index, which the goal does not need.

### 3.7 New device

The user restores the new device from the iCloud backup and opens the app. The Keychain item and the vault files are back. The app shows the calculator, not Set PIN. The user types the PIN and presses `%`. `PINStore.unlock` derives the KEK, unwraps the master key, and opens the vault. This is the same path as on the old device.

Data that must be in iCloud for this:

- The vault files in `Library/Application Support/Vault/`. iOS backs them up by default.
- The Keychain item `pin` with `kSecAttrAccessibleWhenUnlocked`. iOS backs it up by default.
- The `installed` flag in UserDefaults is in the backup too, but the app does not depend on it (section 5, App.swift).

Nothing else. The PIN comes from the user.

## 4. Xcode changes

None.

- Entitlements: none. The device backup needs no entitlement. iCloud Drive and CloudKit would need `com.apple.developer.icloud-container-identifiers` and `com.apple.developer.icloud-services`. The plan does not use them.
- Capabilities: none. Do not add the iCloud capability.
- Info.plist: none. The custom URL scheme `cvlt` for the resource loader is internal to `AVAssetResourceLoader` and needs no `CFBundleURLTypes` entry.
- Build settings: none. `IPHONEOS_DEPLOYMENT_TARGET` stays 17.0. `OSAllocatedUnfairLock` needs iOS 16.

Check: no vault file gets `isExcludedFromBackup`. The plan does not set it.

## 5. Code changes

### New: `CalculatorVault/Storage/VaultCrypto.swift`

`enum VaultCrypto`, CryptoKit only:

- `pbkdf2(pin: String, salt: Data) -> SymmetricKey`. HMAC-SHA256 loop, 200 000 rounds, 32 bytes.
- `wrap(_ master: SymmetricKey, pin: String) -> Data` and `unwrap(_ item: Data, pin: String) throws -> SymmetricKey`. Build and parse the Keychain item of section 3.2.
- `encrypt(from source: URL, to destination: URL, key: SymmetricKey) throws`. Chunked write through `.part` and rename. Sets `NSFileProtectionComplete` on the new file.
- `decryptAll(_ url: URL, key:) throws -> Data` and `decrypt(_ url: URL, key:, range: Range<UInt64>) throws -> Data`.
- `plaintextLength(_ url: URL) throws -> UInt64` (reads and checks the header).
- `decodeImage(_ data: Data, maxPixelSize: Int) -> UIImage?`. Moved from `ItemViewer.PhotoPage.load`.
- `selfTest()` for DEBUG: the PBKDF2 vector, a 2.5 MiB round trip with a range read, and a tamper test that must throw.

### New: `CalculatorVault/Storage/VaultAsset.swift`

- `final class VaultResourceLoader: NSObject, AVAssetResourceLoaderDelegate`. One instance per asset. For a content information request it sets the content type from the file extension, the plaintext length, and `isByteRangeAccessSupported = true`. For a data request it decrypts the requested range chunk by chunk, calls `respond(with:)` for each chunk, then `finishLoading()`. A request with `requestsAllDataToEndOfResource` gets the same loop until the end. If the master key is nil, it fails the request.
- `func makeAsset(for item: VaultItem) -> (AVURLAsset, VaultResourceLoader)`. Builds `cvlt://<fileName>` and sets the delegate on a background queue. The caller keeps the loader alive.

### `CalculatorVault/Security/PINStore.swift`

- Keep `isValid`. Keep the Keychain query. Change the accessibility to `kSecAttrAccessibleWhenUnlocked`.
- `save(_ pin:) throws -> SymmetricKey`: make a new master key, wrap it, write the item.
- `unlock(_ pin: String) -> SymmetricKey?` replaces `verify`. Steps: `isValid`, read the item, check the length and the version, unwrap. Any failure returns nil.
- `change(from old: String, to new: String) throws`: unlock with `old`, wrap with `new`, write the item. One Keychain write.
- `exists()` returns true only for a valid item, so a leftover old item leads to Set PIN. `delete()` stays.

### `CalculatorVault/Security/PINSetupView.swift`

- Setup: `PINStore.save(pin)` as now.
- Change: replace the `verify(current)` guard and `save(pin)` with `PINStore.change(from: current, to: pin)`. The error text for a wrong current PIN stays.

### `CalculatorVault/Calculator/CalculatorView.swift`

- `.percent`: `if let key = PINStore.unlock(engine.display) { engine = CalculatorEngine(); Session.shared.unlock(key) } else { engine.percent() }`.
- The KDF runs on the main thread for about 0.1 to 0.2 s. It runs only when the display shows a 4-to-8 digit integer without a leading 0, because `isValid` runs first. Mark this with a `ponytail:` comment. Move it to a `Task` if the lag shows.

### `CalculatorVault/App.swift`

- `Session`: add `masterKey` in an `OSAllocatedUnfairLock<SymmetricKey?>`. The import closure reads it from a background thread. `unlock(_ key:)` sets it. `lock()` clears it and removes `tmp/share/`.
- First-launch wipe: keep the `installed` flag. Add a second condition: delete the Keychain item only if the Vault directory does not exist. Check the path without the `vaultDirectory` global, because that global creates the directory. After an iCloud restore the directory exists, so the restored item stays even if the preferences are not yet restored.
- DEBUG: call `VaultCrypto.selfTest()` next to `CalculatorEngine.selfTest()`.

### `CalculatorVault/Storage/VaultStore.swift`

- `ImportedFile.init(copying:)`: replace `copyItem` with `VaultCrypto.encrypt(from: source, to: dest, key:)`. Read the key from `Session.shared.masterKey`. Throw if it is nil (the vault locked during the import). The picker file is a system temporary file; the app does not create it.
- `image(for:side:scale:)`: remove `QLThumbnailGenerator`. Photo: `decryptAll`, then `decodeImage(maxPixelSize: side * scale)`. Video: `AVAssetImageGenerator` on `makeAsset(for:)`, first frame. Keep the `NSCache`. Return nil on any error.
- `reload()`: also delete `.part` files.
- New `struct VaultExport: Transferable` with two `FileRepresentation` entries (`.movie` and `.image`) and `exportingCondition` on `isVideo`, the mirror of `ImportedFile`. The export closure decrypts to `tmp/share/<name>` with `NSFileProtectionComplete` and returns `SentTransferredFile`.
- Remove the `QuickLookThumbnailing` import. Add `AVFoundation`.

### `CalculatorVault/Vault/VaultView.swift`

- `ShareLink(items: selected.map(VaultExport.init))`.
- `Thumbnail`: add a `failed` state. When `image(for:)` returns nil, show `exclamationmark.triangle` on the gray square. This covers corrupt files and files from a lost key.

### `CalculatorVault/Vault/ItemViewer.swift`

- `PhotoPage`: `load` calls `VaultCrypto.decryptAll` and `decodeImage`. On error, show the text "Cannot open this item".
- `VideoPage`: `AVPlayer(playerItem: AVPlayerItem(asset:))` with `makeAsset(for: item)`. Keep the loader in a `@State`.
- `ShareLink(item: VaultExport(item: current))`.

### `README.md`

- PIN flow: describe the Keychain item and the unlock by unwrap.
- File storage: describe the encryption and the file format in short form.
- Add a "Backup" section: the iCloud device backup includes the vault and the Keychain item, and the same PIN opens the vault after a restore.
- Out of scope: remove "cloud backup". Keep "iCloud sync".

## 6. Migration

None. The task needs no backward compatibility. Uninstall the old build before you install the new one.

No code reads old data. Two checks keep a leftover install safe without extra code:

- `PINStore.exists()` accepts only the new item format. A leftover old item leads to Set PIN, and `save` overwrites it.
- A leftover plaintext file has no valid header. The grid shows the warning icon and the user can delete it.

## 7. Failure cases

| Case | Behavior |
| --- | --- |
| Wrong PIN | The AES-GCM tag check fails. `%` acts as the percent operator, as now. Each try costs about 0.2 s on the device. |
| No iCloud account, or iCloud Backup off | No backup exists. The vault works locally. The app does not detect this and shows nothing, because the disguise allows no iCloud UI. |
| iCloud full | iOS does not complete the backup and shows its own alert. The app is not involved. |
| Conflict between devices | None by design. Each device has its own vault, master key, and backup. A restore replaces the whole device content with one backup. There is no merge. |
| Partial upload | A restore uses the last complete backup. A vault file is either complete or absent, because the write goes through `.part` and rename. A `.part` file in a backup is deleted at the next vault open. |
| Corrupt ciphertext | A changed byte makes a chunk tag fail. Grid: warning icon. Viewer: "Cannot open this item"; a video shows the player error. Share: the export throws and the share sheet shows nothing. Delete works. |
| Restore without the Keychain item (unencrypted Finder backup to a different device, or a Keychain reset) | The app shows Set PIN. The user sets a PIN and the app makes a new master key. Old files show the warning icon, and the user can delete them. This is data loss. The goal covers the iCloud device backup only. |
| Lock or kill during an import | The key is nil or the process stops. The `.part` file stays, and `reload()` deletes it at the next vault open. No half file appears under a final name. The user imports again. |
| Lock during video playback | The loader fails the pending request. The vault view is gone, so the player is gone. |
| Low storage during import | The write throws. The `.part` file is deleted. No file appears in the grid. |

## 8. Manual tests on the simulator

Build and install. Scheme builds fail on this Mac; use the target build from the memory note:

```bash
xcodebuild -project CalculatorVault.xcodeproj -target CalculatorVault -sdk iphonesimulator -configuration Debug -arch arm64 SYMROOT="$PWD/build" build
```

```bash
UDID=FCEF65E2-4BC5-40AE-BBB6-D7625A0B32A8; xcrun simctl install $UDID build/Debug-iphonesimulator/CalculatorVault.app && xcrun simctl launch $UDID com.example.CalculatorVault
```

Container path:

```bash
C=$(xcrun simctl get_app_container $UDID com.example.CalculatorVault data); V="$C/Library/Application Support/Vault"
```

1. Fresh install. Uninstall the app and reset the Keychain (`xcrun simctl uninstall $UDID com.example.CalculatorVault`, `xcrun simctl keychain $UDID reset`). Install, launch. Set a PIN. Add a video with `xcrun simctl addmedia $UDID sample.mov`. Import two photos and the video. The grid shows three thumbnails.
2. Ciphertext on disk. `for f in "$V"/*; do head -c 4 "$f" | xxd; done` shows `CVLT` for each file. `file "$V"/*` says `data`, not JPEG or ISO Media.
3. View and play. Open a photo, zoom. Open the video, play. Share a photo; the share sheet shows the image. Lock. `ls "$C/tmp/share"` shows nothing.
4. Wrong PIN. Type another 4-digit number, press `%`. The display shows the percent result. Type the PIN, press `%`. The vault opens.
5. Change PIN. Note the file modification times (`ls -l "$V"`). Change the PIN. Lock. The old PIN gives a percent result. The new PIN opens the vault. The modification times are the same.
6. Interrupted import. Import a large video. While the import runs, run `xcrun simctl terminate $UDID com.example.CalculatorVault`. Launch and unlock. The grid does not show the video. `ls -a "$V"` shows no `.part` file and no half file.
7. Restore rehearsal. Copy `"$V"` to a folder outside the container. Uninstall the app; the simulator Keychain keeps the item. Install the new build. Compute `C` again, then copy the folder back to `"$C/Library/Application Support/Vault"` before the first launch. Launch. The calculator shows, not Set PIN. Type the PIN, press `%`. All items open. This checks the first-launch guard, the migratory item, and the files. If Set PIN shows, the simulator dropped the item; then test 9 covers that path.
8. Corrupt file. `printf '\xff' | dd of="$V/<file>" bs=1 seek=40 conv=notrunc`. Unlock. The item shows the warning icon. Open it: "Cannot open this item". Delete it.
9. Lost Keychain. `xcrun simctl keychain $UDID reset`, launch. Set PIN shows. Set a PIN. All old items show the warning icon. Delete them.
10. Self-test. The DEBUG build runs `VaultCrypto.selfTest()` at launch. A failed assert stops the launch.

The simulator has no iCloud backup. Test the real restore on a device: back up, erase the device, restore from iCloud, launch, type the PIN.

## 9. Decisions

1. Decided: Share writes a temporary plaintext file. The system share sheet needs a file URL for a video, and the in-memory path for a photo re-encodes the image. Share decrypts to `tmp/share/` with `NSFileProtectionComplete`. The app deletes the copy at lock and at the next share. This is the one exception to "no plaintext file after import".
2. Decided: 200 000 rounds. Rounds scale the attacker cost and the unlock delay by the same factor. One more PIN digit gives 10x at no delay. A later change needs a version bump and a re-wrap at the next unlock.

## 10. Not in this plan

- Thumbnail cache on disk (the existing `ponytail:` note stays).
- Opaque file names and an encrypted index.
- A passphrase or Face ID as a stronger secret.
- iCloud sync between devices.
