import ScorebugCore
import SwiftUI
import UIKit

/// A team's members and invites. Owners rename the team, invite people by email or
/// with a link, revoke invites and remove members. Anyone can leave.
struct TeamView: View {
    @ObservedObject var app: AppModel
    @StateObject private var model: TeamModel
    let left: () -> Void
    @State private var renaming = false
    @State private var newName = ""
    @State private var inviting = false
    @State private var removing: TeamMember?
    @State private var revoking: TeamInvite?
    @State private var confirmLeave = false

    init(app: AppModel, teamId: String, left: @escaping () -> Void) {
        self.app = app
        self.left = left
        _model = StateObject(wrappedValue: TeamModel(teamId: teamId))
    }

    private var team: TeamMembership? { app.teams.first { $0.id == model.teamId } }
    private var name: String { model.detail?.team.name ?? team?.name ?? "Team" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(Theme.warn).accessibilityIdentifier("team.error")
                }
                if model.detail != nil { ChannelSection(app: app, model: model) }
                if model.isOwner { invitesSection }
                membersSection
                Button(role: .destructive) { confirmLeave = true } label: { Text("Leave team") }
                    .foregroundStyle(Theme.live).frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("team.leave")
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isOwner {
                ToolbarItem(placement: .primaryAction) {
                    Button("Rename") { newName = name; renaming = true }.accessibilityIdentifier("team.rename")
                }
            }
        }
        .alert("Rename team", isPresented: $renaming) {
            TextField("Team name", text: $newName)
            Button("Save") { Task { await model.rename(newName, app: app) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(removing.map { "Remove \($0.displayName) from \(name)?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { member in
            Button("Remove", role: .destructive) { Task { await model.remove(member, app: app) } }
        } message: { _ in Text("They lose access to the team's matches. You can invite them again.") }
        .confirmationDialog("Revoke this invite?",
                            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible, presenting: revoking) { invite in
            Button("Revoke invite", role: .destructive) { Task { await model.revoke(invite, app: app) } }
        } message: { _ in Text("The link and code stop working. Anyone who already joined stays on the team.") }
        .confirmationDialog("Leave \(name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave team", role: .destructive) { Task { if await model.leave(app: app) { left() } } }
        } message: { Text("You won't see the team's matches until someone invites you again.") }
        .sheet(isPresented: $inviting) { InviteMemberSheet(app: app, model: model, teamName: name) }
        .task { await model.load(app) }
        .refreshable { await model.load(app) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 4).fill(Theme.teamColor(model.detail?.team.color ?? team?.color))
                .frame(width: 8, height: 52).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.score(32)).lineLimit(2).accessibilityAddTraits(.isHeader)
                Text(roleLine).font(.subheadline).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private var roleLine: String {
        let count = model.members.count
        let people = count == 1 ? "1 person" : "\(count) people"
        guard model.detail != nil else { return team?.isOwner == true ? "You own this team" : "You're a member" }
        return "\(model.isOwner ? "You own this team" : "You're a member") · \(people)"
    }

    private var invitesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Invites")
            Button { model.issued = nil; model.error = nil; inviting = true } label: {
                Label("Invite people", systemImage: "person.badge.plus")
            }
            .buttonStyle(BigButtonStyle())
            .accessibilityIdentifier("team.invite")
            Text("People you invite can film, score and go live with the team. They sign in with Google.")
                .font(.footnote).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.invites.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(model.invites.enumerated()), id: \.element.id) { index, invite in
                        if index > 0 { Divider().overlay(Theme.line).padding(.leading, 16) }
                        InviteRow(invite: invite) { revoking = invite }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Members")
            if model.detail == nil, model.error == nil {
                ProgressView().frame(maxWidth: .infinity).padding(20)
            }
            VStack(spacing: 0) {
                ForEach(Array(model.members.enumerated()), id: \.element.id) { index, member in
                    if index > 0 { Divider().overlay(Theme.line).padding(.leading, 16) }
                    MemberRow(member: member, isYou: member.personId == app.account?.person.id,
                              canRemove: model.isOwner && member.personId != app.account?.person.id) { removing = member }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// Where the team's matches go live. Owners connect, pick, reconnect or re-check a channel;
/// members see where it goes, or who to ask.
private struct ChannelSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: TeamModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("YouTube channel")
            if let channel = model.channel { current(channel) } else { none }
        }
    }

    private func current(_ channel: TeamYouTube) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ChannelThumbnail(url: channel.channelThumbnail)
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.channelTitle).font(.body.weight(.semibold)).lineLimit(1)
                        .accessibilityIdentifier("team.channel.title")
                    HStack(spacing: 6) {
                        StatusDot(color: channel.status == .ready ? Theme.ok : Theme.warn)
                        Text(statusLine(channel)).font(.footnote).foregroundStyle(channel.status == .ready ? Theme.secondary : Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("team.channel.status")
                    }
                }
                Spacer(minLength: 0)
            }
            if model.isOwner {
                if channel.status == .needsReconnect, model.ownsChannel(app) {
                    Button { Task { await model.connectChannel(app: app) } } label: {
                        Label("Reconnect YouTube", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(BigButtonStyle(height: 52))
                    .disabled(model.busy)
                    .accessibilityIdentifier("team.channel.reconnect")
                } else if channel.status == .liveDisabled, model.ownsChannel(app) {
                    Button { Task { await model.checkChannel(app: app) } } label: { Text("Check again") }
                        .buttonStyle(BigButtonStyle(kind: .surface, height: 48))
                        .disabled(model.busy)
                        .accessibilityIdentifier("team.channel.check")
                }
                picker(label: "Change channel", current: channel.connectionId)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var none: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.isOwner
                 ? "Pick the YouTube channel your matches go live on. You connect it once; members go live without any YouTube setup."
                 : "Your team owner hasn't picked a YouTube channel yet. You can still film, score and record.")
                .font(.subheadline).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("team.channel.none")
            if model.isOwner {
                Button { Task { await model.connectChannel(app: app) } } label: {
                    Label("Connect a YouTube channel", systemImage: "play.rectangle.fill")
                }
                .buttonStyle(BigButtonStyle(height: 52))
                .disabled(model.busy)
                .accessibilityIdentifier("team.channel.connect")
                if !model.connections.isEmpty { picker(label: "Use a channel you connected", current: nil) }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func picker(label: String, current: String?) -> some View {
        Menu {
            ForEach(model.connections) { connection in
                Button { Task { await model.choose(connection, app: app) } } label: {
                    if connection.id == current { Label(connection.channelTitle, systemImage: "checkmark") }
                    else { Text(connection.channelTitle + (connection.status == .ready ? "" : " (needs attention)")) }
                }
            }
            Button { Task { await model.connectChannel(app: app) } } label: { Label("Connect another channel", systemImage: "plus") }
            if current != nil {
                Divider()
                Button(role: .destructive) { Task { await model.choose(nil, app: app) } } label: { Text("Don't go live (record only)") }
            }
        } label: {
            HStack {
                Text(label).font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(Theme.secondary)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(model.busy)
        .accessibilityIdentifier("team.channel.picker")
    }

    private func statusLine(_ channel: TeamYouTube) -> String {
        switch channel.status {
        case .ready: return "Matches go live here, unlisted"
        case .liveDisabled: return "Can't live stream yet. YouTube makes new channels wait 24 hours."
        case .needsReconnect:
            if !model.isOwner { return "Ask your team owner to reconnect YouTube" }
            return model.ownsChannel(app) ? "YouTube needs reconnecting"
                : "YouTube needs reconnecting. Ask the person who connected it, or pick another channel."
        }
    }
}

struct ChannelThumbnail: View {
    let url: String?
    var size: CGFloat = 40
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "play.rectangle.fill").font(.system(size: size * 0.45)).foregroundStyle(Theme.live)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.raised)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct MemberRow: View {
    let member: TeamMember
    let isYou: Bool
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(initials).font(.subheadline.weight(.bold)).foregroundStyle(Theme.text)
                .frame(width: 36, height: 36).background(Theme.raised, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName + (isYou ? " (you)" : "")).font(.body.weight(.semibold)).lineLimit(1)
                if member.name?.isEmpty == false {
                    Text(member.email).font(.footnote).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if member.role == .owner {
                Text("Owner").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.raised, in: Capsule())
            }
            if canRemove {
                Menu {
                    Button("Remove from team", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(Theme.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("More for \(member.displayName)")
            }
        }
        .padding(.horizontal, 16).frame(minHeight: 60)
        .accessibilityElement(children: .contain)
    }

    private var initials: String {
        let words = member.displayName.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." })
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

private struct InviteRow: View {
    let invite: TeamInvite
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: invite.email == nil ? "link" : "envelope.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
                .frame(width: 36, height: 36).background(Theme.raised, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.email ?? "Invite link").font(.body.weight(.semibold)).lineLimit(1)
                Text(expiry).font(.footnote).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            Button("Revoke", action: revoke)
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.warn)
                .frame(minHeight: 44)
                .accessibilityLabel("Revoke invite for \(invite.email ?? "the link")")
        }
        .padding(.horizontal, 16).frame(minHeight: 60)
    }

    private var expiry: String {
        guard let date = ISO8601DateFormatter.withFractions.date(from: invite.expiresAt) else { return "Open" }
        return "Expires \(date.formatted(.relative(presentation: .named)))"
    }
}

extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Invite by email (only that Google account can accept) or make a link anyone can use.
private struct InviteMemberSheet: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: TeamModel
    let teamName: String
    @State private var email = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let issued = model.issued { ready(issued) } else { form }
                    if let error = model.error {
                        Text(error).font(.callout).foregroundStyle(Theme.warn).accessibilityIdentifier("invite.error")
                    }
                }
                .padding(20)
            }
            .background(Color(hex: "#111418").ignoresSafeArea())
            .navigationTitle("Invite to \(teamName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: model.issued == nil ? .cancellationAction : .confirmationAction) {
                    Button(model.issued == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("By email")
            TextField("coach@example.com", text: $email)
                .keyboardType(.emailAddress).textContentType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .fieldStyle()
                .accessibilityIdentifier("invite.email")
            Text("Only the Google account with this email can use the invite.")
                .font(.footnote).foregroundStyle(Theme.secondary)
            Button { Task { await model.invite(email: email, app: app) } } label: {
                if model.busy { ProgressView().tint(Theme.ground) } else { Text("Create email invite") }
            }
            .buttonStyle(BigButtonStyle(height: 52))
            .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
            .accessibilityIdentifier("invite.createEmail")
            SectionLabel("Or with a link").padding(.top, 10)
            Text("Anyone with the link can join the team. Send it to your team's group chat.")
                .font(.footnote).foregroundStyle(Theme.secondary)
            Button { Task { await model.invite(email: nil, app: app) } } label: {
                Label("Create invite link", systemImage: "link")
            }
            .buttonStyle(BigButtonStyle(kind: .surface, height: 52))
            .disabled(model.busy)
            .accessibilityIdentifier("invite.createLink")
        }
    }

    private func ready(_ issued: TeamInviteIssued) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(Theme.ok)
                .accessibilityHidden(true)
            Text(issued.invite.email.map { "Invite for \($0)" } ?? "Invite link ready")
                .font(.title3.weight(.bold)).multilineTextAlignment(.center)
            Text(issued.code).font(Theme.score(40)).kerning(4).textSelection(.enabled)
                .accessibilityLabel("Code \(issued.code.map(String.init).joined(separator: " "))")
                .accessibilityIdentifier("invite.teamCode")
            Text("They open the link on their iPhone, or type the code in Scorebug → Join with a code.")
                .font(.footnote).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            if let url = URL(string: issued.link) {
                ShareLink(item: url, subject: Text("Join \(teamName) on Scorebug"), message: Text(model.shareText(issued))) {
                    Label("Share invite", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(BigButtonStyle())
                .accessibilityIdentifier("invite.share")
                Button { UIPasteboard.general.url = url } label: { Label("Copy link", systemImage: "doc.on.doc") }
                    .buttonStyle(BigButtonStyle(kind: .surface, height: 52))
            }
        }
        .frame(maxWidth: .infinity)
    }
}
