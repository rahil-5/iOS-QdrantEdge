import Foundation

/// Breaks the connected components produced by union-find into tight groups.
///
/// Union-find answers "is there a *path* of similarity between these two photos",
/// which is not the question the user is asking. If A resembles B, B resembles C and
/// C resembles D, union-find puts all four in one group — even when A and D have
/// nothing in common. Across a real library those chains run for hundreds of photos,
/// and the first group swallows most of the library.
///
/// This refines each component by star clustering: repeatedly take the
/// best-connected photo still unassigned, and form a group from it and the photos
/// that matched *it directly*. Every member of the resulting group is a confirmed
/// match against the same anchor, so there is no path-of-similarity chaining and the
/// group means what the user thinks it means — "these are all copies of this one".
enum ClusterRefiner {

    struct Edge: Sendable {
        let first: Int
        let second: Int
        let confidence: Double
    }

    /// - Parameters:
    ///   - components: connected components from union-find.
    ///   - edges: the confirmed pairs those components were built from.
    ///   - maxGroupSize: safety valve. A group larger than this is not reviewable in
    ///     any useful way, so the least similar members are left for the next anchor
    ///     rather than being piled onto this one.
    static func refine(
        components: [[Int]],
        edges: [Edge],
        maxGroupSize: Int = Tuning.maxGroupSize
    ) -> [[Int]] {
        guard !components.isEmpty else { return [] }

        // Adjacency across the whole graph, with each edge's confidence so a group
        // can prefer its strongest matches when it hits the size cap.
        var adjacency: [Int: [(neighbour: Int, confidence: Double)]] = [:]
        adjacency.reserveCapacity(edges.count * 2)
        for edge in edges {
            adjacency[edge.first, default: []].append((edge.second, edge.confidence))
            adjacency[edge.second, default: []].append((edge.first, edge.confidence))
        }

        var refined: [[Int]] = []

        for component in components {
            // A pair cannot chain, so it is already its own answer.
            guard component.count > 2 else {
                if component.count == 2 { refined.append(component) }
                continue
            }

            var unassigned = Set(component)

            while unassigned.count >= 2 {
                // The best-connected photo is the most representative one: it is the
                // frame the others are copies of, rather than an outlier that
                // happened to bridge two unrelated runs.
                guard let anchor = unassigned.max(by: { lhs, rhs in
                    degree(of: lhs, in: adjacency, within: unassigned)
                        < degree(of: rhs, in: adjacency, within: unassigned)
                }) else { break }

                var neighbours = (adjacency[anchor] ?? [])
                    .filter { unassigned.contains($0.neighbour) && $0.neighbour != anchor }
                    .sorted { $0.confidence > $1.confidence }

                // An anchor with nothing left to match is finished — drop it and let
                // the next candidate take a turn, or the loop would never terminate.
                guard !neighbours.isEmpty else {
                    unassigned.remove(anchor)
                    continue
                }

                if neighbours.count > maxGroupSize - 1 {
                    neighbours = Array(neighbours.prefix(maxGroupSize - 1))
                }

                var group = [anchor]
                group.append(contentsOf: neighbours.map(\.neighbour))

                for member in group { unassigned.remove(member) }
                refined.append(group)
            }
        }

        return refined
    }

    /// How many still-unassigned photos this one directly matched.
    private static func degree(
        of node: Int,
        in adjacency: [Int: [(neighbour: Int, confidence: Double)]],
        within unassigned: Set<Int>
    ) -> Int {
        (adjacency[node] ?? []).reduce(0) { total, entry in
            total + (unassigned.contains(entry.neighbour) ? 1 : 0)
        }
    }
}
