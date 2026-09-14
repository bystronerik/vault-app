import CryptoKit
import LocalAuthentication
import SwiftUI

struct CalculatorView: View {
    @State private var engine = CalculatorEngine()
    @AppStorage("faceID") private var faceID = false

    private enum Key: Hashable {
        case digit(String), op(CalculatorEngine.Op), clear, sign, percent, equals

        /// SF Symbol name, or nil for text keys.
        var symbol: String? {
            switch self {
            case .op(.divide): "divide"
            case .op(.multiply): "multiply"
            case .op(.subtract): "minus"
            case .op(.add): "plus"
            case .equals: "equal"
            case .sign: "plus.forwardslash.minus"
            case .percent: "percent"
            default: nil
            }
        }
    }

    private static let rows: [[Key]] = [
        [.clear, .sign, .percent, .op(.divide)],
        [.digit("7"), .digit("8"), .digit("9"), .op(.multiply)],
        [.digit("4"), .digit("5"), .digit("6"), .op(.subtract)],
        [.digit("1"), .digit("2"), .digit("3"), .op(.add)],
        [.digit("0"), .digit("."), .equals],
    ]

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 12
            let size = (geo.size.width - gap * 5) / 4
            VStack(spacing: gap) {
                Spacer()
                Text(engine.display == "Error" ? String(localized: .calculatorError) : engine.text)
                    .font(.system(size: 90, weight: .light))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, gap)
                ForEach(Self.rows.indices, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(Self.rows[r], id: \.self) { key in
                            button(key, size: size, gap: gap)
                        }
                    }
                }
            }
            .padding(.horizontal, gap)
            .padding(.bottom, gap)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func button(_ key: Key, size: CGFloat, gap: CGFloat) -> some View {
        let wide = key == .digit("0")
        let (bg, fg) = colors(key)
        return Button { press(key) } label: {
            Group {
                if let symbol = key.symbol {
                    Image(systemName: symbol).font(.system(size: 34, weight: .medium))
                } else {
                    Text(label(key)).font(.system(size: key == .clear ? 34 : 40))
                }
            }
            .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
            .padding(.leading, wide ? size * 0.37 : 0)
            .frame(width: wide ? size * 2 + gap : size, height: size)
            .background(bg)
            .foregroundStyle(fg)
            .clipShape(Capsule())
        }
        .buttonStyle(KeyStyle())
    }

    private func label(_ key: Key) -> String {
        switch key {
        case let .digit(d): d
        case .clear: engine.isCleared ? "AC" : "C"
        default: ""
        }
    }

    private func colors(_ key: Key) -> (Color, Color) {
        switch key {
        case .clear, .sign, .percent: (Color(white: 0.65), .black)
        case let .op(op) where engine.activeOp == op: (.white, Color(red: 1, green: 0.62, blue: 0.04))
        case .op, .equals: (Color(red: 1, green: 0.62, blue: 0.04), .white)
        case .digit: (Color(white: 0.2), .white)
        }
    }

    private func press(_ key: Key) {
        switch key {
        case let .digit(d): engine.digit(d)
        case let .op(op): engine.operate(op)
        case .clear: engine.clear()
        case .sign: engine.toggleSign()
        case .equals: engine.equals()
        case .percent:
            // ponytail: the KDF runs on the main thread, only for a 4-to-8 digit display. It took 28 ms on the simulator of an M3 Pro Mac.
            // Measure it on the slowest test iPhone, and move it to a Task if the lag shows.
            if let key = PINStore.unlock(engine.display) {
                // Clear the display first, so the PIN does not stay on the screen when Face ID fails.
                engine = CalculatorEngine()
                guard faceID else { openVault(key); return }
                Task { if await Self.faceIDPasses(reason: .calculatorUnlockReason) { openVault(key) } }
            } else {
                engine.percent()
            }
        }
    }

    /// Opens the database and then the vault. It runs after the Face ID check, so the metadata is not in memory before the check.
    /// If the database does not open, the display shows Error, and the vault stays locked.
    private func openVault(_ key: SymmetricKey) {
        do {
            try Session.shared.unlock(key, database: VaultDatabase(url: vaultDirectory.appending(path: "database"), key: key))
        } catch {
            engine.showError()
        }
    }

    /// Face ID, with the device passcode as the fallback for a broken Face ID.
    /// A device without a passcode has no Face ID, and only a person who knows the passcode can remove it.
    /// So the check passes there, and a restore to a device without a passcode can still open the vault.
    /// The first call shows the system prompt for the Face ID permission.
    static func faceIDPasses(reason: LocalizedStringResource) async -> Bool {
        do {
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: reason))
        } catch LAError.passcodeNotSet {
            return true
        } catch {
            return false
        }
    }
}

/// Lightens the key while it is pressed, as the iOS Calculator does.
private struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(Color.white.opacity(configuration.isPressed ? 0.35 : 0))
            .clipShape(Capsule())
    }
}
