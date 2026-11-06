import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct BiteLogWidgets: WidgetBundle {
    var body: some Widget {
        LogBiteControl()
        BiteLiveActivity()
    }
}

/// The control for the Action Button, Control Center and the Lock Screen.
struct LogBiteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.bitelog.ios.log-bite") {
            ControlWidgetButton(action: LogBiteIntent()) {
                Label("Log a bite", systemImage: "fork.knife")
            }
        }
        .displayName("Log a bite")
        .description("Press to record what you ate, press again to log it.")
    }
}

/// Listening, logging, then what was logged: on the Lock Screen and in the
/// Dynamic Island.
struct BiteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BiteActivity.self) { context in
            HStack(spacing: 12) {
                PhaseIcon(phase: context.state.phase).font(.title2)
                PhaseText(state: context.state)
                Spacer()
                if context.state.phase == .listening { StopButton() }
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { PhaseIcon(phase: context.state.phase).font(.title2) }
                DynamicIslandExpandedRegion(.center) { PhaseText(state: context.state) }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase == .listening { StopButton() }
                }
            } compactLeading: {
                PhaseIcon(phase: context.state.phase)
            } compactTrailing: {
                if context.state.phase == .listening {
                    Text(timerInterval: context.state.since...Date.distantFuture, countsDown: false)
                        .monospacedDigit().frame(maxWidth: 44)
                }
            } minimal: {
                PhaseIcon(phase: context.state.phase)
            }
        }
    }
}

private struct PhaseIcon: View {
    let phase: BiteActivity.ContentState.Phase

    var body: some View {
        switch phase {
        case .listening: Image(systemName: "mic.fill").foregroundStyle(.red)
        case .logging: Image(systemName: "ellipsis")
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private struct PhaseText: View {
    let state: BiteActivity.ContentState

    var body: some View {
        switch state.phase {
        case .listening:
            VStack(alignment: .leading) {
                Text("Listening")
                Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
                    .monospacedDigit().font(.caption).foregroundStyle(.secondary)
            }
        default:
            Text(state.line).lineLimit(2)
        }
    }
}

/// Stops and logs, like pressing the control again.
private struct StopButton: View {
    var body: some View {
        Button(intent: LogBiteIntent()) {
            Label("Log it", systemImage: "stop.fill")
        }
        .tint(.red)
    }
}
