# Performance measurements

This document gives the results of the performance tests in `CalculatorVaultTests`.
To run the tests, see [Performance tests](../README.md#performance-tests) in the README.

## Test conditions

- Date: 2026-09-14, 03:26 to 03:40 CEST.
- Code: `CalculatorVault/Storage/` as in commit `a3f0d56`, and the `directory` parameter of `VaultStore` that the tests add.
- Destination: iPhone 17 simulator "CalculatorVault Tests", iOS 26.5 (23F77).
- Mac: Apple M3 Pro chip, 18 GB of memory, macOS 26.6.2, Xcode 26.6 (17F113).
- Build: Release configuration with `ENABLE_TESTABILITY=YES`.
- Result: 21 tests, 0 failures. The run took 14 minutes 17 seconds, with the test videos already in the cache.

## Test data

- Photos: 10 generated 12 MP photos (4000 x 3000 pixels) in HEIC, 2 to 4 MB each.
  The test encrypts each photo one time. Then it copies the encrypted files until it has 1000, 2000, or 10 000 items.
- Videos: H.264, 3840 x 2160 pixels, 30 fps, 50 Mbit/s, with the `moov` atom at the end of the file.
  The files are 102 MB, 506 MB, and 1009 MB.
- In this document, 1 MB is 1 000 000 bytes.

## How to read the tables

- Time is the average of the XCTest clock metric.
- Peak memory is the highest physical footprint of the test host app during the measurement.
  It includes about 40 to 50 MB that the app uses before the measurement starts.
- RSD is the relative standard deviation.
- Runs is the number of measured runs. Before these runs, XCTest runs each block one time and discards the result.
- The numbers do not include the setup: the data generation, the step that empties the cache, and the deletion of the previous output.

## Photos

| Case | Items | Time | Time RSD | Peak memory | Memory RSD | Runs |
|---|---:|---|---:|---:|---:|---:|
| Open | 1 000 | 39 ms | 0.7 % | 54 MB | 0.4 % | 5 |
| Open | 2 000 | 80 ms | 0.3 % | 54 MB | 0.0 % | 5 |
| Open | 10 000 | 358 ms | 0.2 % | 54 MB | 0.0 % | 5 |
| First screen | 1 000 | 1.306 s | 2.3 % | 111 MB | 0.3 % | 5 |
| First screen | 2 000 | 1.298 s | 2.4 % | 112 MB | 0.0 % | 5 |
| First screen | 10 000 | 1.299 s | 2.8 % | 116 MB | 0.0 % | 5 |
| Full pass | 1 000 | 72.55 s (1000 items, 72.6 ms per item) | 0.4 % | 3 298 MB | 0.0 % | 3 |
| Full pass | 2 000 | 88.06 s (1217 items, 72.4 ms per item) | 0.4 % | 4 003 MB | 0.0 % | 3 |
| Full pass | 10 000 | 88.63 s (1215 items, 72.9 ms per item) | 0.8 % | 4 003 MB | 0.0 % | 3 |

- Open: `VaultStore` lists and sorts the files.
- First screen: `VaultStore.image(for:side:scale:)` for the first 18 items, with side 150 and scale 3, one at a time.
- Full pass: the thumbnails of all items, one at a time. The pass stops when the app uses 4 GB.
  With 2000 and 10 000 items, the pass stopped after 1217 and 1215 items. The time per item uses these numbers.

## Videos

| Case | Size | Time | Time RSD | Peak memory | Memory RSD | Runs |
|---|---:|---|---:|---:|---:|---:|
| Import | 100 MB | 137 ms (745 MB/s) | 46.9 % | 74 MB | 0.0 % | 5 |
| Import | 500 MB | 412 ms (1229 MB/s) | 28.2 % | 175 MB | 0.0 % | 5 |
| Import | 1000 MB | 750 ms (1346 MB/s) | 22.2 % | 302 MB | 0.1 % | 5 |
| Grid thumbnail | 100 MB | 75 ms | 15.2 % | 145 MB | 0.7 % | 5 |
| Grid thumbnail | 500 MB | 296 ms | 26.1 % | 553 MB | 0.5 % | 5 |
| Grid thumbnail | 1000 MB | 709 ms | 6.6 % | 1 184 MB | 19.7 % | 5 |
| Playback start | 100 MB | 39 ms | 0.7 % | 144 MB | 0.0 % | 5 |
| Playback start | 500 MB | 174 ms | 2.6 % | 549 MB | 0.1 % | 5 |
| Playback start | 1000 MB | 368 ms | 3.9 % | 1 051 MB | 0.0 % | 5 |
| Seek | 100 MB | 64 ms | 1.6 % | 150 MB | 4.3 % | 5 |
| Seek | 500 MB | 211 ms | 1.6 % | 552 MB | 1.1 % | 5 |
| Seek | 1000 MB | 417 ms | 6.4 % | 1 052 MB | 0.0 % | 5 |

- Import: `VaultCrypto.encrypt(from:to:key:)`. MB/s is the size of the file divided by the time.
- Grid thumbnail: `VaultStore.image(for:side:scale:)` with side 150 and scale 3.
- Playback start: from a new `AVPlayer` with an `AVPlayerItem` on `makeAsset(for:)` until the item is ready to play.
- Seek: a seek to 90 % of the duration, right after the item is ready to play, until the seek completes.

## Problems

Each problem gives the measurement, the probable cause in the code, and the evidence.
One-time probe tests supplied the evidence. The probe tests are not in the repository.

### 1. The thumbnail cache keeps about 3.2 MB for each thumbnail

The full pass of 1000 photos used 3.3 GB. After the pass, the app still used 3.2 GB more than before the pass.
At this rate, 10 000 photos need about 32 GB. An iPhone 17 has 8 GB of memory.

Probable cause: `VaultStore.cache` has no count limit and no cost limit.
Each image from `VaultCrypto.decodeImage` keeps the full decrypted photo in memory.

Evidence: a kept thumbnail used 2.29 MB for a 2.27 MB photo. A redrawn copy of the same thumbnail used 0.03 MB.
The option `kCGImageSourceShouldCacheImmediately` did not change the result.
A full pass without the 4 GB stop reached 26 GB, and the Mac almost used all of its swap space.

### 2. Each thumbnail takes 73 ms after each unlock

The full pass took 72.6 ms for each photo. At this rate, 10 000 photos take about 12 minutes.
The app does this work again after each unlock.

Probable cause: `VaultStore.image(for:side:scale:)` decrypts the full file and decodes the full 12 MP photo for each thumbnail.
The cache is in memory only, and `Session.lock` empties it.

Note: the simulator decodes HEIC in software. An iPhone can be faster.

### 3. Thumbnails that start at the same time can stop all decoding

The test started the 18 first-screen thumbnails at the same time. After 12 minutes, no thumbnail was complete,
and the app used no CPU. One at a time, the same 18 thumbnails take 1.3 s.
For this reason, the First screen test makes the thumbnails one at a time.

Probable cause: `VaultStore.image(for:side:scale:)` decodes in `Task.detached`, and the decode blocks its thread.
The HEIC decoder waits for tile work on other threads. When the decodes block all threads of the Swift concurrency pool,
no thread is free for the tile work. The grid starts one such task for each visible `Thumbnail`.

Evidence: a stack sample showed all 12 threads of the pool in `VTTileDecompressionSessionDecodeTile`, in `dispatch_semaphore_wait`.
This result is from the test process, not from the vault screen of the app.
An iPhone decodes HEIC in hardware, and the result can be different there.

### 4. The grid thumbnail of a video decrypts the full file

The grid thumbnail of the 1000 MB video took 709 ms and used 1.18 GB of memory. The time and the memory increase with the size of the file.

Probable cause: the `moov` atom is at the end of the file. AVFoundation first asks for all bytes from offset 0 to the end.
`VaultResourceLoader` supplies the full range in one loop on a serial queue. AVFoundation does not cancel this request,
so the request for the `moov` atom waits until the loader decrypts the full file.
The loop in `VaultCrypto.decrypt` has no autorelease pool, so the app keeps all read buffers until the request ends.

Evidence: a logging probe showed a first request of 1 009 309 336 bytes. The loader supplied all bytes, and AVFoundation did not cancel the request.
The decryption of 1 GB with `VaultCrypto.decrypt` used 1.17 GB at the peak.
A copy of the loop with an autorelease pool for each chunk used 67 MB.

### 5. Playback start decrypts the full file two times

Playback start of the 1000 MB video took 368 ms and used 1.05 GB of memory. The time and the memory increase with the size of the file.

Probable cause: the cause of problem 4 applies. Also, right after the item is ready to play, AVFoundation asks for all bytes from 1 MiB to the end.
The loader then decrypts the full file a second time.

Evidence: the logging probe showed this second request of 1 008 140 288 bytes. The loader supplied all bytes.

### 6. A seek right after playback start waits for the second full request

A seek to 90 % of the 1000 MB video took 417 ms. The time increases with the size of the file.

Probable cause: the seek starts while the loader supplies the second request from problem 5.
The request for the seek position waits in the serial queue until that request ends.

Evidence: with an idle loader, the same seek took 70 to 90 ms.

### 7. Import keeps memory that increases with the size of the file

Import of the 1000 MB video used 302 MB at the peak. After `VaultCrypto.encrypt` returned, the app still used 245 MB more than before.
The speed of 745 to 1346 MB/s is not a problem.

Probable cause: the loop in `VaultCrypto.encrypt` has no autorelease pool.
The app releases the buffers from `FileHandle.read(upToCount:)` only when the autorelease pool of the caller empties.

Evidence: a copy of the loop with an autorelease pool for each chunk used 67 MB.

Note: the time RSD of 22 to 47 % probably comes from the disk writes of the Mac.

### 8. Open blocks the main actor for 358 ms with 10 000 items

Open took 358 ms for 10 000 photos. `VaultStore` runs on the main actor, so the app does not respond to touches during this time.

Probable cause: the sort in `VaultStore.reload` gets `lastPathComponent` two times for each comparison.

Evidence: for 10 000 files, the sort took 308 ms of 359 ms. Each directory listing took 12 ms.
A sort that gets each name one time took 94 ms.

## Notes on the test design

- The First screen test makes the thumbnails one at a time, because of problem 3.
- The full pass stops when the app uses 4 GB, half the memory of an iPhone 17. This stop prevents problem 1 from filling the memory of the Mac.
  In the first run, which XCTest discards, the full pass makes only 18 thumbnails, because a full pass takes minutes.
- The player item has an `AVPlayerItemVideoOutput`, because `VideoPlayer` shows the frames in the app.
  Without a video output, a seek completed in 0.4 ms and loaded no data.
- The tests set `Session.shared.unlocked` to false after `Session.shared.unlock`.
  If they do not, the host app opens `VaultView`, which reads `Application Support/Vault/`.
  When these measurements were made, `VaultView` also deleted the `.part` files there. A test on a separate simulator with a PIN and a `.part` file confirmed this.
  Now the launch of the app deletes the `.part` files, before the tests start.
