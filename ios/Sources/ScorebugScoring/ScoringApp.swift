import ScorebugCore
import SwiftUI

@main
struct ScoringApp: App {
    var body: some Scene {
        WindowGroup {
            ScoringSetupView()
        }
    }
}

private struct ScoringSetupView: View {
    @State private var endpoint = "http://localhost:18787"
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Native scoring foundation", systemImage: "sportscourt")
                    Text("Match creation, joining, and scoring will be added in the next milestone.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Control plane URL", text: $endpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("scoring.endpoint")
                        .onChange(of: endpoint) { _, _ in validationMessage = nil }
                    Button("Validate address") {
                        do {
                            _ = try ScoringEndpoint(endpoint)
                            validationMessage = "Address format is valid. Connection not tested."
                        } catch {
                            validationMessage = "Enter an HTTPS URL, or HTTP for localhost or a private LAN server."
                        }
                    }
                    .accessibilityIdentifier("scoring.validate")
                    if let validationMessage {
                        Text(validationMessage)
                            .accessibilityIdentifier("scoring.validation")
                    }
                } header: {
                    Text("Server address")
                } footer: {
                    Text("Use localhost for a server running on this Mac in the simulator. On an iPhone, use the server’s LAN address. This setup screen sends no requests and does not save settings.")
                }
            }
            .navigationTitle("Scorebug Scorer")
        }
    }
}
