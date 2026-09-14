# Performance measurements

This document gives the results of the performance tests in `CalculatorVaultTests`.
To run the tests, see [Performance tests](../README.md#performance-tests) in the README.

## Test conditions

- Date: 2026-09-14, 18:48 to 18:51 CEST.
- Code: the commit "Store encrypted grid thumbnails in Library/Caches".
  The first measurements, before the fixes, used `CalculatorVault/Storage/` as in commit `a3f0d56`.
- Destination: iPhone 17 simulator "CalculatorVault Tests", iOS 26.5 (23F77).
- Mac: Apple M3 Pro chip, 18 GB of memory, macOS 26.6.2, Xcode 26.6 (17F113).
- Build: Release configuration with `ENABLE_TESTABILITY=YES`.
- Result: 23 tests, 0 failures. The tests took 2 minutes 42 seconds, with the test videos already in the cache.
  The first run, before the fixes, took 14 minutes 17 seconds.

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
- The Before column gives the time and the peak memory of the first run, before the fixes. A dash means that the test did not exist.

## Photos

| Case | Items | Time | Time RSD | Peak memory | Memory RSD | Runs | Before |
|---|---:|---|---:|---:|---:|---:|---|
| Open | 1 000 | 12 ms | 0.6 % | 57 MB | 0.0 % | 5 | 39 ms, 54 MB |
| Open | 2 000 | 25 ms | 0.8 % | 57 MB | 0.0 % | 5 | 80 ms, 54 MB |
| Open | 10 000 | 114 ms | 2.2 % | 57 MB | 0.1 % | 5 | 358 ms, 54 MB |
| First screen | 1 000 | 13 ms | 2.6 % | 57 MB | 0.0 % | 5 | 1.306 s, 111 MB |
| First screen | 2 000 | 13 ms | 4.7 % | 58 MB | 0.4 % | 5 | 1.298 s, 112 MB |
| First screen | 10 000 | 13 ms | 4.0 % | 64 MB | 0.0 % | 5 | 1.299 s, 116 MB |
| Full pass | 1 000 | 1.512 s (1000 items, 1.5 ms per item) | 7.4 % | 58 MB | 0.3 % | 3 | 72.6 ms per item, 3 298 MB |
| Full pass | 2 000 | 2.866 s (2000 items, 1.4 ms per item) | 5.8 % | 58 MB | 0.8 % | 3 | 72.4 ms per item, 4 003 MB |
| Full pass | 10 000 | 16.20 s (10 000 items, 1.6 ms per item) | 2.3 % | 66 MB | 0.3 % | 3 | 72.9 ms per item, 4 003 MB |
| No thumbnails | 1 000 | 16.53 s (200 items, 82.6 ms per item) | 1.4 % | 71 MB | 1.0 % | 3 | — |

- Open: `VaultStore` lists and sorts the files.
- First screen: `VaultStore.thumbnail(for:)` for the first 18 items, with calls that start at the same time, as the grid does.
  The thumbnail files exist.
- Full pass: `VaultStore.thumbnail(for:)` for all items, one at a time, from the thumbnail files.
  The pass stops when the app uses 4 GB. Before the fixes, the pass stopped after 1217 and 1215 items with 2000 and 10 000 items.
- No thumbnails: `VaultStore.thumbnail(for:)` for the first 200 of 1000 items, with calls that start at the same time.
  Before each run, the test deletes their thumbnail files. So each call decrypts and decodes the photo and writes the thumbnail file.
  This is the first scroll after the update, after a restore, or after iOS deletes `Library/Caches`.

## Videos

| Case | Size | Time | Time RSD | Peak memory | Memory RSD | Runs | Before |
|---|---:|---|---:|---:|---:|---:|---|
| Import | 100 MB | 166 ms (614 MB/s) | 39.8 % | 55 MB | 0.1 % | 5 | 137 ms, 74 MB |
| Import | 500 MB | 851 ms (595 MB/s) | 64.6 % | 56 MB | 1.3 % | 5 | 412 ms, 175 MB |
| Import | 1000 MB | 600 ms (1682 MB/s) | 8.3 % | 56 MB | 1.7 % | 5 | 750 ms, 302 MB |
| Grid thumbnail | 100 MB | 42 ms | 3.3 % | 88 MB | 0.6 % | 5 | 75 ms, 145 MB |
| Grid thumbnail | 500 MB | 45 ms | 8.9 % | 88 MB | 0.1 % | 5 | 296 ms, 553 MB |
| Grid thumbnail | 1000 MB | 43 ms | 4.2 % | 88 MB | 0.2 % | 5 | 709 ms, 1 184 MB |
| Playback start | 100 MB | 22 ms | 31.9 % | 98 MB | 6.4 % | 5 | 39 ms, 144 MB |
| Playback start | 500 MB | 18 ms | 14.4 % | 96 MB | 8.9 % | 5 | 174 ms, 549 MB |
| Playback start | 1000 MB | 21 ms | 37.9 % | 99 MB | 17.8 % | 5 | 368 ms, 1 051 MB |
| Seek | 100 MB | 55 ms | 1.2 % | 95 MB | 0.4 % | 5 | 64 ms, 150 MB |
| Seek | 500 MB | 56 ms | 1.6 % | 106 MB | 0.0 % | 5 | 211 ms, 552 MB |
| Seek | 1000 MB | 57 ms | 3.0 % | 105 MB | 0.0 % | 5 | 417 ms, 1 052 MB |

- Import: `VaultCrypto.encrypt(from:to:key:)`. MB/s is the size of the file divided by the time.
- Grid thumbnail: `VaultStore.thumbnail(for:)` reads the first frame and writes the thumbnail file.
  Before each run, the test deletes the thumbnail file, so the test measures the first time.
- Playback start: from a new `AVPlayer` with an `AVPlayerItem` on `makeAsset(for:)` until the item is ready to play.
- Seek: a seek to 90 % of the duration, right after the item is ready to play, until the seek completes.

## Problems

Each problem gives the measurement of the first run, the probable cause in the code, and the evidence.
One-time probe tests supplied the evidence. The probe tests are not in the repository.
The "Fixed in" line of each problem gives the commits that fixed it. The tables above give the results after these commits.

### 1. The thumbnail cache keeps about 3.2 MB for each thumbnail

The full pass of 1000 photos used 3.3 GB. After the pass, the app still used 3.2 GB more than before the pass.
At this rate, 10 000 photos need about 32 GB. An iPhone 17 has 8 GB of memory.

Probable cause: `VaultStore.cache` has no count limit and no cost limit.
Each image from `VaultCrypto.decodeImage` keeps the full decrypted photo in memory.

Evidence: a kept thumbnail used 2.29 MB for a 2.27 MB photo. A redrawn copy of the same thumbnail used 0.03 MB.
The option `kCGImageSourceShouldCacheImmediately` did not change the result.
A full pass without the 4 GB stop reached 26 GB, and the Mac almost used all of its swap space.

Fixed in: the commits "Limit the image cache to 50 images" and "Store encrypted grid thumbnails in Library/Caches".

### 2. Each thumbnail takes 73 ms after each unlock

The full pass took 72.6 ms for each photo. At this rate, 10 000 photos take about 12 minutes.
The app does this work again after each unlock.

Probable cause: `VaultStore.image(for:side:scale:)` decrypts the full file and decodes the full 12 MP photo for each thumbnail.
The cache is in memory only, and `Session.lock` empties it.

Note: the simulator decodes HEIC in software. An iPhone can be faster.

Fixed in: the commit "Store encrypted grid thumbnails in Library/Caches".

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

Fixed in: the commit "Decode images on a queue with two operations instead of detached tasks".

### 4. The grid thumbnail of a video decrypts the full file

The grid thumbnail of the 1000 MB video took 709 ms and used 1.18 GB of memory. The time and the memory increase with the size of the file.

Probable cause: the `moov` atom is at the end of the file. AVFoundation first asks for all bytes from offset 0 to the end.
`VaultResourceLoader` supplies the full range in one loop on a serial queue. AVFoundation does not cancel this request,
so the request for the `moov` atom waits until the loader decrypts the full file.
The loop in `VaultCrypto.decrypt` has no autorelease pool, so the app keeps all read buffers until the request ends.

Evidence: a logging probe showed a first request of 1 009 309 336 bytes. The loader supplied all bytes, and AVFoundation did not cancel the request.
The decryption of 1 GB with `VaultCrypto.decrypt` used 1.17 GB at the peak.
A copy of the loop with an autorelease pool for each chunk used 67 MB.

Fixed in: the commits "Release the chunk buffers after each chunk in encrypt and decrypt" and "Serve video loader requests off the delegate queue".

### 5. Playback start decrypts the full file two times

Playback start of the 1000 MB video took 368 ms and used 1.05 GB of memory. The time and the memory increase with the size of the file.

Probable cause: the cause of problem 4 applies. Also, right after the item is ready to play, AVFoundation asks for all bytes from 1 MiB to the end.
The loader then decrypts the full file a second time.

Evidence: the logging probe showed this second request of 1 008 140 288 bytes. The loader supplied all bytes.

Fixed in: the commits "Release the chunk buffers after each chunk in encrypt and decrypt" and "Serve video loader requests off the delegate queue".

### 6. A seek right after playback start waits for the second full request

A seek to 90 % of the 1000 MB video took 417 ms. The time increases with the size of the file.

Probable cause: the seek starts while the loader supplies the second request from problem 5.
The request for the seek position waits in the serial queue until that request ends.

Evidence: with an idle loader, the same seek took 70 to 90 ms.

Fixed in: the commit "Serve video loader requests off the delegate queue".

### 7. Import keeps memory that increases with the size of the file

Import of the 1000 MB video used 302 MB at the peak. After `VaultCrypto.encrypt` returned, the app still used 245 MB more than before.
The speed of 745 to 1346 MB/s is not a problem.

Probable cause: the loop in `VaultCrypto.encrypt` has no autorelease pool.
The app releases the buffers from `FileHandle.read(upToCount:)` only when the autorelease pool of the caller empties.

Evidence: a copy of the loop with an autorelease pool for each chunk used 67 MB.

Note: the time RSD of 22 to 47 % probably comes from the disk writes of the Mac.

Fixed in: the commit "Release the chunk buffers after each chunk in encrypt and decrypt".

### 8. Open blocks the main actor for 358 ms with 10 000 items

Open took 358 ms for 10 000 photos. `VaultStore` runs on the main actor, so the app does not respond to touches during this time.

Probable cause: the sort in `VaultStore.reload` gets `lastPathComponent` two times for each comparison.

Evidence: for 10 000 files, the sort took 308 ms of 359 ms. Each directory listing took 12 ms.
A sort that gets each name one time took 94 ms.

Fixed in: the commits "Remove leftover files at launch instead of in VaultStore.init" and "Sort the vault items by names that the store gets one time".

## Notes on the test design

- The First screen and No thumbnails tests start their calls at the same time, as the grid does.
  In the first run, the First screen test made the thumbnails one at a time, because of problem 3.
- The tests make the thumbnail files of the 10 encrypted photos and copy them with the photos.
  So the First screen and Full pass tests read thumbnail files.
- The full pass stops when the app uses 4 GB, half the memory of an iPhone 17. This stop prevented problem 1 from filling the memory of the Mac.
  In the first run, which XCTest discards, the full pass makes only 18 thumbnails.
- An image from `CGImageSourceCreateThumbnailAtIndex` decodes the photo again each time something renders it.
  For a 12 MP HEIC photo on the simulator, the thumbnail call took 70 ms, a render 70 ms, and `jpegData` on that image 135 ms.
  `kCGImageSourceShouldCacheImmediately` did not change these times. So `VaultStore` draws the image one time before the JPEG encode.
  With `jpegData` on the image, the No thumbnails test took 23.5 s. With one queue operation at a time, it took 41.4 s.
- The player item has an `AVPlayerItemVideoOutput`, because `VideoPlayer` shows the frames in the app.
  Without a video output, a seek completed in 0.4 ms and loaded no data.
- The tests set `Session.shared.unlocked` to false after `Session.shared.unlock`.
  If they do not, the host app opens `VaultView`, which reads `Application Support/Vault/`.
  When these measurements were made, `VaultView` also deleted the `.part` files there. A test on a separate simulator with a PIN and a `.part` file confirmed this.
  Now the launch of the app deletes the `.part` files, before the tests start.
