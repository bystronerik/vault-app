import AVKit
import SwiftUI

/// Full-screen pager. Swipe between items, pinch to zoom photos, play videos, swipe down to close.
struct ItemViewer: View {
    let store: VaultStore
    @State var current: VaultItem
    /// The namespace of the grid cells.
    let zoom: Namespace.ID
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $current) {
                ForEach(store.items) { item in
                    Group {
                        if item.isVideo { VideoPage(url: item.url) } else { PhotoPage(url: item.url) }
                    }
                    .tag(item)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(.itemViewerClose, systemImage: "xmark") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: VaultExport(item: current), preview: SharePreview(current.url.lastPathComponent)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Button(.vaultDeleteButton, systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
            .confirmationDialog(.itemViewerDeleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(.vaultDeleteButton, role: .destructive) { delete() }
            }
        }
        // The system zoom transition closes the viewer with a swipe down. It zooms back to the cell of the current item.
        .navigationTransition(.zoom(sourceID: current.id, in: zoom))
    }

    private func delete() {
        let index = store.items.firstIndex(of: current) ?? 0
        store.delete([current])
        if store.items.isEmpty { dismiss() } else { current = store.items[min(index, store.items.count - 1)] }
    }
}

/// Plays through the resource loader. The loader stays in state so the asset can reach it.
private struct VideoPage: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var loader: VaultResourceLoader?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                let (asset, loader) = makeAsset(for: url)
                self.loader = loader
                let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                // The SDK header gives this setting for a resource loader delegate that loads the media data.
                player.automaticallyWaitsToMinimizeStalling = false
                self.player = player
            }
            .onDisappear { player?.pause(); player = nil; loader = nil }
    }
}

/// Decrypts the photo to memory and decodes it at not more than 4096 pixels on the long side.
/// Shows the cached grid thumbnail first.
private struct PhotoPage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZoomableImage(image: image)
            .overlay { if failed { Text(.itemViewerErrorCannotOpen).foregroundStyle(.secondary) } }
            .task {
                // The cache lookup reads no file and uses no queue.
                if image == nil { image = VaultStore.cache.object(forKey: url.path as NSString) }
                let full = await VaultStore.image(for: url, maxPixelSize: 4096)
                guard !Task.isCancelled else { return }
                image = full
                failed = full == nil
            }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?
    func makeUIView(context _: Context) -> ZoomScrollView { ZoomScrollView() }
    func updateUIView(_ view: ZoomScrollView, context _: Context) {
        if view.image !== image { view.image = image }
    }
}

/// UIScrollView with an aspect-fit image that stays centered while zoomed.
final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var fittedSize = CGSize.zero

    var image: UIImage? {
        get { imageView.image }
        set { imageView.image = newValue; fittedSize = .zero; setNeedsLayout() }
    }

    init() {
        super.init(frame: .zero)
        delegate = self
        maximumZoomScale = 6
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        addSubview(imageView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap))
        tap.numberOfTapsRequired = 2
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.size != fittedSize else { return }
        fittedSize = bounds.size
        zoomScale = 1
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        imageView.frame = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        contentSize = imageView.frame.size
        center()
    }

    private func center() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in _: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_: UIScrollView) { center() }

    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / 3, height: bounds.height / 3)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}
