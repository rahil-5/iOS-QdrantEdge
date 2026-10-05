import Foundation
import SQLite3

/// Persists fingerprints so a rescan only pays for what changed.
///
/// The first scan of a large library is genuinely expensive — every asset must be
/// decoded. Every scan after that should not be. Fingerprints are keyed by asset
/// identifier and validated against the asset's modification date, so an edited
/// photo is re-analysed and an untouched one is read straight from disk.
///
/// SQLite rather than a plist or JSON blob because this needs incremental writes:
/// rewriting a 12 MB file after every batch would be slower than the work it saves.
actor FingerprintStore {

    /// Owns the connection so it is closed when the store goes away.
    ///
    /// An actor's `deinit` is nonisolated and may not touch isolated state, so the
    /// handle cannot be closed there. Wrapping it in its own class moves the cleanup
    /// to a deinit that is allowed to run it.
    private final class Connection {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { sqlite3_close(pointer) }
    }

    private var connection: Connection?
    private var database: OpaquePointer? { connection?.pointer }
    private let fileURL: URL

    /// SQLite needs to know whether it may keep a pointer we hand it. `TRANSIENT`
    /// tells it to copy immediately, which is what we want for the temporary buffers
    /// used during binding.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(filename: String = "fingerprints.sqlite") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent(filename)
    }

    // MARK: - Lifecycle

    private func open() throws {
        guard connection == nil else { return }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            fileURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            throw StoreError.cannotOpen(lastMessage(handle))
        }
        connection = Connection(handle)

        // WAL keeps reads fast while a batch of writes is in flight.
        exec("PRAGMA journal_mode = WAL;")
        exec("PRAGMA synchronous = NORMAL;")

        // Version 2 added the shape signature. A row written before it cannot be
        // completed without decoding the image again, so the old table is dropped
        // and the next scan re-analyses the library once.
        if userVersion() < Self.schemaVersion {
            exec("DROP TABLE IF EXISTS fingerprints;")
            exec("PRAGMA user_version = \(Self.schemaVersion);")
        }
        exec("""
            CREATE TABLE IF NOT EXISTS fingerprints (
                asset_id   TEXT PRIMARY KEY,
                stamp      REAL NOT NULL,
                dhash      INTEGER NOT NULL,
                sharpness  REAL NOT NULL,
                exposure   REAL NOT NULL,
                mean_luma  REAL NOT NULL,
                histogram  BLOB NOT NULL,
                keyframes  BLOB NOT NULL,
                shape      BLOB NOT NULL
            );
            """)
    }

    private static let schemaVersion: Int32 = 2

    private func userVersion() -> Int32 {
        guard let database else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    }

    enum StoreError: Error {
        case cannotOpen(String)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let database else { return false }
        return sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    private func lastMessage(_ handle: OpaquePointer?) -> String {
        guard let handle, let message = sqlite3_errmsg(handle) else { return "unknown error" }
        return String(cString: message)
    }

    // MARK: - Reading

    /// Loads every cached fingerprint, keyed by asset identifier.
    ///
    /// Returns an empty dictionary rather than throwing if the cache is unreadable —
    /// a corrupt cache should cost a slow scan, never a failed one.
    func loadAll() -> [String: Fingerprint] {
        do { try open() } catch { return [:] }
        guard let database else { return [:] }

        let sql = """
            SELECT asset_id, stamp, dhash, sharpness, exposure, mean_luma, histogram, keyframes, shape
            FROM fingerprints;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }

        var results: [String: Fingerprint] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0) else { continue }
            let assetID = String(cString: idPointer)

            let bins = readFloats(statement, column: 6)
            guard bins.count == HistogramSignature.binCount else { continue }
            let shape = readHalfFloats(statement, column: 8)
            guard shape.count == ShapeSignature.dimensions else { continue }

            results[assetID] = Fingerprint(
                assetID: assetID,
                dHash: UInt64(bitPattern: sqlite3_column_int64(statement, 2)),
                histogram: HistogramSignature(bins: bins),
                shape: ShapeSignature(components: shape),
                sharpness: Float(sqlite3_column_double(statement, 3)),
                exposure: Float(sqlite3_column_double(statement, 4)),
                meanLuma: Float(sqlite3_column_double(statement, 5)),
                keyframeHashes: readHashes(statement, column: 7),
                stamp: sqlite3_column_double(statement, 1)
            )
        }
        return results
    }

    /// Copies a BLOB into a `[Float]`.
    ///
    /// Goes through `memcpy` rather than reinterpreting the pointer because SQLite
    /// makes no alignment promise about blob storage, and an unaligned `Float` load
    /// is undefined behaviour.
    private func readFloats(_ statement: OpaquePointer?, column: Int32) -> [Float] {
        guard let pointer = sqlite3_column_blob(statement, column) else { return [] }
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        let count = byteCount / MemoryLayout<Float>.size
        guard count > 0 else { return [] }

        var values = [Float](repeating: 0, count: count)
        values.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress else { return }
            memcpy(base, pointer, count * MemoryLayout<Float>.size)
        }
        return values
    }

    private func readHalfFloats(_ statement: OpaquePointer?, column: Int32) -> [Float16] {
        guard let pointer = sqlite3_column_blob(statement, column) else { return [] }
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        let count = byteCount / MemoryLayout<Float16>.size
        guard count > 0 else { return [] }

        var values = [Float16](repeating: 0, count: count)
        values.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress else { return }
            memcpy(base, pointer, count * MemoryLayout<Float16>.size)
        }
        return values
    }

    private func readHashes(_ statement: OpaquePointer?, column: Int32) -> [UInt64] {
        guard let pointer = sqlite3_column_blob(statement, column) else { return [] }
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        let count = byteCount / MemoryLayout<UInt64>.size
        guard count > 0 else { return [] }

        var values = [UInt64](repeating: 0, count: count)
        values.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress else { return }
            memcpy(base, pointer, count * MemoryLayout<UInt64>.size)
        }
        return values
    }

    // MARK: - Writing

    /// Upserts a batch inside a single transaction.
    func save(_ fingerprints: [Fingerprint]) {
        guard !fingerprints.isEmpty else { return }
        do { try open() } catch { return }
        guard let database else { return }

        let sql = """
            INSERT INTO fingerprints
                (asset_id, stamp, dhash, sharpness, exposure, mean_luma, histogram, keyframes, shape)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(asset_id) DO UPDATE SET
                stamp = excluded.stamp,
                dhash = excluded.dhash,
                sharpness = excluded.sharpness,
                exposure = excluded.exposure,
                mean_luma = excluded.mean_luma,
                histogram = excluded.histogram,
                keyframes = excluded.keyframes,
                shape = excluded.shape;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        exec("BEGIN TRANSACTION;")
        for fingerprint in fingerprints {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            sqlite3_bind_text(statement, 1, fingerprint.assetID, -1, Self.transient)
            sqlite3_bind_double(statement, 2, fingerprint.stamp)
            sqlite3_bind_int64(statement, 3, Int64(bitPattern: fingerprint.dHash))
            sqlite3_bind_double(statement, 4, Double(fingerprint.sharpness))
            sqlite3_bind_double(statement, 5, Double(fingerprint.exposure))
            sqlite3_bind_double(statement, 6, Double(fingerprint.meanLuma))

            fingerprint.histogram.bins.withUnsafeBufferPointer { buffer in
                _ = sqlite3_bind_blob(statement, 7, buffer.baseAddress,
                                      Int32(buffer.count * MemoryLayout<Float>.size), Self.transient)
            }
            fingerprint.keyframeHashes.withUnsafeBufferPointer { buffer in
                _ = sqlite3_bind_blob(statement, 8, buffer.baseAddress,
                                      Int32(buffer.count * MemoryLayout<UInt64>.size), Self.transient)
            }
            fingerprint.shape.components.withUnsafeBufferPointer { buffer in
                _ = sqlite3_bind_blob(statement, 9, buffer.baseAddress,
                                      Int32(buffer.count * MemoryLayout<Float16>.size), Self.transient)
            }

            guard sqlite3_step(statement) == SQLITE_DONE else { continue }
        }
        exec("COMMIT;")
    }

    /// Drops cached rows for assets that no longer exist, so the cache cannot grow
    /// without bound as the user deletes photos.
    func prune(_ stale: [String]) {
        guard !stale.isEmpty else { return }
        do { try open() } catch { return }
        guard let database else { return }

        var deleteStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM fingerprints WHERE asset_id = ?;",
                                 -1, &deleteStatement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(deleteStatement) }

        exec("BEGIN TRANSACTION;")
        for assetID in stale {
            sqlite3_reset(deleteStatement)
            sqlite3_clear_bindings(deleteStatement)
            sqlite3_bind_text(deleteStatement, 1, assetID, -1, Self.transient)
            sqlite3_step(deleteStatement)
        }
        exec("COMMIT;")
    }

    /// Removes every cached fingerprint. Exposed in Settings for when the user wants
    /// to force a full re-analysis.
    func clear() {
        do { try open() } catch { return }
        exec("DELETE FROM fingerprints;")
        // Fold the write-ahead log back into the database and truncate it. Without
        // this the rows are gone but the WAL still holds their pages, so the size on
        // disk barely moves and the Settings screen looks like nothing happened.
        exec("PRAGMA wal_checkpoint(TRUNCATE);")
        exec("VACUUM;")
    }

    /// How many assets currently have a stored fingerprint.
    func count() -> Int {
        do { try open() } catch { return 0 }
        guard let database else { return 0 }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM fingerprints;", -1, &statement, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(statement) }

        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }

    /// Size of the cache on disk, for the Settings screen.
    ///
    /// Includes the write-ahead log and shared-memory files. In WAL mode those hold
    /// most of the recently written data — the main file can read as 4 KB while the
    /// sidecar holds 60 KB more — so counting only the main file understates the
    /// real figure, which is exactly the number the user is being shown.
    func diskUsage() -> Int64 {
        [fileURL.path, fileURL.path + "-wal", fileURL.path + "-shm"].reduce(Int64(0)) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return total + ((attributes?[.size] as? Int64) ?? 0)
        }
    }
}
