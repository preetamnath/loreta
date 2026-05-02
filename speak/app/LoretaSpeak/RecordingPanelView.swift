import SwiftUI

struct RecordingPanelView: View {
    @ObservedObject var recordingState: RecordingState

    var body: some View {
        Group {
            switch recordingState.panelPresentation {
            case .hidden:
                EmptyView()
            case .recording(let presentation):
                ActiveRecordingCapsuleView(
                    presentation: presentation,
                    cancelAction: { Task { await recordingState.cancelRecording() } },
                    finishAction: { Task { await recordingState.finishRecording() } }
                )
            case .status(let presentation):
                StatusPanelView(presentation: presentation)
            }
        }
    }
}

private struct ActiveRecordingCapsuleView: View {
    let presentation: RecordingPresentation
    let cancelAction: () -> Void
    let finishAction: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            LogoMark()

            AudioVisualizer(level: presentation.audioLevel)

            Text(formatElapsed(presentation.elapsedSeconds))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(width: 42, alignment: .trailing)

            RecordingControlButton(
                systemName: "xmark",
                accessibilityLabel: "Cancel recording",
                foregroundStyle: Color(red: 0.70, green: 0.73, blue: 0.78),
                backgroundStyle: Color.white.opacity(0.08),
                action: cancelAction
            )

            RecordingControlButton(
                systemName: "checkmark",
                accessibilityLabel: "Finish recording",
                foregroundStyle: .white,
                backgroundStyle: Color(red: 0.16, green: 0.45, blue: 0.95),
                action: finishAction
            )
        }
        .padding(.horizontal, 10)
        .frame(width: 286, height: 42)
        .background(Color(red: 0.055, green: 0.062, blue: 0.070).opacity(0.92), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.10))
        }
        .shadow(color: .black.opacity(0.28), radius: 14, y: 7)
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct StatusPanelView: View {
    let presentation: StatusPresentation

    var body: some View {
        switch presentation.layout {
        case .compact:
            CompactStatusPillView(presentation: presentation)
        case .recovery:
            RecoveryStatusPanelView(presentation: presentation)
        }
    }
}

private struct CompactStatusPillView: View {
    let presentation: StatusPresentation

    var body: some View {
        HStack(spacing: 10) {
            LogoMark()

            Spacer(minLength: 0)

            CompactStatusContentView(presentation: presentation)
        }
        .padding(.horizontal, 10)
        .frame(width: presentation.panelSize.width, height: presentation.panelSize.height)
        .background(Color(red: 0.055, green: 0.062, blue: 0.070).opacity(0.94), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(borderColor)
        }
        .shadow(color: .black.opacity(0.28), radius: 14, y: 7)
    }

    private var borderColor: Color {
        switch presentation.tone {
        case .neutral, .processing:
            return .white.opacity(0.10)
        case .success:
            return Color(red: 0.24, green: 0.72, blue: 0.44).opacity(0.28)
        case .error:
            return Color(red: 0.84, green: 0.36, blue: 0.41).opacity(0.28)
        }
    }
}

private struct RecoveryStatusPanelView: View {
    let presentation: StatusPresentation

    var body: some View {
        HStack(spacing: 10) {
            StatusIconView(presentation: presentation)

            if presentation.hasDetail {
                VStack(alignment: .leading, spacing: 2) {
                    title
                    detail
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                title
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: presentation.panelSize.width, height: presentation.panelSize.height)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(borderColor)
        }
        .shadow(color: .black.opacity(0.24), radius: 14, y: 7)
    }

    private var title: some View {
        Text(presentation.title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    private var detail: some View {
        Text(presentation.detail ?? "")
            .font(.system(size: 11.5, weight: .regular))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var backgroundColor: Color {
        switch presentation.tone {
        case .neutral, .processing:
            return Color(red: 0.055, green: 0.062, blue: 0.070).opacity(0.94)
        case .success:
            return Color(red: 0.052, green: 0.071, blue: 0.078).opacity(0.95)
        case .error:
            return Color(red: 0.078, green: 0.058, blue: 0.064).opacity(0.95)
        }
    }

    private var borderColor: Color {
        switch presentation.tone {
        case .neutral, .processing:
            return .white.opacity(0.10)
        case .success:
            return Color(red: 0.18, green: 0.46, blue: 0.96).opacity(0.28)
        case .error:
            return Color(red: 0.84, green: 0.36, blue: 0.41).opacity(0.28)
        }
    }
}

private struct CompactStatusContentView: View {
    let presentation: StatusPresentation

    var body: some View {
        HStack(spacing: 7) {
            switch presentation.icon {
            case .processing:
                ProgressView()
                    .controlSize(.small)
                    .tint(Color(red: 0.39, green: 0.60, blue: 1.0))
                    .scaleEffect(0.78)
            case .cancelled:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color(red: 0.72, green: 0.75, blue: 0.80))
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color(red: 0.27, green: 0.78, blue: 0.47))
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color(red: 0.94, green: 0.62, blue: 0.66))
            }

            if presentation.hasTitle {
                Text(presentation.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}

private struct StatusIconView: View {
    let presentation: StatusPresentation

    var body: some View {
        ZStack {
            Circle()
                .fill(iconBackground)
                .frame(width: 22, height: 22)

            switch presentation.icon {
            case .processing:
                ProgressView()
                    .controlSize(.small)
                    .tint(iconForeground)
                    .scaleEffect(0.7)
            case .cancelled:
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(iconForeground)
            case .success:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(iconForeground)
            case .error:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(iconForeground)
            }
        }
        .accessibilityHidden(true)
    }

    private var iconBackground: Color {
        switch presentation.tone {
        case .neutral:
            return Color.white.opacity(0.09)
        case .processing, .success:
            return Color(red: 0.16, green: 0.45, blue: 0.95).opacity(0.22)
        case .error:
            return Color(red: 0.84, green: 0.36, blue: 0.41).opacity(0.22)
        }
    }

    private var iconForeground: Color {
        switch presentation.tone {
        case .neutral:
            return Color(red: 0.76, green: 0.79, blue: 0.84)
        case .processing:
            return Color(red: 0.39, green: 0.60, blue: 1.0)
        case .success:
            return Color(red: 0.27, green: 0.78, blue: 0.47)
        case .error:
            return Color(red: 0.94, green: 0.62, blue: 0.66)
        }
    }
}

private struct LogoMark: View {
    var body: some View {
        Text("L")
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.20, green: 0.49, blue: 0.98))
            .frame(width: 24, height: 24)
    }
}

private struct AudioVisualizer: View {
    let level: Double

    private let barCount = 15

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * 5.2

            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(barColor(for: index))
                        .frame(width: 3, height: barHeight(for: index, phase: phase))
                }
            }
        }
        .frame(width: 78, height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone audio level")
    }

    private func barHeight(for index: Int, phase: TimeInterval) -> CGFloat {
        let position = Double(index) / Double(max(1, barCount - 1))
        let carrier = 0.5 + 0.5 * sin((position * .pi * 3.4) + phase)
        let shimmer = 0.5 + 0.5 * sin((position * .pi * 7.0) - (phase * 0.7))
        let activity = max(0.12, min(1.0, level))
        let height = 4.0 + (carrier * 7.0 + shimmer * 5.0) * activity
        return CGFloat(min(20, height))
    }

    private func barColor(for index: Int) -> Color {
        let distanceFromCenter = abs(Double(index) - Double(barCount - 1) / 2)
        let centerWeight = 1 - distanceFromCenter / Double(barCount)
        return Color(red: 0.18, green: 0.46, blue: 0.96).opacity(0.42 + centerWeight * 0.38)
    }
}

private struct RecordingControlButton: View {
    let systemName: String
    let accessibilityLabel: String
    let foregroundStyle: Color
    let backgroundStyle: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(foregroundStyle)
                .frame(width: 24, height: 24)
                .background(backgroundStyle, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
