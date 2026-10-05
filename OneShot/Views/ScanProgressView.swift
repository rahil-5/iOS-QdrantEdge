import SwiftUI

/// Live progress through the pipeline.
///
/// Shows the named phase rather than one anonymous spinner, because the first scan
/// of a large library takes long enough that "what is it doing" is a fair question.
struct ScanProgressView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // The ring tracks the phase in front of the user, restarting at zero for
            // each one, rather than one number creeping across the whole pipeline.
            ProgressRing(fraction: library.phase.fraction ?? 0)
                .frame(width: 156, height: 156)

            VStack(spacing: 8) {
                Text(library.phase.title)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.opacity)

                Text(library.phase.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .frame(minHeight: 40, alignment: .top)

                if let counts = itemCounts {
                    Text(counts)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            stepList
                .padding(.horizontal, 28)

            Spacer()

            Button(role: .cancel) {
                library.cancelScan()
            } label: {
                Text("Cancel")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .animation(.smooth(duration: 0.3), value: library.phase)
    }

    private var itemCounts: String? {
        switch library.phase {
        case .indexing(let done, let total),
             .fingerprinting(let done, let total),
             .scoring(let done, let total):
            guard total > 0 else { return nil }
            return "\(done.formatted()) of \(total.formatted())"
        default:
            return nil
        }
    }

    /// One row per phase, each with its own 0–100% bar.
    private var stepList: some View {
        VStack(spacing: 14) {
            ForEach(Array(ScanPhase.stepTitles.enumerated()), id: \.offset) { index, title in
                StepProgressRow(
                    title: title,
                    progress: library.phase.progress(ofStep: index),
                    isActive: library.phase.pipelinePosition?.index == index,
                    hasStarted: library.phase.hasReached(step: index)
                )
            }
        }
    }
}

/// One pipeline step with its own bar.
private struct StepProgressRow: View {
    let title: String
    let progress: Double
    let isActive: Bool
    let hasStarted: Bool

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                Spacer()
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(labelStyle)

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                // A step not yet reached is muted so the eye lands on the one
                // actually running.
                .tint(hasStarted ? Color.accentColor : Color.secondary.opacity(0.35))
        }
        .animation(.smooth(duration: 0.3), value: progress)
    }

    private var labelStyle: HierarchicalShapeStyle {
        if isActive { return .primary }
        return hasStarted ? .secondary : .tertiary
    }
}

/// Circular determinate progress with a soft trailing cap.
struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 14)

            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                // A single flat colour, not an angular gradient. The gradient swept
                // from 55% opacity up to full across the sweep, so the beginning of
                // the arc read visibly dimmer than the end and left a seam partway
                // round the ring.
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .animation(.smooth(duration: 0.4), value: fraction)
    }
}
