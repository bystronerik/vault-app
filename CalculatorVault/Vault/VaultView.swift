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
    @State private var changingPIN = false
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
                                    Button("Delete", systemImage: "trash", role: .destructive) {
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
                    ContentUnavailableView("No Items", systemImage: "photo.on.rectangle",
                                           description: Text("Tap + to import photos and videos."))
                }
            }
            .navigationTitle(selecting ? "\(selected.count) Selected" : "Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Lock", systemImage: "lock.fill") { Session.shared.lock() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selecting {
                        Button("Done") { selecting = false; selected = [] }
                    } else {
                        Button("Import", systemImage: "plus") { picking = true }
                        Menu {
                            Button("Select", systemImage: "checkmark.circle") { selecting = true }
                            Button("Change PIN", systemImage: "key") { changingPIN = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                if selecting {
                    ToolbarItemGroup(placement: .bottomBar) {
                        ShareLink(items: selected.map(VaultExport.init), preview: { SharePreview($0.item.url.lastPathComponent) }) {
                            Image(systemName: "square.and.arrow.up")
                        }
                            .disabled(selected.isEmpty)
                        Spacer()
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = selected; confirmDelete = true }
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
            .confirmationDialog(String(AttributedString(localized: "Delete ^[\(deleting.count) item](inflect: true)?").characters),
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { store.delete(deleting); selected = []; selecting = false }
            }
            .fullScreenCover(item: $viewing) { item in ItemViewer(store: store, current: item) }
            .sheet(isPresented: $changingPIN) { PINSetupView(requireCurrent: true) { changingPIN = false } }
        }
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
    func makeUIView(context: Context) -> PlayerView { PlayerView(url: url) }
    func updateUIView(_ view: PlayerView, context: Context) {}
}

/// Plays a video with sound and no controls. It plays only while it is in a window, so it stops when the menu closes.
private final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private let url: URL
    /// The asset reads the file through the loader. Keep the loader while the player exists.
    private var loader: VaultResourceLoader?

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let playerLayer = layer as! AVPlayerLayer
        if window == nil {
            playerLayer.player?.pause()
            playerLayer.player = nil
            loader = nil
        } else if playerLayer.player == nil {
            let (asset, loader) = makeAsset(for: url)
            self.loader = loader
            playerLayer.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            playerLayer.player?.play()
        }
    }
}
