import ScorebugCore
import SwiftUI

struct HomeView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var film: FilmModel
    @StateObject private var home = HomeModel()
    @State private var newMatchTeam: TeamMembership?
    @State private var joining = false
    @State private var settings = false
    @State private var creatingTeam = false
    @State private var path = NavigationPath()

    private enum Destination: Hashable { case team(String), recordings }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if app.me == nil, !home.loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if app.teams.isEmpty {
                        NoTeamCard { creatingTeam = true }
                    }
                    ForEach(app.teams) { team in
                        TeamBlock(team: team, match: home.activeMatches[team.id], watchLink: home.watchLinks[team.id],
                                  channel: home.channels[team.id], prominent: app.teams.count == 1,
                                  busy: home.busy,
                                  openTeam: { path.append(Destination.team(team.id)) },
                                  newMatch: { newMatchTeam = team },
                                  open: { snapshot, kind in Task { await open(snapshot, team: team, kind: kind) } })
                    }
                    Button { app.error = nil; joining = true } label: { Text("Join with a code") }
                        .buttonStyle(BigButtonStyle(kind: .surface, height: 52))
                        .accessibilityIdentifier("home.join")
                    if let error = home.error ?? app.error {
                        Text(error).font(.callout).foregroundStyle(Theme.warn).accessibilityIdentifier("home.error")
                    }
                    if let recap = app.preferences.lastMatch {
                        SectionLabel("Last match").padding(.top, 12)
                        LastMatchCard(recap: recap)
                    }
                    Button { path.append(Destination.recordings) } label: {
                        RowLabel(title: "Recordings", detail: recordingCount)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.recordings")
                    if !app.teams.isEmpty {
                        Button { creatingTeam = true } label: { Label("New team", systemImage: "plus") }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("home.newTeam")
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 32)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .team(let id): TeamView(app: app, teamId: id) { path = NavigationPath() }
                case .recordings: RecordingsView(film: film, preferences: app.preferences)
                }
            }
            .refreshable { await home.refresh(app) }
        }
        .sheet(item: $newMatchTeam) { team in
            if let access = app.access(teamId: team.id) {
                NewMatchSheet(app: app, model: NewMatchModel(team: team.team, isOwner: team.isOwner, access: access,
                                                            preferences: app.preferences))
            }
        }
        .sheet(isPresented: $joining) { JoinSheet(app: app) }
        .sheet(isPresented: $settings) { SettingsSheet(app: app) }
        .sheet(isPresented: $creatingTeam) {
            CreateTeamSheet(home: home, app: app) { id in path.append(Destination.team(id)) }
                .presentationDetents([.medium])
        }
        .task { await home.refresh(app) }
        .onChange(of: app.teams) { _, _ in Task { await home.loadMatches(app) } }
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

    private func open(_ snapshot: MatchSnapshot, team: TeamMembership, kind: MatchSession.Kind) async {
        guard let session = await home.open(snapshot, team: team, kind: kind, app: app) else { return }
        app.begin(session)
    }

    private var recordingCount: String {
        let count = film.recordings.filter { $0.status != .unavailable }.count
        return count == 1 ? "1 saved" : "\(count) saved"
    }
}

/// One team on Home: its open match to film or score, and New match.
private struct TeamBlock: View {
    let team: TeamMembership
    let match: MatchSnapshot?
    let watchLink: MatchYouTube?
    /// Outer nil: not read yet. Inner nil: no channel set.
    let channel: TeamYouTube??
    let prominent: Bool
    let busy: Bool
    let openTeam: () -> Void
    let newMatch: () -> Void
    let open: (MatchSnapshot, MatchSession.Kind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: openTeam) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.teamColor(team.color)).frame(width: 6, height: 28)
                        .accessibilityHidden(true)
                    Text(team.name).font(Theme.score(26)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(team.isOwner ? "Owner" : "Member").font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(team.name), \(team.isOwner ? "owner" : "member")")
            .accessibilityHint("Members and invites")
            .accessibilityIdentifier("home.team.\(team.id)")
            if let note = channelNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium)).foregroundStyle(Theme.warn)
                    .accessibilityIdentifier("home.channelNote")
            }
            if let match {
                ActiveMatchCard(match: match, watchLink: watchLink, busy: busy, open: { open(match, $0) })
            }
            Button(action: newMatch) {
                Label("New match", systemImage: "plus").labelStyle(.titleAndIcon)
            }
            .buttonStyle(BigButtonStyle(kind: prominent && match == nil ? .primary : .surface, height: prominent && match == nil ? 60 : 52))
            .accessibilityIdentifier("home.newMatch")
        }
    }

    /// A channel problem worth seeing before the gym: the team can't go live as it stands.
    private var channelNote: String? {
        guard case .some(let current) = channel else { return nil }
        guard let current else { return team.isOwner ? "No YouTube channel yet. Connect one to go live." : nil }
        switch current.status {
        case .ready: return nil
        case .liveDisabled: return "\(current.channelTitle) can't live stream yet (YouTube's 24-hour wait)."
        case .needsReconnect: return team.isOwner ? "YouTube needs reconnecting" : "Ask your team owner to reconnect YouTube"
        }
    }
}

/// The team's open match, as it stands, with Film and Score.
private struct ActiveMatchCard: View {
    let match: MatchSnapshot
    let watchLink: MatchYouTube?
    let busy: Bool
    let open: (MatchSession.Kind) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusDot(color: Theme.live)
                Text(match.broadcast.desired == .running ? "Live · Set \(match.score.set)" : "Match open · Set \(match.score.set)")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                Spacer()
                if let url = watchLink?.url {
                    ShareLink(item: url, subject: Text("Watch our match live"),
                              message: Text("Watch \(match.teams.home.name) vs \(match.teams.away.name) live on YouTube: \(url.absoluteString)")) {
                        Label("Watch link", systemImage: "play.rectangle.fill").font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(Theme.text)
                    .accessibilityIdentifier("home.match.watchLink")
                }
            }
            .padding(.horizontal, 16).padding(.top, 14)
            row(.team1).padding(.top, 10).padding(.bottom, 6)
            row(.team2).padding(.bottom, 12)
            Divider().overlay(Theme.line)
            HStack(spacing: 10) {
                Button { open(.filming) } label: { Label("Film", systemImage: "video.fill") }
                    .buttonStyle(BigButtonStyle(kind: .surface, height: 48))
                    .accessibilityIdentifier("home.match.film")
                Button { open(.scoring) } label: { Label("Score", systemImage: "hand.tap.fill") }
                    .buttonStyle(BigButtonStyle(height: 48))
                    .accessibilityIdentifier("home.match.score")
            }
            .disabled(busy)
            .padding(12)
        }
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ slot: TeamSlot) -> some View {
        let team = match.teams[slot]
        return HStack {
            TeamChip(team: team, size: 24)
            Spacer()
            Text("\(match.score.sets(slot))").font(Theme.score(20, weight: .semibold)).foregroundStyle(Theme.secondary)
                .accessibilityLabel("\(match.score.sets(slot)) sets")
            Text("\(match.score.points(slot))").font(Theme.score(34)).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

private struct NoTeamCard: View {
    let create: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up your team").font(Theme.score(26))
            Text("Create your team, then invite the parents and scorers who help at matches. Joining someone else's team? Open the invite link they sent you.")
                .font(.subheadline).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Button(action: create) { Label("Create team", systemImage: "plus") }
                .buttonStyle(BigButtonStyle())
                .accessibilityIdentifier("home.createTeam")
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A row that pushes another screen: "Recordings   3 saved ›".
struct RowLabel: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.body.weight(.semibold))
            Spacer()
            if let detail { Text(detail).font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondary) }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
        }
        .padding(16).frame(minHeight: 56)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct CreateTeamSheet: View {
    @ObservedObject var home: HomeModel
    @ObservedObject var app: AppModel
    let created: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                SectionLabel("Team name")
                TextField("Cascade 14 Black", text: $name)
                    .textInputAutocapitalization(.words)
                    .fieldStyle()
                    .accessibilityIdentifier("createTeam.name")
                Text("The name shows on your matches. You can change it later.")
                    .font(.footnote).foregroundStyle(Theme.secondary)
                if let error = home.error { Text(error).font(.callout).foregroundStyle(Theme.warn) }
                Spacer()
                Button {
                    Task {
                        guard let id = await home.createTeam(name: name, app: app) else { return }
                        dismiss()
                        created(id)
                    }
                } label: {
                    if home.busy { ProgressView().tint(Theme.ground) } else { Text("Create team") }
                }
                .buttonStyle(BigButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || home.busy)
                .accessibilityIdentifier("createTeam.submit")
            }
            .padding(20)
            .background(Color(hex: "#111418").ignoresSafeArea())
            .navigationTitle("New team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { home.error = nil; dismiss() } } }
        }
    }
}

struct LastMatchCard: View {
    let recap: MatchRecap
    var body: some View {
        VStack(spacing: 0) {
            row(recap.team1, winner: recap.team1.score >= recap.team2.score).padding(.top, 16).padding(.bottom, 8)
            row(recap.team2, winner: recap.team2.score > recap.team1.score).padding(.bottom, 12)
            Divider().overlay(Theme.line)
            HStack {
                Text(recap.status)
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
            Text("\(team.score)").font(Theme.score(40)).monospacedDigit().foregroundStyle(winner ? Theme.text : Theme.secondary)
        }
        .padding(.horizontal, 16)
    }
}

struct SettingsSheet: View {
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var deleteError: String?
    @State private var developer = false

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    LabeledContent("Name", value: app.account?.person.name ?? "—")
                    LabeledContent("Email", value: app.account?.person.email ?? "—")
                }
                Section {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                        .accessibilityIdentifier("settings.signOut")
                } footer: {
                    Text("Recordings stay on this phone. Sign in again any time.")
                }
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        if app.busy { ProgressView() } else { Text("Delete account") }
                    }
                    .disabled(app.busy)
                    .accessibilityIdentifier("settings.deleteAccount")
                } footer: {
                    if let error = deleteError {
                        Text(error).foregroundStyle(Theme.warn).accessibilityIdentifier("settings.deleteAccount.error")
                    } else {
                        Text("Deletes your Scorebug account and its data for good.")
                    }
                }
                #if DEBUG
                Section("Developer") {
                    Button { developer = true } label: {
                        LabeledContent("Server", value: app.server.url.absoluteString)
                    }
                    .accessibilityIdentifier("settings.developer")
                }
                #endif
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out of Scorebug?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { dismiss(); await app.signOut() } }
            }
            .alert("Delete your Scorebug account?", isPresented: $confirmDelete) {
                Button("Delete account", role: .destructive) { Task { await deleteAccount() } }
                    .accessibilityIdentifier("settings.deleteAccount.confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(Self.deleteMessage)
            }
            .sheet(isPresented: $developer) { DeveloperServerSheet(app: app) }
        }
    }

    /// Exactly what DELETE /v1/me removes (apps/control-plane/src/worker/account.ts).
    static let deleteMessage = """
        This can't be undone. Scorebug deletes your account, signs you out on every device, \
        and removes your YouTube channel connections and Scorebug's access to them. A match \
        streaming to your channel stops.

        Teams only you are on are deleted with their matches. You leave teams with other people; \
        if you're the only owner, the longest-standing member becomes owner.

        Recordings stay on this iPhone.
        """

    private func deleteAccount() async {
        deleteError = nil
        if await app.deleteAccount() { dismiss() } else { deleteError = app.error ?? "Couldn't delete your account. Try again." }
    }
}
