import CryptoKit
import Foundation
import GRDB
import SQLite3

/// The metadata of the vault items. SQLite keeps the database in memory while the vault is open, and each write saves the
/// whole database to one sealed file. See `VaultCrypto` for the file format.
final class VaultDatabase: Sendable {
    private let url: URL
    /// The saves need the master key. `Session.lock` closes the database.
    private let master: SymmetricKey
    private let queue: DatabaseQueue

    /// Opens the database file, or a new database when the file does not exist. Throws when the file does not open.
    /// Does not save, so the first write saves the schema.
    init(url: URL, key: SymmetricKey) throws {
        self.url = url
        master = key
        var configuration = Configuration()
        // Without it, SQLite can write a plaintext temporary file to tmp/.
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA temp_store = MEMORY") }
        queue = try DatabaseQueue(configuration: configuration)
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try VaultCrypto.openDatabase(url, master: key)
            try queue.inDatabase { db in
                // SQLite frees the buffer when the database closes, so the buffer must come from sqlite3_malloc64.
                guard let buffer = sqlite3_malloc64(UInt64(bytes.count))?.assumingMemoryBound(to: UInt8.self) else {
                    throw DatabaseError(resultCode: .SQLITE_NOMEM)
                }
                bytes.copyBytes(to: buffer, count: bytes.count)
                let code = sqlite3_deserialize(db.sqliteConnection, "main", buffer, Int64(bytes.count), Int64(bytes.count),
                                               UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE))
                guard code == SQLITE_OK else { throw DatabaseError(resultCode: ResultCode(rawValue: code)) }
                db.clearSchemaCache()
            }
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createItem") { db in
            try db.execute(sql: """
            CREATE TABLE item (
              id TEXT PRIMARY KEY NOT NULL, -- A UUID string. The vault file name and the thumbnail file name use it.
              originalFilename TEXT,        -- The file name that the photo picker gives.
              type TEXT NOT NULL,           -- A UTType identifier, for example public.heic.
              created DATETIME,             -- The capture date. NULL when the media has no capture date.
              imported DATETIME NOT NULL    -- The import date.
            )
            """)
        }
        try migrator.migrate(queue)
    }

    func read<T>(_ value: (Database) throws -> T) throws -> T {
        try queue.read(value)
    }

    // ponytail: each save writes the whole file. Move to SQLCipher if the saves become too slow.
    /// Runs `updates` in one transaction and then saves the database file. If the save throws, the change stays in memory.
    func write(_ updates: (Database) throws -> Void) throws {
        // The transaction and the save are in one queue access, so two saves cannot write in the wrong order.
        try queue.inDatabase { db in
            try db.inTransaction { try updates(db); return .commit }
            var size: Int64 = 0
            guard let bytes = sqlite3_serialize(db.sqliteConnection, "main", &size, 0) else { throw DatabaseError(resultCode: .SQLITE_NOMEM) }
            let plaintext = Data(bytes: bytes, count: Int(size))
            sqlite3_free(bytes)
            try VaultCrypto.sealDatabase(plaintext, to: url, master: master)
        }
    }

    /// Waits for a running write. After the close, each access throws.
    func close() throws {
        try queue.close()
    }

    #if DEBUG
    // swiftlint:disable force_try
    static func selfTest() {
        let url = URL.temporaryDirectory.appending(path: "selftest-database")
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let key = SymmetricKey(size: .bits256)
        let insert = "INSERT INTO item (id, originalFilename, type, imported) VALUES (?, ?, 'public.jpeg', CURRENT_TIMESTAMP)"

        // No file: a new database. The write saves it.
        var database = try! VaultDatabase(url: url, key: key)
        try! database.write { try $0.execute(sql: insert, arguments: ["a", "a.jpeg"]) }
        try! database.close()
        assert((try? database.read { _ in }) == nil)
        assert(try! Data(contentsOf: url).prefix(15) != Data("SQLite format 3".utf8))

        // The file loads. A long value adds pages, so the loaded database must grow.
        database = try! VaultDatabase(url: url, key: key)
        assert(try! database.read { try String.fetchAll($0, sql: "SELECT id FROM item") } == ["a"])
        try! database.write { try $0.execute(sql: insert, arguments: ["b", String(repeating: "b", count: 10_000)]) }
        try! database.close()
        database = try! VaultDatabase(url: url, key: key)
        assert(try! database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM item") } == 2)
        try! database.close()

        assert((try? VaultDatabase(url: url, key: SymmetricKey(size: .bits256))) == nil)
    }
    // swiftlint:enable force_try
    #endif
}
