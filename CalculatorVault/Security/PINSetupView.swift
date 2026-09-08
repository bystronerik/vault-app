import SwiftUI

/// First-launch PIN setup. With `requireCurrent`, it changes the PIN from inside the vault.
struct PINSetupView: View {
    var requireCurrent = false
    var onDone: () -> Void
    @State private var current = ""
    @State private var pin = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if requireCurrent { SecureField("Current PIN", text: $current) }
                    SecureField("New PIN (4 to 8 digits)", text: $pin)
                    SecureField("Confirm PIN", text: $confirm)
                } footer: {
                    Text("To open the vault, type the PIN on the calculator and press %.")
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button("Save PIN", action: save)
            }
            .keyboardType(.numberPad)
            .navigationTitle(requireCurrent ? "Change PIN" : "Set PIN")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func save() {
        guard PINStore.isValid(pin) else { error = "Use 4 to 8 digits. The first digit must not be 0."; return }
        guard pin == confirm else { error = "The two PINs are not the same."; return }
        do {
            if requireCurrent { try PINStore.change(from: current, to: pin) } else { try PINStore.save(pin) }
            onDone()
        } catch VaultCrypto.Failure.wrongPIN {
            error = "The current PIN is not correct."
        } catch {
            self.error = "The app could not save the PIN."
        }
    }
}
