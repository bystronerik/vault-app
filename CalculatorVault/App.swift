import CryptoKit
import os
import SwiftUI

@main
struct CalculatorVaultApp: App {
    init() {
        // The Keychain survives a reinstall. Clear it on the first launch after an install, unless a restored vault
        // exists. Check the path without `vaultDirectory`, because that global creates the directory.
        let vault = URL.applicationSupportDirectory.appending(path: "Vault")
        if !UserDefaults.standard.bool(forKey: "installed") {
            if !FileManager.default.fileExists(atPath: vault.path) {
                PINStore.delete()
            }
            UserDefaults.standard.set(true, forKey: "installed")
        }
        // A stopped import leaves a `.part` file. No import runs at launch, so the sweep cannot delete a running import.
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: vault.path)) ?? [])
        for name in names where name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: vault.appending(path: name))
        }
        // Keep only the thumbnail files of vault files. A delete in an older build, a delete during a thumbnail write,
        // and a stopped test run leave other files. The first use of `thumbnailDirectory` creates the directory,
        // also after iOS deletes Library/Caches.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: thumbnailDirectory.path)) ?? []
            where !(name.hasSuffix(".thumb") && names.contains(String(name.dropLast(6)))) {
            try? FileManager.default.removeItem(at: thumbnailDirectory.appending(path: name))
        }
        // The plaintext share copies of a stopped app.
        try? FileManager.default.removeItem(at: shareDirectory)
        #if DEBUG
        CalculatorEngine.selfTest()
        VaultCrypto.selfTest()
        VaultDatabase.selfTest()
        #endif
    }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}

/// Attached to the window. Records every touch and then fails, so it never blocks other gestures.
private final class TouchSpy: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with _: UIEvent) {
        Session.shared.lastTouch = Date()
        if let view, let y = touches.first?.location(in: view).y {
            Session.shared.lastTouchAtBottom = y >= view.bounds.height - view.safeAreaInsets.bottom
        }
        state = .failed
    }
}

@Observable final class Session {
    static let shared = Session()
    var unlocked = false
    var lastTouch = Date()
    /// True when the last touch started in the bottom safe area, where the home indicator gestures start.
    var lastTouchAtBottom = false
    /// True while a system picker is open. Its touches do not reach this app.
    var paused = false
    /// True while the keyboard shows. It is in another window, so its touches do not reach the gesture recognizer.
    var keyboardShown = false
    @ObservationIgnored private let cover = UIHostingController(rootView: CalculatorView())
    @ObservationIgnored private let key = OSAllocatedUnfairLock<SymmetricKey?>(initialState: nil)
    /// The master key while the vault is open. Safe to read from any thread.
    var masterKey: SymmetricKey? { key.withLock { $0 } }

    func unlock(_ masterKey: SymmetricKey) {
        key.withLock { $0 = masterKey }
        lastTouch = Date()
        unlocked = true
    }

    /// Clears the master key, so every decrypt stops, empties the image cache, and removes the plaintext share copies.
    /// Closes the viewer, the sheets, and the pickers with no animation, so no closing screen shows the vault.
    @MainActor func lock() {
        unlocked = false
        // The vault view is gone, so the picker cannot clear this flag.
        paused = false
        key.withLock { $0 = nil }
        window?.rootViewController?.dismiss(animated: false)
        VaultStore.cache.removeAllObjects()
        try? FileManager.default.removeItem(at: shareDirectory)
    }

    private var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// True when the app became inactive for the app switcher, or when it cannot tell.
    /// The app switcher gesture sends a touch on the home indicator first. The Control Center and Notification Center
    /// gestures send no touch. The app cannot see that touch with no home indicator, with an assistive technology,
    /// under the keyboard or the photo picker, or under a UIKit screen such as the share sheet.
    var leftForAppSwitcher: Bool {
        guard let window, !lastTouchAtBottom, window.safeAreaInsets.bottom > 0, !paused, !keyboardShown,
              !UIAccessibility.isVoiceOverRunning, !UIAccessibility.isSwitchControlRunning,
              !UIAccessibility.isAssistiveTouchRunning else { return true }
        // SwiftUI shows its sheets and the photo picker in hosting controllers, and `paused` covers the picker.
        // The share sheet runs in another process, and it is not in a hosting controller.
        var next = window.rootViewController?.presentedViewController
        while let vc = next {
            if !(vc is UIHostingController<AnyView>) { return true }
            next = vc.presentedViewController
        }
        return false
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
    /// In seconds. 0 is Instant.
    @AppStorage("lockTimeout") private var lockTimeout = 0
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
            case .inactive, .background:
                if session.unlocked { session.setCovered(true) }
                // The app can return to active from the app switcher and not go to the background.
                if lockTimeout == 0, new == .background || session.leftForAppSwitcher { session.lock() }
            case .active:
                // A suspended app gets no tick. Check the timeout before the cover goes.
                lockIfIdle()
                session.watchTouches(); session.setCovered(false)
            @unknown default: break
            }
        }
        .onReceive(tick) { _ in if !session.paused { lockIfIdle() } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in session.keyboardShown = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in session.keyboardShown = false }
    }

    /// Locks after the lock timeout with no touch. For Instant, the limit is 1 minute.
    private func lockIfIdle() {
        if session.unlocked, Date().timeIntervalSince(session.lastTouch) > TimeInterval(max(lockTimeout, 60)) { session.lock() }
    }
}
