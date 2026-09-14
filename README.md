# CalculatorVault

A native iOS calculator with a hidden photo and video vault.
SwiftUI, iOS 17+, Xcode 26+.

Type the PIN on the calculator and press `%` to open the vault.

## Screenshots

![Calculator](docs/screenshots/calculator.png)
![Vault](docs/screenshots/vault.png)
![Set PIN](docs/screenshots/set-pin.png)

## Install

TestFlight: internal testers only. There is no public link yet.

Build from source:

1. Open `CalculatorVault.xcodeproj` in Xcode 26 or later.
2. Run the `CalculatorVault` scheme on an iPhone with iOS 17 or later, or on a simulator.

## Open the vault

1. On the first launch, the app shows the **Set PIN** screen. Enter a PIN of 4 to 8 digits and confirm it.
   The first digit must not be 0, because the calculator drops leading zeros.
2. To open the vault, type the PIN and press `%`. With a wrong PIN, `%` works as the percent operator.
3. To lock the vault, tap the lock button. The vault also locks after the lock timeout.
   See [Lock behavior](#lock-behavior).
4. To change the PIN, open the vault, tap the `...` menu, tap **Settings**, and tap **Change PIN**.
5. To use Face ID, open the vault, tap the `...` menu, tap **Settings**, and turn on **Face ID**.
   Face ID is off by default. When it is on, the app asks for Face ID after the correct PIN.
   If Face ID fails, you can type the device passcode.
6. To set the lock timeout, open the vault, tap the `...` menu, tap **Settings**, and tap **Lock Timeout**.
   The default is **Instant**.

There is no PIN recovery. If you forget the PIN, the vault files are lost.

## Threat model

The app protects the vault files and the master key.

The app protects against:

- a person who holds the unlocked phone and does not know the PIN,
- with Face ID on, a person who holds the unlocked phone and knows the PIN, but not the device passcode,
- a person who looks at the app switcher,
- a person who reads the app files on a locked device,
- a person who reads the iCloud backup.

The app does not protect against:

- a person with the unlocked phone who finds the app on the home screen.
  The app looks like a calculator, but it does not hide that it exists.
- a person who extracts the Keychain item and tries PINs offline. A 4-digit PIN has 10 000 values.
  Face ID does not prevent this.
- malware or a jailbroken device. Decrypted data is in memory while the vault is open.
- with a lock timeout other than **Instant**, a person who holds the unlocked phone before the lock timeout ends.

A hidden vault is not a substitute for the device passcode and iOS data protection.
The share copy in `tmp/share/` is plaintext until the next lock.

Use a device passcode, a long PIN, and Advanced Data Protection on the iCloud account.

## Security design

The app makes one random 256-bit master key. The PIN wraps the master key.
The app encrypts each file under the master key. The app never stores the PIN.

Code: `CalculatorVault/Security/` holds the PIN and Keychain code.
`CalculatorVault/Storage/` holds the encryption and file code.

### Key management

- The app derives a key from the PIN with PBKDF2-HMAC-SHA256, 200 000 rounds, and a random 16-byte salt.
- The app wraps the master key with AES-256-GCM under the derived key.
- The Keychain item holds a version byte, the salt, and the wrapped master key.
- A wrong PIN fails the AES-GCM tag check. Each try costs about 0.2 s.
- Change PIN wraps the same master key under the new PIN. The vault files do not change.

### Face ID

- Face ID is off by default. The setting is in `UserDefaults`, so the device backup includes it.
- When Face ID is on, the app runs the `deviceOwnerAuthentication` policy after a correct PIN.
  The vault opens only when the policy passes.
- The system tries Face ID first. If Face ID fails, is locked, or is not set up, the system asks for the device passcode.
- A device without a passcode has no Face ID, so the check passes there.
  To remove the passcode, a person must know it. That person can also type the passcode at the check.
- Face ID does not change the encryption. The PIN alone unwraps the master key.

### File format

- Header: the magic `CVLT`, the plaintext length (UInt64), and an 8-byte nonce prefix.
- Chunks: up to 1 MiB of plaintext each, encrypted with AES-256-GCM, followed by a 16-byte tag.
- The nonce of a chunk is the prefix plus the chunk index.
- The header is the additional authenticated data of every chunk.
- The app writes to a hidden `.part` file and renames it when the write completes.
  The file keeps its extension.

### Data at rest and in memory

- Import uses the system `PhotosPicker`. The app does not request access to the photo library.
- The vault files are in `Application Support/Vault/`. The directory and every file use `NSFileProtectionComplete`.
- The app writes no plaintext copy. Thumbnails and photos come from ImageIO on decrypted data in memory.
  Videos play through an `AVAssetResourceLoader` delegate that decrypts byte ranges on demand.
- Share is the one exception. It decrypts the item to `tmp/share/`. The app deletes that copy at the next lock.

### Lock behavior

The vault locks when you tap the lock button and after the lock timeout. A running video does not count as a touch.

- **Instant**: the vault locks when you open the app switcher and when the app goes to the background.
  It also locks after 1 minute with no touch. Control Center and Notification Center do not lock the vault.
- **1 minute** to **1 hour**: the vault locks after that time with no touch. The time also counts while you use other apps.
  When you return to the app after that time, the app locks the vault before it shows the vault.

iOS makes the app inactive for the app switcher, Control Center, and Notification Center.
iOS does not tell the app which one it is. The app switcher gesture sends a touch on the home indicator to the app.
The Control Center and Notification Center gestures send no touch.
With **Instant**, the app locks the vault when it becomes inactive and the last touch was on the home indicator.
In these conditions, the app cannot see that touch, so the vault locks each time the app becomes inactive:

- on an iPhone with a Home button,
- with VoiceOver, Switch Control, or AssistiveTouch on,
- while the keyboard, the photo picker, or the share sheet shows.

Voice Control can open the app switcher with no touch. Then the vault stays open until the app goes to the background,
or until 1 minute passes with no touch.

When the app becomes inactive, a calculator view covers the window, so the app switcher does not show the vault.
At the lock, the app clears the master key and empties the in-memory cache of thumbnails and previews.
It also closes the viewer, the sheets, and the pickers with no animation.

### Backup, restore, and reinstall

- The iCloud device backup includes the vault files and the Keychain item. The app needs no entitlement.
- The backup holds only ciphertext, the salt, and the wrapped master key.
- After a restore on a new device, type the same PIN and press `%`.
- Advanced Data Protection on the iCloud account makes the backup end-to-end encrypted.
- The Keychain survives a reinstall. The app clears the old item on the first launch after an install,
  so the Set PIN screen shows again. It keeps the item when the vault directory exists, because that is a restore.

## Project layout

- `CalculatorVault/Calculator/` — calculator engine and view.
- `CalculatorVault/Vault/` — gallery grid, settings page, and full-screen viewer.
- `CalculatorVault/Security/` — Keychain PIN store and PIN setup form.
- `CalculatorVault/Storage/` — vault directory, encryption, import, delete, thumbnails, video loader.

## Contributing

- Open an issue before you start a large change.
- Build the app as described in [Install](#install).
- Open a pull request against `main`.

### Code checks

A Git pre-commit hook checks the Swift files and the String Catalogs before each commit. [Lefthook](https://lefthook.dev) runs these tools in this order:

- [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) formats the staged Swift files and adds the changes to the commit.
- [SwiftLint](https://github.com/realm/SwiftLint) finds style and code problems. A warning also stops the commit.
- [Periphery](https://github.com/peripheryapp/periphery) builds the app and the tests, and finds unused code.
- `scripts/check-localization-keys.py` checks `Localizable.xcstrings` against the code. See [Localization](#localization).

1. Install the tools.

   ```bash
   brew install swiftformat swiftlint periphery lefthook
   ```

2. Install the hook in your clone.

   ```bash
   lefthook install
   ```

- Run time: about 5 to 15 seconds for a commit that changes Swift files or String Catalogs. Other commits skip the checks.
- The configuration is in `.swiftformat`, `.swiftlint.yml`, `.periphery.yml`, and `lefthook.yml`.
- The hook builds the app into `build/periphery`. The default build cache of Periphery is the same for all clones of the project, and other clones cause false results.
- When you commit part of a file, Lefthook removes the other changes of that file until the hook ends. Then it puts them back.
- If Periphery reports code that the app uses, add `// periphery:ignore` to the declaration.
- To skip the checks for one commit, use `git commit --no-verify`.

### Localization

The app has English text only. `CalculatorVault/Localizable.xcstrings` contains the text of the app.
`CalculatorVault/InfoPlist.xcstrings` contains the Info.plist text, for example `CFBundleDisplayName`. Apple sets these keys.

Each string has a semantic key, for example `settings.title`. The rules for keys are:

- Write the key as lowerCamelCase segments with dots between them. First write the screen or the feature, then the element.
- Use one key for one meaning. If two texts are equal but have a different function, use two keys.
- The catalog is the only place for the English text and the comment for translators. The Swift code contains no English text.
- The build makes one `LocalizedStringResource` symbol for each key. It removes the dots and makes the first letter of each segment uppercase.
  For example, `pinSetup.error.wrongCurrentPIN` becomes `.pinSetupErrorWrongCurrentPIN`.
- A key with `%lld` becomes a function with an `Int` argument, for example `.vaultSelectionTitle(selected.count)`.

To add a string:

1. Add an entry to `Localizable.xcstrings`. Give it `"extractionState" : "manual"`, a comment, and an `en` value with the state `translated`.
   Without `manual`, the build makes no symbol. Without a value, the app shows the key.
2. Use the symbol in the code: `Text(.settingsTitle)`, `Button(.vaultToolbarLock) { ... }`, or `.navigationTitle(.vaultTitle)`.
   For a `String` parameter, use `String(localized: .calculatorError)`.
3. For inflection, use `String(AttributedString(localized: .vaultDeleteTitle(count)).characters)`. `String(localized:)` does not apply the `^[...](inflect: true)` markup.
4. Do not use a string literal as a key or as text, for example `Text("settings.title")` or `error = "Save PIN"`. The code compiles, but the app shows the literal.

To rename a key, change the key in `Localizable.xcstrings` and the symbol at all call sites in the same commit.
Stage all these files. The hook builds the files on disk, so it does not find a commit that has only a part of the rename.
Do not rename a key to a key that the catalog already has. JSON does not stop two equal keys, and the build keeps only the first entry.

To change the English text, change only the `en` value in the catalog.
If the new text adds or removes a format specifier such as `%lld`, the symbol changes between a variable and a function. Then change the call sites too.

To remove a string, remove the call sites and the catalog entry in the same commit. The build puts all manual entries into the app, also unused entries.

If the build shows "has no member", "cannot be resolved without a contextual type", or "unable to type-check this expression in reasonable time", look for a symbol that has no catalog key.
The last message can show a different line in the `VaultView` body.

The pre-commit hook runs `python3 scripts/check-localization-keys.py` after the build. The script stops the commit when:

- a key is not dotted lowerCamelCase, or the catalog has the same key two times
- an entry is not manual, or has no `en` value, or has no comment
- no Swift file uses the symbol of a key (code in comments does not count)
- the Swift code has a localizable string literal. The script reads the `.stringsdata` files of the build in `build/periphery`.

Run the export only after you change an Info.plist text. The export must not add entries to `Localizable.xcstrings`.

```bash
xcodebuild -exportLocalizations -project CalculatorVault.xcodeproj -scheme CalculatorVault -derivedDataPath build/l10n -localizationPath build/l10n/export -exportLanguage en
```

To find text that the app does not localize, run the app with the `-NSAccentuateLocalizedStrings YES` argument.
Localized text shows accents. Text without accents does not go through the catalog.
With this argument, a text with `%lld` shows the accented format specifier instead of the number. Without the argument, the text is correct.
The calculator keys and the number on the display do not use the catalog.

### Performance tests

The `CalculatorVaultTests` target measures how fast the app opens and shows large vaults.
The tests use vaults with 1000, 2000, and 10 000 photos, and videos of 100 MB, 500 MB, and 1000 MB.
They measure the time and the peak memory. They have no pass or fail limits, so a test fails only when a step fails.

1. Create a new iPhone 17 simulator. Do not use a simulator that has your own test data.

   ```bash
   xcrun simctl create "CalculatorVault Tests" "iPhone 17"
   ```

2. Run the tests with the Release configuration, because the Debug configuration does not optimize the code.

   ```bash
   xcodebuild test -project CalculatorVault.xcodeproj -scheme CalculatorVault -destination "platform=iOS Simulator,name=CalculatorVault Tests" -configuration Release ENABLE_TESTABILITY=YES
   ```

3. Find the results in the output lines that contain `measured`.
   The results of the run on 2026-09-14 are in [docs/performance-measurements.md](docs/performance-measurements.md).

- Run time: about 15 minutes on a Mac with an Apple M3 Pro chip.
  The first run on a new simulator takes about 5 minutes more, because the tests make the test videos.
- Free disk space: 4 GB. The test videos use 1.6 GB. They stay in `Library/Caches` of the app for the next runs.
  The tests delete all other test files at the end.
- Free memory: 4 GB. The full pass over the thumbnails stops when the app uses 4 GB,
  because a pass over 10 000 photos needs about 30 GB.
- The tests keep all test files in a temporary directory.
  They do not read, write, or delete the files in `Application Support/Vault/`.

## Report a security issue

Do not open a public issue for a vulnerability.
Use **Report a vulnerability** on the Security tab of this repository.
Include the iOS version, the steps, and the impact. You get a reply within 14 days.
There is no bug bounty.

## License

GPL-3.0, see `LICENSE`.
