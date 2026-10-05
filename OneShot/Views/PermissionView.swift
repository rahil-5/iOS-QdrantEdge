import SwiftUI
import UniformTypeIdentifiers
import Photos

/// The gate before anything else can happen.
///
/// OneShot needs *full* library access rather than a limited selection, because a
/// duplicate is by definition a relationship between two photos — it cannot tell you
/// a photo is a copy if it can only see one of the pair. This screen explains that
/// rather than just demanding the permission.
struct PermissionView: View {
    @Environment(LibraryModel.self) private var library
    @State private var didRequest = false
    @State private var isChoosingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            iconMark
                .padding(.bottom, 28)

            Text("Find duplicate photos")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 18) {
                assurance(
                    "iphone.gen3",
                    "Everything stays on this device",
                    "Photos are analysed on device. Nothing is uploaded, and OneShot works with no internet connection at all."
                )
                assurance(
                    "checkmark.shield",
                    "Nothing is deleted without you",
                    "OneShot suggests which copy to keep. You review every group, and iOS asks you to confirm before anything moves."
                )
                assurance(
                    "arrow.uturn.backward",
                    "Recoverable for 30 days",
                    "Deleted items go to Recently Deleted in Photos, exactly as if you removed them yourself."
                )
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                actionArea

                // Not everyone wants to grant the library, and not every duplicate
                // lives in it. A folder is a complete alternative rather than a
                // consolation prize, so it is offered here rather than hidden behind
                // the permission the user just declined.
                Button {
                    isChoosingFolder = true
                } label: {
                    Text("Scan a folder instead")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .padding(.vertical, 24)
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { outcome in
            if case .success(let urls) = outcome, let url = urls.first {
                library.useFolder(url)
            }
        }
    }

    // MARK: Pieces

    private var iconMark: some View {
        ZStack {
            ForEach(Array([(-17.0, 0.30), (-8.5, 0.55)].enumerated()), id: \.offset) { _, item in
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.tint.opacity(item.1 * 0.5))
                    .frame(width: 96, height: 96)
                    .rotationEffect(.degrees(item.0))
            }
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.tint)
                .frame(width: 96, height: 96)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        }
    }

    private func assurance(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch library.authorization {
        case .notDetermined:
            // Neutral wording, deliberately. App Review rejects a pre-prompt whose
            // button reads "Allow ...", because it steers the decision that belongs
            // to the system prompt behind it. The screen above still explains why
            // the access is needed — that part is allowed, and useful.
            Button {
                didRequest = true
                Task { await library.requestAccess() }
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)

        case .limited:
            VStack(spacing: 12) {
                Text("OneShot has access to only some of your photos. It needs the full library to tell which ones are copies of each other.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                openSettingsButton("Open Settings")
            }

        case .denied, .restricted:
            VStack(spacing: 12) {
                Text("Photo access is turned off. You can turn it back on in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                openSettingsButton("Open Settings")
            }

        default:
            ProgressView()
        }
    }

    private func openSettingsButton(_ title: String) -> some View {
        Button {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        } label: {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .controlSize(.large)
    }

    private var subtitle: String {
        switch library.authorization {
        case .limited:
            "Almost there — OneShot needs to see your whole library."
        case .denied, .restricted:
            "OneShot can't see your photos yet."
        default:
            "Spot the copies, keep the best one, and get the space back."
        }
    }
}
