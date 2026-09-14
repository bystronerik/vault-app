import SwiftUI

/// First-launch PIN setup. With `requireCurrent`, it changes the PIN from inside the vault.
struct PINSetupView: View {
    var requireCurrent = false
    var onDone: () -> Void
    @State private var current = ""
    @State private var pin = ""
    @State private var confirm = ""
    @State private var error: LocalizedStringResource?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if requireCurrent { SecureField(.pinSetupFieldCurrentPIN, text: $current) }
                    SecureField(.pinSetupFieldNewPIN, text: $pin)
                    SecureField(.pinSetupFieldConfirmPIN, text: $confirm)
                } footer: {
                    Text(.pinSetupFooter)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button(.pinSetupButtonSave, action: save)
            }
            .keyboardType(.numberPad)
            .navigationTitle(requireCurrent ? .pinSetupTitleChange : .pinSetupTitleSet)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func save() {
        guard PINStore.isValid(pin) else { error = .pinSetupErrorInvalidPIN; return }
        guard pin == confirm else { error = .pinSetupErrorMismatch; return }
        do {
            if requireCurrent { try PINStore.change(from: current, to: pin) } else { try PINStore.save(pin) }
            onDone()
        } catch VaultCrypto.Failure.wrongPIN {
            error = .pinSetupErrorWrongCurrentPIN
        } catch {
            self.error = .pinSetupErrorSaveFailed
        }
    }
}
