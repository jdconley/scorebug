import ScorebugCore
import SwiftUI

/// Everything for a match on one sheet. "Go live" starts recording and the stream together.
struct NewMatchSheet: View {
    @ObservedObject var app: AppModel
    @StateObject private var model: NewMatchModel
    @State private var recordOnlyChoice = false
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, model: NewMatchModel) {
        self.app = app
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TeamEditor(slot: .team1, team: $model.draft.team1)
                    TeamEditor(slot: .team2, team: $model.draft.team2)
                    formatPicker
                    stylePicker
                    settingsGroup
                    if let error = model.error {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(error).font(.callout).foregroundStyle(Theme.warn).accessibilityIdentifier("newMatch.error")
                            if model.otherMatchOpen {
                                Button("Close the other match") { Task { await model.closeOtherMatch() } }
                                    .buttonStyle(BigButtonStyle(kind: .surface, height: 48))
                                    .disabled(model.busy)
                            }
                        }
                    }
                    actions
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(hex: "#111418").ignoresSafeArea())
            .navigationTitle("New match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Theme.secondary)
                }
            }
        }
        .task { await model.loadDestinations() }
        .interactiveDismissDisabled(model.busy)
    }

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Format")
            SegmentedChoice(options: MatchFormat.allCases, selection: $model.draft.format) { $0.label }
        }
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Scorebug on the stream")
            HStack(spacing: 10) {
                ForEach(ScorebugStyle.allCases, id: \.self) { style in
                    Button { model.draft.style = style } label: {
                        VStack(spacing: 8) {
                            ScorebugPreview(style: style, team1: model.draft.team1.color, team2: model.draft.team2.color)
                                .frame(height: 54)
                            Text(style.label).font(.footnote.weight(.semibold))
                                .foregroundStyle(model.draft.style == style ? Theme.text : Theme.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(model.draft.style == style ? Theme.text : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.label)
                    .accessibilityAddTraits(model.draft.style == style ? .isSelected : [])
                }
            }
        }
    }

    private var settingsGroup: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach(model.destinations) { destination in
                    Button { recordOnlyChoice = false; model.chooseDestination(destination) } label: {
                        Text(destination.name + (destination.isDefault ? " (default)" : ""))
                    }
                }
                if model.destinations.isEmpty {
                    Button { recordOnlyChoice = false } label: { Text("Server default") }
                }
                Divider()
                Button { recordOnlyChoice = true } label: { Text("Record only") }
            } label: {
                HStack {
                    Text("Stream to").foregroundStyle(Theme.text)
                    Spacer()
                    Text(recordOnlyChoice ? "Record only" : model.streamLabel).foregroundStyle(Theme.muted)
                    Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 14).frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("newMatch.streamTo")
            Divider().overlay(Theme.line).padding(.leading, 14)
            Toggle(isOn: $model.draft.recordIn4K) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record in 4K")
                    Text("Runs the phone hotter. The stream stays 1080p or lower.").font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            .tint(Theme.ok)
            .padding(.horizontal, 14).frame(minHeight: 60)
            .accessibilityIdentifier("newMatch.record4K")
        }
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var actions: some View {
        VStack(spacing: 14) {
            if recordOnlyChoice {
                Button { start(recordOnly: true) } label: { busyLabel("Start recording") }
                    .buttonStyle(BigButtonStyle())
                    .disabled(!model.canStart)
                    .accessibilityIdentifier("newMatch.record")
            } else {
                Button { start(recordOnly: false) } label: {
                    HStack(spacing: 10) {
                        Circle().fill(.white).frame(width: 10, height: 10).accessibilityHidden(true)
                        busyLabel("Go live")
                    }
                }
                .buttonStyle(BigButtonStyle(kind: .live))
                .disabled(!model.canStart)
                .accessibilityIdentifier("newMatch.goLive")
                Button("Record only, don't stream") { start(recordOnly: true) }
                    .foregroundStyle(Theme.muted).frame(minHeight: 44)
                    .disabled(!model.canStart)
                    .accessibilityIdentifier("newMatch.recordOnly")
            }
            if !model.draft.isValid, let issue = model.issues.first {
                Text(issue.message).font(.footnote).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder private func busyLabel(_ title: String) -> some View {
        if model.busy { ProgressView().tint(.white) } else { Text(title) }
    }

    private func start(recordOnly: Bool) {
        Task {
            guard let session = await model.start(recordOnly: recordOnly) else { return }
            dismiss()
            app.begin(session)
        }
    }
}

private struct TeamEditor: View {
    let slot: TeamSlot
    @Binding var team: TeamDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(slot.label)
            HStack(spacing: 10) {
                Circle().fill(Theme.teamColor(team.color)).frame(width: 22, height: 22).accessibilityHidden(true)
                TextField("Team name", text: Binding(get: { team.name }, set: { team.setName($0) }))
                    .font(.system(size: 17))
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .accessibilityLabel("\(slot.label) name")
                    .accessibilityIdentifier("newMatch.\(slot.rawValue).name")
            }
            .fieldStyle()
            HStack(spacing: 10) {
                Text("Short name").font(.subheadline).foregroundStyle(Theme.secondary)
                TextField("SHORT", text: Binding(get: { team.shortName }, set: { team.setShortName($0) }))
                    .font(Theme.score(22))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .accessibilityLabel("\(slot.label) short name, up to 8 characters")
                    .accessibilityIdentifier("newMatch.\(slot.rawValue).short")
                Text("\(team.shortName.count)/8").font(.caption).monospacedDigit().foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(TeamPalette.swatches) { swatch in
                        Button { team.color = swatch.hex } label: {
                            Circle().fill(Color(hex: swatch.hex)).frame(width: 32, height: 32)
                                .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                                .overlay(Circle().stroke(Theme.text, lineWidth: team.color.lowercased() == swatch.hex ? 3 : 0).padding(-4))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(swatch.name)
                        .accessibilityAddTraits(team.color.lowercased() == swatch.hex ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }
}

struct SegmentedChoice<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.system(size: 15, weight: selection == option ? .semibold : .medium))
                        .foregroundStyle(selection == option ? Theme.ground : Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(selection == option ? Theme.text : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension ScorebugStyle {
    var label: String {
        switch self {
        case .bar: "Bar"
        case .lowerThird: "Lower third"
        case .setCard: "Set card"
        }
    }
}

/// A tiny 16:9 sketch of where each scorebug style sits on the stream.
struct ScorebugPreview: View {
    let style: ScorebugStyle
    let team1: String
    let team2: String

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: "#3A3F47"))
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: "#8A6A4A")).frame(width: w * 0.8, height: h * 0.42)
                    .offset(x: w * 0.1, y: h * 0.52)
                switch style {
                case .bar:
                    bug(rows: 2).frame(width: w * 0.42, height: h * 0.3).offset(x: w * 0.05, y: h * 0.07)
                case .lowerThird:
                    HStack(spacing: 2) {
                        chip(team1); Rectangle().fill(.white.opacity(0.85)).frame(width: w * 0.12)
                        chip(team2)
                    }
                    .padding(3)
                    .frame(width: w * 0.7, height: h * 0.18)
                    .background(Theme.ground.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
                    .offset(x: w * 0.15, y: h * 0.72)
                case .setCard:
                    bug(rows: 2, columns: 3).frame(width: w * 0.5, height: h * 0.36).offset(x: w * 0.05, y: h * 0.07)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func chip(_ hex: String) -> some View { Rectangle().fill(Color(hex: hex)) }

    private func bug(rows: Int, columns: Int = 1) -> some View {
        VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 2) {
                    Rectangle().fill(Color(hex: row == 0 ? team1 : team2)).frame(width: 3)
                    Rectangle().fill(.white.opacity(0.75))
                    ForEach(0..<columns, id: \.self) { _ in Rectangle().fill(.white.opacity(0.4)).frame(width: 5) }
                }
            }
        }
        .padding(3)
        .background(Theme.ground.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
    }
}
