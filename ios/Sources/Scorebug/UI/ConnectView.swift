import ScorebugCore
import SwiftUI
import UIKit

/// First launch: scan the setup QR the server prints, or type its address and code.
struct ConnectView: View {
    @ObservedObject var app: AppModel
    @State private var manual = false
    @State private var joining = false
    @State private var scanNote: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Connect your server")
                    .font(Theme.score(34)).padding(.top, 40)
                    .accessibilityAddTraits(.isHeader)
                Text("On the computer running Scorebug, run the command below, then point this camera at the code it shows.")
                    .font(.body).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Text("./infra/install.sh phone")
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
                ScannerBox { code in
                    if !app.open(code) { scanNote = "That QR code isn't a Scorebug link." }
                }
                .padding(.top, 8)
                Text(scanNote ?? "The code carries the server address and a one-time key. Nothing to type.")
                    .font(.footnote).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                if let error = app.error, app.pendingLink == nil, !manual, !joining {
                    Text(error).font(.callout).foregroundStyle(Theme.warn).multilineTextAlignment(.center)
                        .accessibilityIdentifier("connect.error")
                }
                VStack(spacing: 12) {
                    Button { pasteLink() } label: { Label("Paste setup link", systemImage: "doc.on.clipboard") }
                        .buttonStyle(BigButtonStyle(kind: .surface, height: 52))
                    Button("Enter address manually") { app.error = nil; manual = true }
                        .foregroundStyle(Theme.muted).frame(minHeight: 44)
                        .accessibilityIdentifier("connect.manual")
                    Button("Join someone's match instead") { app.error = nil; joining = true }
                        .foregroundStyle(Theme.muted).frame(minHeight: 44)
                        .accessibilityIdentifier("connect.join")
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24).padding(.bottom, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $manual) { ManualConnectSheet(app: app) }
        .sheet(isPresented: $joining) { JoinSheet(app: app) }
        .onAppear { OrientationLock.set(.portrait, rotateTo: .portrait) }
    }

    private func pasteLink() {
        guard let text = UIPasteboard.general.string, app.open(text) else {
            scanNote = "Copy the scorebug://connect link from your server first."
            return
        }
    }
}

private struct ManualConnectSheet: View {
    @ObservedObject var app: AppModel
    @State private var address = ""
    @State private var code = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                SectionLabel("Server address")
                TextField("scorebug.example.com", text: $address)
                    .textContentType(.URL).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .fieldStyle()
                    .accessibilityIdentifier("connect.address")
                SectionLabel("Setup code")
                TextField("From the setup link", text: $code)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .fieldStyle()
                    .accessibilityIdentifier("connect.code")
                Text("The code is the part after code= in the scorebug://connect link. It works once.")
                    .font(.footnote).foregroundStyle(Theme.secondary)
                if let error = app.error {
                    Text(error).font(.callout).foregroundStyle(Theme.warn)
                        .accessibilityIdentifier("connect.manualError")
                }
                Spacer()
                Button {
                    Task { if await app.enroll(address: address, code: code) { dismiss() } }
                } label: {
                    if app.busy { ProgressView().tint(Theme.ground) } else { Text("Connect") }
                }
                .buttonStyle(BigButtonStyle())
                .disabled(address.isEmpty || code.isEmpty || app.busy)
                .accessibilityIdentifier("connect.submit")
            }
            .padding(20)
            .screenBackground()
            .navigationTitle("Connect manually")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { app.error = nil; dismiss() } } }
        }
    }
}

extension View {
    func fieldStyle() -> some View {
        padding(.horizontal, 14).frame(minHeight: 52)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
