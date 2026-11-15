import ScorebugCore
import SwiftUI

struct StreamingControlsView: View {
    @ObservedObject var model: CaptureStreamingModel
    @State private var showSetup = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Streaming", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                Spacer()
                Button("Setup") { showSetup = true }.accessibilityIdentifier("streaming.setup")
            }
            HStack(spacing: 8) {
                Text(statusText).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("streaming.localStatus")
                    .accessibilityValue(model.localState.rawValue)
                if let quality = model.streamQuality {
                    Text(quality.label).font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .accessibilityIdentifier("streaming.quality")
                }
            }
            if model.canStopStreaming {
                Button("Stop live", role: .destructive) { Task { await model.stopStreaming() } }
                    .buttonStyle(.bordered).accessibilityIdentifier("streaming.stop")
            } else {
                Button("Go live") { model.requestStartStreaming() }
                    .buttonStyle(.bordered).disabled(!model.canStart)
                    .accessibilityIdentifier("streaming.start")
            }
            Text("Your recording stays on this device even if the stream drops.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = model.message {
                Text(message).font(.callout).accessibilityIdentifier("streaming.message")
            }
            if model.commandState?.pending != nil || model.needsStorageRetry || model.message != nil {
                Button("Retry") { Task { await model.pollControl() } }
                    .disabled(model.busy).accessibilityIdentifier("streaming.retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $showSetup) {
            setup
                .onAppear { model.isSetupPresented = true }
                .onDisappear { model.isSetupPresented = false }
        }
    }
    private var statusText: String {
        switch model.status {
        case .live: "Live"
        case .reconnecting: "Reconnecting…"
        case .starting: "Going live…"
        case .recordingOnly: "Recording only"
        case .off: "Not live"
        }
    }
    private var setup: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server URL", text: $model.endpoint)
                        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("streaming.endpoint")
                    SecureField("Installation token", text: $model.installationToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("streaming.token")
                }.disabled(!model.canChangeSetup)
                Section("Advanced") {
                    TextField("Encoder", text: $model.workerId)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("streaming.worker")
                    TextField("Destination", text: $model.outputId)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("streaming.output")
                }.disabled(!model.canChangeSetup)
                Section {
                    Button("Save and connect") { Task { await model.connect() } }
                        .disabled(model.busy).accessibilityIdentifier("streaming.connect")
                    if model.busy { ProgressView("Connecting…") }
                    if model.connectedGameID != nil { Text("Connected to the active match").accessibilityIdentifier("streaming.connected") }
                    if let message = model.message { Text(message).font(.callout) }
                    if !model.canChangeSetup {
                        Text("Stop recording and let pending streaming requests finish before changing the server.").font(.caption)
                    }
                } footer: {
                    Text("Saved securely on this device, separately from your Score setup.")
                }
            }
            .navigationTitle("Streaming setup")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showSetup = false }.accessibilityIdentifier("streaming.closeSetup")
            } }
        }
    }
}
