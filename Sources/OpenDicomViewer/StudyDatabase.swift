// StudyDatabase.swift — OpenDicomViewer
//
// A small local SQLite-backed index of DICOM studies this app has imported (local folder/ZIP)
// or retrieved from PACS (see PACSBrowserView.swift), added so LibraryView.swift can offer a
// "browse all studies / delete / send / share" screen without re-scanning the whole filesystem
// on every launch. Uses Apple's system libsqlite3 (`import SQLite3`, `.linkedLibrary("sqlite3")`
// in Package.swift) directly via its C API, rather than a third-party wrapper or Core Data --
// Core Data would need a hand-authored `.xcdatamodeld` (normally built with Xcode's visual model
// editor, brittle to hand-write blind), and a raw SQL schema this small doesn't need an ORM.
//
// IMPORTANT CAVEAT: like every other Swift file in this port, this has NOT been compiler-
// verified -- no Swift toolchain has ever been available in the sandbox that wrote it. The
// SQLite C API bridging below (particularly the `SQLITE_TRANSIENT` binding-destructor trick) is
// extremely well-established, widely-documented Swift/SQLite boilerplate, unlike the rest of
// this file's logic, which is original.
import Foundation
import SQLite3

/// One row in the study library. `folderPath` is stored RELATIVE to the app's Documents
/// directory (not an absolute URL) so it stays valid across app relaunches even if the sandbox
/// container's absolute path changes (which it can, e.g. after certain reinstalls) -- resolve it
/// back to an absolute URL via `StudyImportService.absoluteURL(for:)`.
struct StudyRecord: Identifiable, Hashable {
    let studyInstanceUID: String
    var patientName: String
    var patientID: String
    var studyDate: String
    var studyDescription: String
    var modalities: String
    var accessionNumber: String
    var folderPath: String
    var source: String // "local" or "pacs" -- see StudyImportSource in StudyImportService.swift
    var numberOfInstances: Int
    var dateAdded: Double // Date().timeIntervalSince1970

    var id: String { studyInstanceUID }

    /// Best-effort "YYYY-MM-DD" formatting of the raw DICOM DA (e.g. "20240115"), matching
    /// PACSStudy.formattedStudyDate in PACSService.swift.
    var formattedStudyDate: String {
        guard studyDate.count == 8 else {
            return studyDate.isEmpty ? "Unknown Date" : studyDate
        }
        let y = studyDate.prefix(4)
        let m = studyDate.dropFirst(4).prefix(2)
        let d = studyDate.dropFirst(6).prefix(2)
        return "\(y)-\(m)-\(d)"
    }
}

/// SQLite's `sqlite3_bind_text`/`sqlite3_bind_blob` need a "destructor" telling SQLite whether
/// it can hold onto the pointer past the call (SQLITE_STATIC) or must copy the bytes immediately
/// (SQLITE_TRANSIENT). The C header defines SQLITE_TRANSIENT as `((sqlite3_destructor_type)-1)`,
/// a macro that Swift's ClangImporter cannot import as a usable symbol -- this `unsafeBitCast`
/// reconstruction of that same sentinel value is the standard, widely-documented Swift/SQLite
/// workaround (present in effectively every Swift+SQLite3 codebase), not something specific to
/// this file.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class StudyDatabase {
    static let shared = StudyDatabase()

    private var db: OpaquePointer?
    /// Serializes all access -- SQLite's default (non-multithread-configured) connection isn't
    /// safe to call concurrently from multiple threads, and this class is used from both the
    /// main actor (LibraryView) and background import/PACS-retrieve code paths.
    private let queue = DispatchQueue(label: "com.opendicomviewer.studydb")

    private init() {
        queue.sync {
            openDatabase()
            createTableIfNeeded()
        }
    }

    private func databaseURL() -> URL {
        let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return (documents ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("StudyLibrary.sqlite")
    }

    private func openDatabase() {
        let path = databaseURL().path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            let message = db != nil ? String(cString: sqlite3_errmsg(db)) : "unknown error"
            NSLog("[StudyDatabase] Failed to open database at \(path): \(message)")
            db = nil
        }
    }

    private func createTableIfNeeded() {
        guard let db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS studies (
            study_instance_uid TEXT PRIMARY KEY,
            patient_name TEXT NOT NULL DEFAULT '',
            patient_id TEXT NOT NULL DEFAULT '',
            study_date TEXT NOT NULL DEFAULT '',
            study_description TEXT NOT NULL DEFAULT '',
            modalities TEXT NOT NULL DEFAULT '',
            accession_number TEXT NOT NULL DEFAULT '',
            folder_path TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'local',
            number_of_instances INTEGER NOT NULL DEFAULT 0,
            date_added REAL NOT NULL DEFAULT 0
        );
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("[StudyDatabase] Failed to create table: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// Inserts a new row, or replaces every field of an existing row with the same
    /// `studyInstanceUID` (re-importing/re-retrieving the same study updates it in place rather
    /// than duplicating).
    func upsert(_ record: StudyRecord) {
        queue.sync {
            guard let db else { return }
            let sql = """
            INSERT INTO studies (
                study_instance_uid, patient_name, patient_id, study_date, study_description,
                modalities, accession_number, folder_path, source, number_of_instances, date_added
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(study_instance_uid) DO UPDATE SET
                patient_name = excluded.patient_name,
                patient_id = excluded.patient_id,
                study_date = excluded.study_date,
                study_description = excluded.study_description,
                modalities = excluded.modalities,
                accession_number = excluded.accession_number,
                folder_path = excluded.folder_path,
                source = excluded.source,
                number_of_instances = excluded.number_of_instances,
                date_added = excluded.date_added;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                NSLog("[StudyDatabase] upsert prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, record.studyInstanceUID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, record.patientName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, record.patientID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, record.studyDate, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, record.studyDescription, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, record.modalities, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, record.accessionNumber, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, record.folderPath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 9, record.source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 10, Int32(record.numberOfInstances))
            sqlite3_bind_double(stmt, 11, record.dateAdded)

            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("[StudyDatabase] upsert step failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    /// All studies, most-recently-added first.
    func allStudies() -> [StudyRecord] {
        queue.sync {
            guard let db else { return [] }
            let sql = """
            SELECT study_instance_uid, patient_name, patient_id, study_date, study_description,
                   modalities, accession_number, folder_path, source, number_of_instances, date_added
            FROM studies ORDER BY date_added DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                NSLog("[StudyDatabase] allStudies prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return []
            }
            defer { sqlite3_finalize(stmt) }

            var results: [StudyRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(StudyRecord(
                    studyInstanceUID: columnText(stmt, 0),
                    patientName: columnText(stmt, 1),
                    patientID: columnText(stmt, 2),
                    studyDate: columnText(stmt, 3),
                    studyDescription: columnText(stmt, 4),
                    modalities: columnText(stmt, 5),
                    accessionNumber: columnText(stmt, 6),
                    folderPath: columnText(stmt, 7),
                    source: columnText(stmt, 8),
                    numberOfInstances: Int(sqlite3_column_int(stmt, 9)),
                    dateAdded: sqlite3_column_double(stmt, 10)
                ))
            }
            return results
        }
    }

    func delete(studyInstanceUID: String) {
        queue.sync {
            guard let db else { return }
            let sql = "DELETE FROM studies WHERE study_instance_uid = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                NSLog("[StudyDatabase] delete prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, studyInstanceUID, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("[StudyDatabase] delete step failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }
}
