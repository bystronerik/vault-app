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
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(store.items) { item in
                        Thumbnail(item: item)
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
            }
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
    @Environment(\.displayScale) private var scale
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
            .task {
                image = await VaultStore.image(for: item.url, side: 150, scale: scale)
                failed = image == nil
            }
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
                    image = await VaultStore.image(for: item.url, side: 400, scale: scale)
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
            self.loader = loader
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
            playerLayer.player = player
            player.play()
        }
    }
}
