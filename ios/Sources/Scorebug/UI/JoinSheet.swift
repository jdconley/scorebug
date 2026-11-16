import ScorebugCore
import SwiftUI
import UIKit

/// Type or paste a code: K7P-4QX scores one match someone else is filming (no account needed),
/// ABCD-EFGH is a team invite.
struct JoinSheet: View {
    @ObservedObject var app: AppModel
    @State private var code = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("To help score a match, ask the person filming to tap Invite scorer and read you the code. Team invite codes work here too.")
                        .foregroundStyle(Theme.muted)
                    SectionLabel("Code")
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
                        if app.busy { ProgressView().tint(Theme.ground) } else { Text(isTeamCode ? "Join team" : "Join and score") }
                    }
                    .buttonStyle(BigButtonStyle())
                    .disabled(!isValid || app.busy)
                    .accessibilityIdentifier("join.submit")
                }
                .padding(20)
            }
            .screenBackground()
            .navigationTitle("Join with a code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { app.error = nil; dismiss() } } }
            .onAppear { app.error = nil; focused = true }
        }
    }

    private var isTeamCode: Bool { TeamInviteCode.normalize(code) != nil }
    private var isValid: Bool { InviteCode.normalize(code) != nil || isTeamCode }

    private func submit(_ text: String) async {
        if await app.join(text: text) || app.notInBeta { dismiss() }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, ScorebugLink(string: text, hosts: app.linkHosts) != nil
                || InviteCode.normalize(text) != nil || TeamInviteCode.normalize(text) != nil else {
            app.error = "Copy the invite link or the code first."
            return
        }
        Task { await submit(text) }
    }

    /// "ABC-DEF" for a six-character match code, "ABCD-EFGH" for an eight-character team code.
    static func format(_ input: String) -> String {
        let raw = String(input.uppercased().filter { InviteCode.alphabet.contains($0) }.prefix(TeamInviteCode.length))
        if raw.count > 6 { return "\(raw.prefix(4))-\(raw.dropFirst(4))" }
        return raw.count > 3 ? "\(raw.prefix(3))-\(raw.dropFirst(3))" : raw
    }
}
