import AVFoundation
import PhotosUI
import SwiftUI

struct VaultView: View {
    @State private var store = VaultStore()
    @State private var picking = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var selecting = false
    @State private var selected: Set<VaultItem> = []
    @State private var viewing: VaultItem?
    @State private var showingSettings = false
    @State private var confirmDelete = false
    /// The items for the delete dialog: the selection, or the one item from the long-press menu.
    @State private var deleting: Set<VaultItem> = []
    /// The column counts of the grid, from the largest items to the smallest. A pinch moves one step.
    private static let columnCounts = [3, 5, 15]
    @AppStorage("gridColumns") private var columnCount = 3
    /// The frame of the grid in the scroll view. The pinch uses it to find the item under the fingers.
    @State private var gridFrame = CGRect.zero
    /// The magnification at the last column change of the running pinch.
    @State private var pinchScale: CGFloat = 1
    @GestureState private var pinching = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount), spacing: 2) {
                        ForEach(store.items) { item in
                            // The thumbnail file size for 3 columns. Smaller cells decode smaller images, so that 15 columns fill faster.
                            Thumbnail(item: item, maxPixelSize: thumbnailPixels * 3 / columnCount)
                                .opacity(selected.contains(item) ? 0.6 : 1)
                                .overlay(alignment: .bottomTrailing) {
                                    if selecting {
                                        Image(systemName: selected.contains(item) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(.white, .blue)
                                            .padding(6)
                                    }
                                }
                                .onTapGesture {
                                    if selecting {
                                        if !selected.insert(item).inserted { selected.remove(item) }
                                    } else {
                                        viewing = item
                                    }
                                }
                                .contextMenu {
                                    if !selecting {
                                        ShareLink(item: VaultExport(item: item), preview: SharePreview(item.url.lastPathComponent))
                                        Button(.vaultDeleteButton, systemImage: "trash", role: .destructive) {
                                            deleting = [item]; confirmDelete = true
                                        }
                                    }
                                } preview: {
                                    ItemPreview(item: item)
                                }
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { gridFrame = $0 }
                }
                // Simultaneous, so that the pinch does not block the scroll, the taps, and the long-press menus.
                .simultaneousGesture(MagnifyGesture()
                    .updating($pinching) { _, pinching, _ in pinching = true }
                    .onChanged { pinch($0, proxy: proxy) })
            }
            // The gesture state also resets when the system cancels the pinch. A cancelled pinch does not call onEnded.
            .onChange(of: pinching) { _, on in if !on { pinchScale = 1 } }
            .overlay {
                if store.items.isEmpty {
                    ContentUnavailableView(.vaultEmptyTitle, systemImage: "photo.on.rectangle",
                                           description: Text(.vaultEmptyMessage))
                }
            }
            .navigationTitle(selecting ? .vaultSelectionTitle(selected.count) : .vaultTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(.vaultToolbarLock, systemImage: "lock.fill") { Session.shared.lock() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selecting {
                        Button(.vaultSelectionDone) { selecting = false; selected = [] }
                    } else {
                        Button(.vaultToolbarImport, systemImage: "plus") { picking = true }
                        Menu {
                            Button(.vaultMenuSelect, systemImage: "checkmark.circle") { selecting = true }
                            Button(.settingsTitle, systemImage: "gear") { showingSettings = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                if selecting {
                    ToolbarItemGroup(placement: .bottomBar) {
                        ShareLink(items: selected.map(VaultExport.init), preview: { SharePreview($0.item.url.lastPathComponent) }, label: {
                            Image(systemName: "square.and.arrow.up")
                        })
                        .disabled(selected.isEmpty)
                        Spacer()
                        Button(.vaultDeleteButton, systemImage: "trash", role: .destructive) { deleting = selected; confirmDelete = true }
                            .disabled(selected.isEmpty)
                    }
                }
            }
            .photosPicker(isPresented: $picking, selection: $picks, matching: .any(of: [.images, .videos]),
                          preferredItemEncoding: .current)
            .onChange(of: picking) { _, open in
                // The picker runs out of process, so its touches do not reset the inactivity clock.
                Session.shared.paused = open
                Session.shared.lastTouch = Date()
            }
            .onChange(of: picks) { _, new in
                guard !new.isEmpty else { return }
                Task { await store.importItems(new); picks = [] }
            }
            // The dialog title is plain text, so Foundation must apply the inflection first.
            .confirmationDialog(String(AttributedString(localized: .vaultDeleteTitle(deleting.count)).characters),
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(.vaultDeleteButton, role: .destructive) { store.delete(deleting); selected = []; selecting = false }
            }
            .fullScreenCover(item: $viewing) { item in ItemViewer(store: store, current: item) }
            .navigationDestination(isPresented: $showingSettings) { SettingsView() }
        }
    }

    /// Changes the column count one step when the pinch passes 1.3 times the scale of the last change.
    /// Spread the fingers for larger items. The item under the fingers stays in place.
    private func pinch(_ value: MagnifyGesture.Value, proxy: ScrollViewProxy) {
        let step = value.magnification > pinchScale * 1.3 ? -1 : value.magnification < pinchScale / 1.3 ? 1 : 0
        let index = (Self.columnCounts.firstIndex(of: columnCount) ?? 1) + step
        guard step != 0, Self.columnCounts.indices.contains(index), !store.items.isEmpty else { return }
        pinchScale = value.magnification
        // The cells are squares with a spacing of 2 points, so a row and a column have the same size.
        let size = (gridFrame.width + 2) / CGFloat(columnCount)
        let row = max(0, Int((value.startLocation.y - gridFrame.minY) / size))
        let column = min(max(0, Int((value.startLocation.x - gridFrame.minX) / size)), columnCount - 1)
        let item = store.items[min(row * columnCount + column, store.items.count - 1)]
        columnCount = Self.columnCounts[index]
        // The anchor is the same unit point in the item and in the scroll view, so the item stays under the fingers.
        // No animation: the grid does not animate the new columns, and an animated scroll moves through many rows.
        proxy.scrollTo(item.id, anchor: value.startAnchor)
    }
}

/// The settings page. It opens from the vault menu.
private struct SettingsView: View {
    @AppStorage("faceID") private var faceID = false
    /// In seconds. 0 is Instant.
    @AppStorage("lockTimeout") private var lockTimeout = 0
    @State private var changingPIN = false

    var body: some View {
        Form {
            Button(.settingsChangePIN) { changingPIN = true }
            Toggle(.settingsFaceID, isOn: $faceID)
                .onChange(of: faceID) { _, on in
                    // Ask for the Face ID permission now, not at the next unlock. Turn the switch off if Face ID fails.
                    guard on else { return }
                    Task { if await !CalculatorView.faceIDPasses(reason: .settingsFaceIDReason) { faceID = false } }
                }
            Picker(.lockTimeoutLabel, selection: $lockTimeout) {
                Text(.lockTimeoutOptionInstant).tag(0)
                Text(.lockTimeoutOptionOneMinute).tag(60)
                Text(.lockTimeoutOptionFiveMinutes).tag(300)
                Text(.lockTimeoutOptionFifteenMinutes).tag(900)
                Text(.lockTimeoutOptionThirtyMinutes).tag(1800)
                Text(.lockTimeoutOptionOneHour).tag(3600)
            }
        }
        .navigationTitle(.settingsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $changingPIN) { PINSetupView(requireCurrent: true) { changingPIN = false } }
    }
}

private struct Thumbnail: View {
    let item: VaultItem
    let maxPixelSize: Int
    @State private var image: UIImage?
    /// The file cannot open: corrupt, or from a lost key.
    @State private var failed = false

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.isVideo {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(6)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            // A new column count loads the image again at the new size. The cell shows the old image until then.
            .task(id: maxPixelSize) {
                let image = await VaultStore.thumbnail(for: item.url, maxPixelSize: maxPixelSize)
                // A cell that scrolls away cancels the task. Keep its state empty.
                guard !Task.isCancelled else { return }
                self.image = image
                failed = image == nil
            }
            // The cache limits the memory only when the cells off the screen keep no image.
            .onDisappear { image = nil }
    }
}

/// The long-press preview. Shows the photo, or plays the video over its first frame, aspect-fit at 400 points on the long side.
private struct ItemPreview: View {
    let item: VaultItem
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        if let image {
            // Size by the aspect ratio, not the pixels, so a low-resolution item does not show small.
            let fit = 400 / max(image.size.width, image.size.height)
            Image(uiImage: image).resizable().frame(width: image.size.width * fit, height: image.size.height * fit)
                .overlay { if item.isVideo { PreviewPlayer(url: item.url) } }
        } else {
            Color(.secondarySystemBackground)
                .frame(width: 300, height: 300)
                .overlay {
                    if failed { Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary) }
                }
                .task {
                    // A video needs only its first frame, because the player covers it.
                    image = await item.isVideo ? VaultStore.thumbnail(for: item.url)
                        : VaultStore.image(for: item.url, maxPixelSize: Int(400 * scale))
                    failed = image == nil
                }
        }
    }
}

private struct PreviewPlayer: UIViewRepresentable {
    let url: URL
    func makeUIView(context _: Context) -> PlayerView { PlayerView(url: url) }
    func updateUIView(_: PlayerView, context _: Context) {}
}

/// Plays a video in a loop, with sound and no controls. It plays only while it is in a window, so it stops when the menu closes.
private final class PlayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    private let url: URL
    /// The asset reads the file through the loader, and the looper repeats the item. Keep both while the player exists.
    private var loader: VaultResourceLoader? // periphery:ignore
    private var looper: AVPlayerLooper? // periphery:ignore

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let playerLayer = layer as! AVPlayerLayer // swiftlint:disable:this force_cast
        if window == nil {
            playerLayer.player?.pause()
            playerLayer.player = nil
            looper = nil
            loader = nil
        } else if playerLayer.player == nil {
            let (asset, loader) = makeAsset(for: url)
            let player = AVQueuePlayer()
            // The SDK header gives this setting for a resource loader delegate that loads the media data.
            player.automaticallyWaitsToMinimizeStalling = false
            self.loader = loader
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
            playerLayer.player = player
            player.play()
        }
    }
}
