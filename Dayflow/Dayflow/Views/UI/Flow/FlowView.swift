import SwiftUI

/// Flow owns its tasks and sessions on this Mac; only model inference uses the selected CLI.
struct FlowView: View {
  @Environment(\.dayflowTheme) private var theme
  @ObservedObject private var mirror = FlowSessionMirror.shared
  @ObservedObject private var timeline = FlowSessionTimeline.shared
  @ObservedObject private var agent = FlowDistractionAgent.shared
  @ObservedObject private var appState = AppState.shared
  @AppStorage("flowLocalTaskDraft") private var taskDraft = ""
  @AppStorage("flowLocalDuration") private var minutes = 50
  @State private var alertStyle: FlowAlertStyle = .friendly

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(spacing: 20) {
          Image("FlowWaitlistCreature")
            .resizable().scaledToFit().frame(width: 88, height: 88)
          VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.custom("InstrumentSerif-Regular", size: 42))
            Text("Your tasks and session stay on this Mac.")
              .foregroundStyle(theme.textSecondary)
          }
        }
        if mirror.snapshot.phase == .idle {
          setup
        } else {
          session
        }
      }
      .font(.custom("Figtree", size: 14))
      .foregroundStyle(theme.textPrimary)
      .padding(36)
      .frame(maxWidth: 950, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .background(theme.panelFill)
  }

  private var title: String {
    switch mirror.snapshot.phase {
    case .idle: return "Find your flow"
    case .active: return "Time to focus"
    case .onBreak: return "Take a break"
    case .ended: return "Session complete"
    }
  }

  private var setup: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("What do you want to work on?").font(.headline)
      Text("One task per line. Flow can check tasks off as you finish them.")
        .foregroundStyle(theme.textSecondary)
      TextEditor(text: $taskDraft)
        .font(.custom("Figtree", size: 15))
        .frame(height: 130).padding(8)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.textMuted.opacity(0.3)))
        .accessibilityLabel("Session tasks")
      HStack {
        Picker("Duration", selection: $minutes) {
          ForEach([15, 25, 50, 90], id: \.self) { Text("\($0) min").tag($0) }
        }
        Picker("Reminders", selection: $alertStyle) {
          ForEach(FlowAlertStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
      }
      FlowProviderPicker()
      Button("Start session") {
        mirror.startSession(
          titles: taskDraft.components(separatedBy: .newlines), minutes: minutes,
          alertStyle: alertStyle)
      }
      .buttonStyle(.borderedProminent).tint(theme.accent)
      .disabled(taskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  private var session: some View {
    VStack(alignment: .leading, spacing: 20) {
      if mirror.isSessionOn {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let deadline =
            mirror.snapshot.phase == .onBreak
            ? mirror.snapshot.breakEndsAt : mirror.snapshot.sessionEndsAt
          let remaining = max(
            0,
            (deadline ?? Int(context.date.timeIntervalSince1970))
              - Int(context.date.timeIntervalSince1970))
          Text(String(format: "%02d:%02d", remaining / 60, remaining % 60))
            .font(.custom("Figtree", size: 40)).monospacedDigit()
        }
        Text(agent.statusLine).foregroundStyle(theme.textSecondary)
        if !appState.isRecording {
          Text("Dayflow recording is paused. Resume recording to let Flow watch the screen.")
            .foregroundStyle(.orange)
        }
        if agent.statusLine == "Failed to start" || agent.statusLine.hasPrefix("Stopped after") {
          if let message = agent.transcript.last?.text {
            Text(String(message.prefix(600))).font(.caption).foregroundStyle(.secondary)
          }
        }
        HStack {
          if mirror.snapshot.phase == .active {
            Button("Take a 5 min break") { mirror.menuBarControl("break", minutes: 5) }
          } else {
            Button("Resume") { mirror.menuBarControl("resume") }
          }
          Button("End session") { mirror.menuBarControl("end") }
          Button("Retry agent") { agent.start(with: mirror.snapshot) }
            .disabled(mirror.snapshot.phase == .onBreak)
        }.buttonStyle(.bordered)
      }
      tasks
      HStack(spacing: 16) {
        metric("Focused", kind: .focused)
        metric("Distracted", kind: .distracted)
        metric("Breaks", kind: .break)
        VStack(alignment: .leading, spacing: 6) {
          Text("Focus").foregroundStyle(theme.textSecondary)
          Text(focusPercentage).font(.title2)
        }.frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .leading, spacing: 6) {
          Text("Nudges").foregroundStyle(theme.textSecondary)
          Text("\(mirror.snapshot.nudgeCount ?? 0)").font(.title2)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      VStack(alignment: .leading, spacing: 14) {
        Text("Timeline").font(.headline)
        if !timeline.entries.isEmpty {
          GeometryReader { geometry in
            let total = timeline.entries.reduce(0.0) {
              $0 + max(0, $1.endedAt.timeIntervalSince($1.startedAt))
            }
            HStack(spacing: 0) {
              ForEach(timeline.entries) { entry in
                color(entry.kind).frame(
                  width: total > 0
                    ? geometry.size.width * max(0, entry.endedAt.timeIntervalSince(entry.startedAt))
                      / total : 0)
              }
            }.clipShape(RoundedRectangle(cornerRadius: 6))
          }.frame(height: 20)
        }
        if timeline.entries.isEmpty {
          Text("No activity has been analyzed yet. Flow updates the timeline during the session.")
            .foregroundStyle(theme.textSecondary)
        }
        ForEach(timeline.entries) { entry in
          HStack(alignment: .top, spacing: 14) {
            Text(
              "\(FlowSessionTimeline.clock(entry.startedAt)) – \(FlowSessionTimeline.clock(entry.endedAt))"
            )
            .monospacedDigit().frame(width: 115, alignment: .leading)
            Circle().fill(color(entry.kind)).frame(width: 8, height: 8).padding(.top, 5)
            Text(entry.title).frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.category ?? entry.kind.rawValue.capitalized)
              .foregroundStyle(theme.textSecondary)
          }
          Divider()
        }
      }.padding(20).background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
      if mirror.snapshot.phase == .ended {
        HStack {
          Button("Start a new session") { mirror.apply(.idle) }
            .buttonStyle(.borderedProminent).tint(theme.accent)
          Button("Keep going for 10 min") {
            mirror.continueSession()
          }.buttonStyle(.bordered)
        }
      }
    }
  }

  private var tasks: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(mirror.snapshot.goalTasks ?? [], id: \.id) { task in
        Button {
          mirror.completeTasks(ids: [task.id])
        } label: {
          Label(task.title, systemImage: "circle")
        }.buttonStyle(.plain).disabled(!mirror.isSessionOn)
      }
      ForEach(mirror.snapshot.completedTasks ?? [], id: \.id) { task in
        Label(task.title, systemImage: "checkmark.circle.fill").foregroundStyle(theme.textSecondary)
      }
    }
  }

  private func metric(_ title: String, kind: FlowSessionTimeline.Kind) -> some View {
    let seconds = timeline.entries.filter { $0.kind == kind }
      .reduce(0.0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) }
    return VStack(alignment: .leading, spacing: 6) {
      Text(title).foregroundStyle(theme.textSecondary)
      Text("\(Int(seconds / 60))m").font(.title2).foregroundStyle(color(kind))
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private var focusPercentage: String {
    let focused = timeline.entries.filter { $0.kind == .focused }
      .reduce(0.0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) }
    let total = timeline.entries.filter { $0.kind != .break }
      .reduce(0.0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) }
    return total > 0 ? "\(Int(100 * focused / total))%" : "—"
  }

  private func color(_ kind: FlowSessionTimeline.Kind) -> Color {
    switch kind {
    case .focused: return .teal
    case .distracted: return .orange
    case .break: return .gray
    }
  }
}

struct FlowProviderPicker: View {
  @ObservedObject private var settings = FlowAgentSettings.shared
  @ObservedObject private var mirror = FlowSessionMirror.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("Flow model", selection: $settings.provider) {
        ForEach(FlowAgentSettings.Provider.allCases) { provider in
          Text(provider.title).tag(provider)
        }
      }.disabled(mirror.isSessionOn)
      Toggle("Watch the screen during Flow sessions", isOn: $settings.agentEnabled)
        .disabled(mirror.isSessionOn)
      Text(
        "Uses your signed-in Claude or Codex CLI. Screen checks go to that AI provider. No Dayflow account or Flow server is required."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }
}
