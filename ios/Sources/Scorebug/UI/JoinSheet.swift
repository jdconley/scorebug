import ScorebugCore
import SwiftUI
import UIKit

/// Join a match someone else is filming: scan their invite QR, paste the link or type the code.
struct JoinSheet: View {
    @ObservedObject var app: AppModel
    @State private var code = ""
    @State private var scanning = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Ask the person filming to tap Invite scorer, then scan their code or type it here.")
                        .foregroundStyle(Theme.muted)
                    if scanning {
                        ScannerBox { text in
                            if JoinInput(text) != nil { Task { await submit(text) } }
                            else { app.error = "That QR code isn't a Scorebug invite." }
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Button { scanning = true } label: { Label("Scan invite code", systemImage: "qrcode.viewfinder") }
                            .buttonStyle(BigButtonStyle(kind: .surface, height: 52))
                    }
                    SectionLabel("Or type the code")
                    TextField("K7P-4QX", text: Binding(get: { code }, set: { code = Self.format($0) }))
                        .font(Theme.score(34)).kerning(4)
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .focused($focused)
                        .fieldStyle()
                        .accessibilityIdentifier("join.code")
                    Button { paste() } label: { Label("Paste invite link", systemImage: "doc.on.clipboard") }
                        .foregroundStyle(Theme.muted).frame(minHeight: 44)
                    if let error = app.error {
                        Text(error).font(.callout).foregroundStyle(Theme.warn).accessibilityIdentifier("join.error")
                    }
                    Button {
                        Task { await submit(code) }
                    } label: {
                        if app.busy { ProgressView().tint(Theme.ground) } else { Text("Join and score") }
                    }
                    .buttonStyle(BigButtonStyle())
                    .disabled(InviteCode.normalize(code) == nil || app.busy)
                    .accessibilityIdentifier("join.submit")
                }
                .padding(20)
            }
            .screenBackground()
            .navigationTitle("Join a match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { app.error = nil; dismiss() } } }
            .onAppear { app.error = nil }
        }
    }

    private func submit(_ text: String) async {
        if await app.join(text: text) { dismiss() }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, JoinInput(text) != nil else {
            app.error = "Copy the scorebug://join link or the code first."
            return
        }
        Task { await submit(text) }
    }

    /// Keeps the field as "ABC-DEF" while typing.
    static func format(_ input: String) -> String {
        let raw = String(input.uppercased().filter { InviteCode.alphabet.contains($0) }.prefix(6))
        return raw.count > 3 ? "\(raw.prefix(3))-\(raw.dropFirst(3))" : raw
    }
}
