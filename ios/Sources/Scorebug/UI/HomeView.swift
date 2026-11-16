import ScorebugCore
import SwiftUI

struct HomeView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var film: FilmModel
    @StateObject private var home = HomeModel()
    @State private var newMatch = false
    @State private var joining = false
    @State private var settings = false
    @State private var recordings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    statusLine
                    Button { newMatch = true } label: {
                        Label("New match", systemImage: "plus").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(BigButtonStyle())
                    .accessibilityIdentifier("home.newMatch")
                    Button { joining = true } label: { Text("Join a match") }
                        .buttonStyle(BigButtonStyle(kind: .surface, height: 52))
                        .accessibilityIdentifier("home.join")
                    if let error = app.error {
                        Text(error).font(.callout).foregroundStyle(Theme.warn)
                    }
                    if let recap = app.preferences.lastMatch {
                        SectionLabel("Last match").padding(.top, 12)
                        LastMatchCard(recap: recap)
                    }
                    Button { recordings = true } label: {
                        HStack {
                            Text("Recordings").font(.body.weight(.semibold))
                            Spacer()
                            Text(recordingCount).font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondary)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                        }
                        .padding(16).frame(minHeight: 56)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.recordings")
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 32)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $recordings) { RecordingsView(film: film, preferences: app.preferences) }
        }
        .sheet(isPresented: $newMatch) {
            if let config = app.config {
                NewMatchSheet(app: app, model: NewMatchModel(config: config, preferences: app.preferences))
            }
        }
        .sheet(isPresented: $joining) { JoinSheet(app: app) }
        .sheet(isPresented: $settings) { SettingsSheet(app: app, home: home) }
        .task { await home.refresh(app.config) }
        .refreshable { await home.refresh(app.config) }
        .onAppear { OrientationLock.set(.portrait, rotateTo: .portrait) }
    }

    private var header: some View {
        HStack {
            Text("Scorebug").font(Theme.score(34)).kerning(0.6).accessibilityAddTraits(.isHeader)
            Spacer()
            Button { settings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44).background(Theme.surface, in: Circle())
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("home.settings")
        }
    }

    private var statusLine: some View {
        Button { Task { await home.refresh(app.config) } } label: {
            HStack(spacing: 8) {
                StatusDot(color: home.isHealthy ? Theme.ok : (home.connection == .checking ? Theme.secondary : Theme.warn))
                (Text("Server ") + Text(app.config?.host ?? "").foregroundColor(Theme.text).fontWeight(.semibold) + Text(" \(home.detail)"))
                    .font(.subheadline).foregroundStyle(Theme.muted).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.status")
        .accessibilityHint("Checks the server again")
    }

    private var recordingCount: String {
        let count = film.recordings.filter { $0.status != .unavailable }.count
        return count == 1 ? "1 saved" : "\(count) saved"
    }
}

struct LastMatchCard: View {
    let recap: MatchRecap
    var body: some View {
        VStack(spacing: 0) {
            row(recap.team1, winner: recap.team1.sets >= recap.team2.sets).padding(.top, 16).padding(.bottom, 8)
            row(recap.team2, winner: recap.team2.sets > recap.team1.sets).padding(.bottom, 12)
            Divider().overlay(Theme.line)
            HStack {
                Text("\(recap.final ? "Final" : "Ended early")\(recap.setScores.isEmpty ? "" : " · \(recap.setScores)")")
                Spacer()
                Text(recap.date, format: .relative(presentation: .named))
            }
            .font(.footnote).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func row(_ team: MatchRecap.Team, winner: Bool) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 3).fill(Theme.teamColor(team.color)).frame(width: 6, height: 36)
            Text(team.shortName).font(Theme.score(26)).foregroundStyle(winner ? Theme.text : Theme.secondary)
            Spacer()
            Text("\(team.sets)").font(Theme.score(40)).monospacedDigit().foregroundStyle(winner ? Theme.text : Theme.secondary)
        }
        .padding(.horizontal, 16)
    }
}

struct SettingsSheet: View {
    @ObservedObject var app: AppModel
    @ObservedObject var home: HomeModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDisconnect = false

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    LabeledContent("Address", value: app.config?.endpoint ?? "—")
                    LabeledContent("This phone", value: app.config?.deviceName ?? "—")
                    LabeledContent("Status", value: home.detail)
                }
                Section {
                    Button("Disconnect this phone", role: .destructive) { confirmDisconnect = true }
                } footer: {
                    Text("Recordings stay on this phone. To connect again you'll need a new setup link from the server.")
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Disconnect from \(app.config?.host ?? "the server")?", isPresented: $confirmDisconnect,
                                titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { dismiss(); app.disconnect() }
            }
        }
    }
}
