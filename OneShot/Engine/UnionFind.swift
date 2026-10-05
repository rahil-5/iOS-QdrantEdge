import Foundation

/// Disjoint-set union with path compression and union by rank.
///
/// The comparison phase produces *pairs*, but the user thinks in *groups*: five
/// shots of the same subject should be one group of five, not ten disconnected
/// pairs. Union-find merges pairs into groups in near-constant time per operation,
/// and it does so transitively — if A matches B and B matches C, all three end up
/// together even when A and C were never directly compared.
struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ element: Int) -> Int {
        var root = element
        while parent[root] != root {
            root = parent[root]
        }
        // Path compression: point everything on the way up straight at the root.
        var current = element
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ first: Int, _ second: Int) {
        let firstRoot = find(first)
        let secondRoot = find(second)
        guard firstRoot != secondRoot else { return }

        if rank[firstRoot] < rank[secondRoot] {
            parent[firstRoot] = secondRoot
        } else if rank[firstRoot] > rank[secondRoot] {
            parent[secondRoot] = firstRoot
        } else {
            parent[secondRoot] = firstRoot
            rank[firstRoot] += 1
        }
    }

    /// Collects every set with more than one member, keyed by root.
    mutating func groups() -> [[Int]] {
        var buckets: [Int: [Int]] = [:]
        for element in 0..<parent.count {
            buckets[find(element), default: []].append(element)
        }
        return buckets.values.filter { $0.count > 1 }
    }
}
