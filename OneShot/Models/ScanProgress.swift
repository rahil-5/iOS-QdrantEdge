import Foundation

/// Where the scanner is in its pipeline. Each phase reports its own progress so the
/// UI can show something honest rather than one indeterminate spinner.
enum ScanPhase: Sendable, Equatable {
    case idle
    /// Enumerating `PHAsset`s and flattening them into `AssetRecord`s.
    case indexing(done: Int, total: Int)
    /// Decoding thumbnails and computing hashes — the expensive pass.
    case fingerprinting(done: Int, total: Int)
    /// Building the candidate index and testing pairs.
    case comparing(done: Int, total: Int)
    /// Running face detection and picking a keeper per group.
    case scoring(done: Int, total: Int)
    case finished
    case cancelled
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Ready"
        case .indexing: "Reading your library"
        case .fingerprinting: "Analysing photos"
        case .comparing: "Finding matches"
        case .scoring: "Picking the best ones"
        case .finished: "Done"
        case .cancelled: "Cancelled"
        case .failed: "Something went wrong"
        }
    }

    var detail: String {
        switch self {
        case .idle: "Tap Scan to begin."
        case .indexing: "Building an index of everything on this device."
        case .fingerprinting: "Reading colour and detail from each image."
        case .comparing: "Comparing fingerprints to group copies together."
        case .scoring: "Checking sharpness, faces and resolution."
        case .finished: "Review what OneShot found."
        case .cancelled: "No changes were made."
        case .failed(let message): message
        }
    }

    /// 0…1 within the current phase, or nil when the phase has no measurable work.
    var fraction: Double? {
        switch self {
        case .indexing(let done, let total),
             .fingerprinting(let done, let total),
             .comparing(let done, let total),
             .scoring(let done, let total):
            guard total > 0 else { return nil }
            return min(1, Double(done) / Double(total))
        case .finished: return 1
        default: return nil
        }
    }

    /// Position of this phase in the overall pipeline, used for the combined bar.
    var pipelinePosition: (index: Int, count: Int)? {
        let count = 4
        switch self {
        case .indexing: return (0, count)
        case .fingerprinting: return (1, count)
        case .comparing: return (2, count)
        case .scoring: return (3, count)
        default: return nil
        }
    }

    /// The four phases, in the order the user sees them happen.
    static let stepTitles = [
        "Reading your library",
        "Analysing photos",
        "Finding matches",
        "Picking the best ones"
    ]

    /// Progress of one named step, 0…1.
    ///
    /// Steps already passed read 1, the step in flight reads its own fraction, and
    /// steps still to come read 0 — so each fills from empty to full in turn rather
    /// than every stage sharing a single bar. One bar across four phases of very
    /// different lengths said nothing about how far along the current step was.
    func progress(ofStep step: Int) -> Double {
        if self == .finished { return 1 }
        guard let (index, _) = pipelinePosition else { return 0 }
        if step < index { return 1 }
        if step > index { return 0 }
        return fraction ?? 0
    }

    /// True once this step has begun, so completed and pending steps can be styled
    /// differently from the one actually running.
    func hasReached(step: Int) -> Bool {
        if self == .finished { return true }
        guard let (index, _) = pipelinePosition else { return false }
        return step <= index
    }

    var isRunning: Bool {
        switch self {
        case .indexing, .fingerprinting, .comparing, .scoring: true
        default: false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .finished, .cancelled, .failed: true
        default: false
        }
    }
}
