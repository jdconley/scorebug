import ScorebugCore
import SwiftUI

struct PhoneWatchView: View {
    @ObservedObject var model: PhoneWatchModel
    let connections: [PhoneWatchConnection]
    var body: some View {
        NavigationStack {
            Form {
                Section("Paired Watch") {
                    Label(status, systemImage: "applewatch")
                        .accessibilityIdentifier("phoneWatch.status")
                    Text("Open Scorebug on your Watch, then send the current match from this phone. Your Watch will have its own scoring access.")
                    if model.notice == nil { Text("Waiting for your Watch…").foregroundStyle(.secondary) }
                }
                if model.pending != nil {
                    Section("Saved setup request") {
                        Button("Retry setup") { Task { await model.retry() } }
                            .disabled(model.busy || model.notice == nil).accessibilityIdentifier("phoneWatch.retry")
                        Button("Start a new setup request") { model.resetRequest() }
                            .disabled(model.busy).accessibilityIdentifier("phoneWatch.reset")
                            #if DEBUG
                            .accessibilityValue(model.pendingSetupProvenance)
                            #endif
                    }
                } else {
                    Section("Send current match") {
                        if connections.isEmpty {
                            Text("Configure your server in Film or Score first.")
                        }
                        ForEach(Array(connections.enumerated()), id: \.offset) { index, connection in
                            Button("Use " + connection.label.lowercased()) { Task { await model.connect(using: connection) } }
                                .disabled(model.busy || model.notice == nil)
                                .accessibilityIdentifier("phoneWatch.connect." + String(index))
                        }
                    }
                }
                if model.busy { ProgressView("Preparing Watch setup…") }
                if let message = model.message { Section { Text(message).accessibilityIdentifier("phoneWatch.message") } }
                Section {
                    Text("You can score on your Watch while this phone films, or use a Watch paired to another configured phone. Take over scoring explicitly on the device you want to use.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.navigationTitle("Watch")
        }
    }
    private var status: String {
        switch model.notice?.phase {
        case .paired: "Watch reports connected"
        case .pending: "Watch is confirming setup"
        case .unpaired: "Watch is ready for setup"
        case nil: "Open Scorebug on your Watch"
        }
    }
}
