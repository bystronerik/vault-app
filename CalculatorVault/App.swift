import SwiftUI

@main
struct CalculatorVaultApp: App {
    init() {
        // The Keychain survives a reinstall. Clear it on the first launch after install.
        if !UserDefaults.standard.bool(forKey: "installed") {
            PINStore.delete()
            UserDefaults.standard.set(true, forKey: "installed")
        }
        #if DEBUG
        CalculatorEngine.selfTest()
        #endif
    }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}

/// Attached to the window. Records every touch and then fails, so it never blocks other gestures.
private final class TouchSpy: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        Session.shared.lastTouch = Date()
        state = .failed
    }
}

@Observable final class Session {
    static let shared = Session()
    var unlocked = false
    var lastTouch = Date()
    /// True while a system picker is open. Its touches do not reach this app.
    var paused = false
    @ObservationIgnored private let cover = UIHostingController(rootView: CalculatorView())

    func unlock() { lastTouch = Date(); unlocked = true }
    func lock() { unlocked = false }

    private var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    func watchTouches() {
        guard let window, !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchSpy }) else { return }
        window.addGestureRecognizer(TouchSpy())
    }

    /// Puts a calculator over the whole window so the app switcher snapshot does not show the vault.
    func setCovered(_ on: Bool) {
        guard let window else { return }
        if on {
            cover.view.frame = window.bounds
            window.addSubview(cover.view)
        } else {
            cover.view.removeFromSuperview()
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var phase
    @State private var session = Session.shared
    @State private var hasPIN = PINStore.exists()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if !hasPIN {
                PINSetupView { hasPIN = true }
            } else if session.unlocked {
                VaultView()
            } else {
                CalculatorView()
            }
        }
        .onAppear { session.watchTouches() }
        .onChange(of: phase) { _, new in
            switch new {
            case .inactive: if session.unlocked { session.setCovered(true) }
            case .background: session.lock()
            case .active: session.watchTouches(); session.setCovered(false)
            @unknown default: break
            }
        }
        .onReceive(tick) { now in
            if session.unlocked, !session.paused, now.timeIntervalSince(session.lastTouch) > 60 { session.lock() }
        }
    }
}
