import AuthenticationServices
import ScorebugCore
import SwiftUI
import UIKit

/// First launch: Sign in with Google. A scorer helping out at one match can join with a code instead.
struct SignInView: View {
    @ObservedObject var app: AppModel
    @State private var joining = false
    @State private var developer = false

    var body: some View {
        Group {
            if app.notInBeta { PrivateBetaView(app: app) } else { signIn }
        }
        .sheet(isPresented: $joining) { JoinSheet(app: app) }
        .sheet(isPresented: $developer) { DeveloperServerSheet(app: app) }
        .onAppear { OrientationLock.set(.portrait, rotateTo: .portrait) }
    }

    private var signIn: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            VStack(spacing: 18) {
                BrandMark()
                Text("Scorebug").font(Theme.score(52)).kerning(0.8)
                    .accessibilityAddTraits(.isHeader)
                Text("Film your volleyball match, keep score, and go live on YouTube with the score on the video.")
                    .font(.body).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 40)
            VStack(spacing: 14) {
                if let error = app.error, !joining {
                    Text(error).font(.callout).foregroundStyle(Theme.warn).multilineTextAlignment(.center)
                        .accessibilityIdentifier("signIn.error")
                }
                Button { Task { await app.signIn() } } label: {
                    if app.busy { ProgressView().tint(Theme.ground) } else {
                        HStack(spacing: 10) {
                            GoogleMark()
                            Text("Sign in with Google")
                        }
                    }
                }
                .buttonStyle(BigButtonStyle())
                .disabled(app.busy)
                .accessibilityIdentifier("signIn.google")
                Button { app.error = nil; joining = true } label: { Text("Join with a code") }
                    .buttonStyle(BigButtonStyle(kind: .surface, height: 52))
                    .accessibilityIdentifier("signIn.join")
                Text("Scorebug sees only your name and email. Scoring someone's match with a code needs no account.")
                    .font(.footnote).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                #if DEBUG
                Button { developer = true } label: {
                    Label(app.server.url.host == ScorebugService.linkHost ? "Server: scorebug.live" : "Server: \(app.server.url.absoluteString)",
                          systemImage: "wrench.and.screwdriver")
                        .font(.footnote.weight(.medium))
                }
                .foregroundStyle(Theme.secondary).frame(minHeight: 44)
                .accessibilityIdentifier("signIn.developer")
                #endif
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 24)
        .frame(maxWidth: 520).frame(maxWidth: .infinity)
    }
}

/// Signed in with Google, but not on the beta list and no team invite.
struct PrivateBetaView: View {
    @ObservedObject var app: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            VStack(spacing: 18) {
                Image(systemName: "lock.fill").font(.system(size: 40, weight: .semibold)).foregroundStyle(Theme.text)
                    .frame(width: 88, height: 88).background(Theme.surface, in: Circle())
                    .accessibilityHidden(true)
                Text("Scorebug is in private beta").font(Theme.score(34)).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("beta.title")
                Text("That Google account isn't on the beta list yet. Ask for access, or open the team invite link your team owner sent you.")
                    .font(.body).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 40)
            VStack(spacing: 14) {
                Button { openURL(ScorebugService.url) } label: { Text("Ask for access") }
                    .buttonStyle(BigButtonStyle())
                    .accessibilityIdentifier("beta.ask")
                Button { Task { await app.signIn() } } label: { Text("Use another Google account") }
                    .buttonStyle(BigButtonStyle(kind: .surface, height: 52))
                    .disabled(app.busy)
                    .accessibilityIdentifier("beta.retry")
                Button("Back") { app.dismissNotInBeta() }
                    .foregroundStyle(Theme.muted).frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 24)
        .frame(maxWidth: 520).frame(maxWidth: .infinity)
    }
}

/// The app icon, for the sign-in screen.
struct BrandMark: View {
    var body: some View {
        Image("BrandIcon").resizable().interpolation(.high)
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A plain "G" in Google's blue, sized for the sign-in button.
private struct GoogleMark: View {
    var body: some View {
        Text("G").font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundStyle(Color(hex: "#4285F4"))
            .frame(width: 28, height: 28)
            .background(.white, in: Circle())
            .overlay(Circle().stroke(Theme.line, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Debug builds: use a local server (`pnpm --filter @scorebug/control-plane dev:worker`).
struct DeveloperServerSheet: View {
    @ObservedObject var app: AppModel
    @State private var address = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                SectionLabel("Server")
                TextField("https://scorebug.live", text: $address)
                    .keyboardType(.URL).textContentType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .fieldStyle()
                    .accessibilityIdentifier("developer.server")
                Text("Leave empty for scorebug.live. Changing the server signs you out.")
                    .font(.footnote).foregroundStyle(Theme.secondary)
                HStack(spacing: 10) {
                    ForEach(["http://localhost:8787", "http://127.0.0.1:8787"], id: \.self) { preset in
                        Button(preset.replacingOccurrences(of: "http://", with: "")) { address = preset }
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10).frame(minHeight: 36)
                            .background(Theme.surface, in: Capsule())
                    }
                }
                if let error = app.error {
                    Text(error).font(.callout).foregroundStyle(Theme.warn)
                }
                Spacer()
                Button("Use this server") { if app.useServer(address) { dismiss() } }
                    .buttonStyle(BigButtonStyle())
                    .accessibilityIdentifier("developer.use")
            }
            .padding(20)
            .screenBackground()
            .navigationTitle("Developer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                address = app.server.url.host == ScorebugService.linkHost ? "" : app.server.url.absoluteString
            }
        }
    }
}

/// `ASWebAuthenticationSession`: Google's page in a system sheet that shares Safari's
/// sign-ins, finishing on `scorebug://auth`.
@MainActor final class WebAuthenticationBrowser: NSObject, SignInBrowser, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func open(_ url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
                Task { @MainActor in self?.session = nil }
                if let callback { return continuation.resume(returning: callback) }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    return continuation.resume(throwing: SignInBrowserError.cancelled)
                }
                continuation.resume(throwing: error ?? SignInBrowserError.unavailable)
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: SignInBrowserError.unavailable)
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
