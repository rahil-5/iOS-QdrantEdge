import SwiftUI

/// A single reason the keeper was chosen, so the recommendation is never opaque.
struct HighlightChip: View {
    let highlight: QualityHighlight

    var body: some View {
        Label(highlight.rawValue, systemImage: highlight.symbolName)
            .font(.caption2.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.tint.opacity(0.14), in: Capsule())
            .foregroundStyle(.tint)
    }
}

/// How confident the scanner is that a group really is one picture.
struct ConfidenceBadge: View {
    let group: DuplicateGroup

    var body: some View {
        Text(group.confidenceLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch group.confidence {
        case 0.92...: .green
        case 0.75..<0.92: .blue
        default: .orange
        }
    }
}

/// Filter pill for the results screen.
struct FilterChip: View {
    let title: String
    let systemImage: String
    let count: Int
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(isOn ? .white.opacity(0.75) : .secondary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial),
                in: Capsule()
            )
            .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
