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
            Text(localStatus).accessibilityIdentifier("streaming.localStatus")
                .accessibilityValue(model.localState.rawValue)
            Text(workerStatus).font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("streaming.workerStatus").accessibilityValue(model.workerState.rawValue)
            if let game = model.connectedGameID {
                Text("Match: \(game)").font(.caption).foregroundStyle(.secondary)
            }
            if model.localState == .publishing || model.localState == .starting {
                Button("Stop streaming", role: .destructive) { Task { await model.stopStreaming() } }
                    .buttonStyle(.bordered).accessibilityIdentifier("streaming.stop")
            } else {
                Button("Start streaming") { model.requestStartStreaming() }
                    .buttonStyle(.bordered).disabled(!model.canStart)
                    .accessibilityIdentifier("streaming.start")
            }
            Text("Recording stays on this device when streaming stops or loses its connection.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = model.message {
                Text(message).font(.callout).accessibilityIdentifier("streaming.message")
            }
            if model.commandState?.pending != nil || model.needsStorageRetry || model.message != nil {
                Button("Retry connection and pending status") { Task { await model.pollControl() } }
                    .disabled(model.busy).accessibilityIdentifier("streaming.retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $showSetup) { setup }
    }
    private var localStatus: String {
        switch model.localState {
        case .idle: "Camera publishing: off"
        case .starting: "Camera publishing: starting…"
        case .publishing: "Camera publishing: sending media"
        case .failed: "Camera publishing: failed"
        }
    }
    private var workerStatus: String {
        switch model.workerState {
        case .producingOutput: "Worker: producing output (recent report)"
        case .unknown: "Worker: no current observation"
        case .stale: "Worker: observation expired"
        case .notRequested, .idle: "Worker: output not requested"
        case .waitingSource: "Worker: waiting for camera media"
        case .starting: "Worker: starting output"
        case .stopping: "Worker: stopping output"
        case .retrying: "Worker: retrying output"
        case .failed: "Worker: output failed"
        case .closed: "Worker: closed"
        }
    }
    private var setup: some View {
        NavigationStack {
            Form {
                Section("Capture connection") {
                    TextField("Server URL", text: $model.endpoint)
                        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("streaming.endpoint")
                    SecureField("Installation token", text: $model.installationToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("streaming.token")
                    TextField("Worker ID", text: $model.workerId)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("streaming.worker")
                    TextField("Output ID", text: $model.outputId)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("streaming.output")
                }.disabled(!model.canChangeSetup)
                Section {
                    Button("Save and connect to active match") { Task { await model.connect() } }
                        .disabled(model.busy).accessibilityIdentifier("streaming.connect")
                    if model.busy { ProgressView("Connecting…") }
                    if let game = model.connectedGameID { Text("Capture joined \(game)").accessibilityIdentifier("streaming.connected") }
                    if let message = model.message { Text(message).font(.callout) }
                    if !model.canChangeSetup {
                        Text("Finish recording and reconcile pending streaming status before changing the saved connection.").font(.caption)
                    }
                } footer: {
                    Text("Capture uses its own device identity and secure Keychain setup. Your Score setup is separate. Streaming uses the selected server worker and output.")
                }
            }
            .navigationTitle("Streaming setup")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showSetup = false }.accessibilityIdentifier("streaming.closeSetup")
            } }
        }
    }
}
