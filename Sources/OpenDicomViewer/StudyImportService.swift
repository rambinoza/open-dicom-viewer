// StudyImportService.swift — OpenDicomViewer
//
// Import pipeline for LibraryView.swift's "browse/delete/upload from folder or ZIP" feature.
// Handles copying an externally-picked folder (or extracting a ZIP archive) into this app's own
// managed storage, extracting summary metadata for the study database, and packaging files back
// up as a single ZIP for sharing/emailing.
//
// DESIGN NOTE -- why Library entries only ever point inside this app's own Documents directory:
// a folder picked via `.fileImporter` (or macOS's NSOpenPanel) can be ANYWHERE on disk, often
// outside the app's sandbox, reachable only via a security-scoped bookmark that is only
// guaranteed valid for the duration of that one picker session. A "browse your library any time"
// screen backed by a database needs paths that stay valid indefinitely across app relaunches --
// so importing (as opposed to the existing lightweight SidebarView "Open" button, which just
// views a folder in place without copying or registering it anywhere) always COPIES the source
// into Documents/ImportedStudies/<uuid>/ first, and only registers *that* copy in the database.
// This does mean import uses roughly 2x the disk space of the original source while the source
// still exists elsewhere -- an accepted tradeoff for reliability over storage efficiency.
//
// "Upload from media" (the user's own phrasing) needs no separate code path: on iOS, external
// media (USB-C drives, SD card readers, network shares) already surface as ordinary browsable
// folders through the Files app / `.fileImporter`, so `importFolder(from:)` below already covers
// it -- there is nothing media-specific to special-case.
//
// IMPORTANT CAVEAT: not compiler-verified, same as every other Swift file in this port. The ZIP
// extraction/creation calls (`FileManager.unzipItem`/`zipItem`, from the new ZIPFoundation SPM
// dependency added in Package.swift) were checked against ZIPFoundation's actual published API
// documentation (exact signatures fetched and confirmed, not guessed from memory) before being
// used here, which is a stronger basis than the rest of this file's logic, but still not the
// same as a real build.
import Foundation
import ZIPFoundation

enum StudyImportError: LocalizedError {
    case extractionFailed(String)
    case copyFailed(String)
    case noDICOMFilesFound

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let message):
            return "Could not extract the archive: \(message)"
        case .copyFailed(let message):
            return "Could not copy the folder: \(message)"
        case .noDICOMFilesFound:
            return "No readable DICOM files were found."
        }
    }
}

enum StudyImportSource: String {
    case local
    case pacs
}

enum StudyImportService {

    // MARK: - Managed storage

    /// Root directory for all library-managed (imported or PACS-retrieved) study folders.
    static func importedStudiesRoot() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let root = documents.appendingPathComponent("ImportedStudies", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Resolves a StudyRecord's stored relative `folderPath` back to an absolute URL under this
    /// app's CURRENT Documents directory. Only the relative path is ever persisted (see
    /// StudyDatabase.swift) since the sandbox container's absolute path is not guaranteed stable
    /// across relaunches.
    static func absoluteURL(for record: StudyRecord) throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return documents.appendingPathComponent(record.folderPath, isDirectory: true)
    }

    // MARK: - Import

    /// Copies `sourceFolder` (an arbitrary, possibly security-scoped folder picked via
    /// `.fileImporter`) into this app's own managed storage, then registers it in the study
    /// database. Returns the new managed folder URL -- pass this to `DICOMModel.load(url:)` to
    /// open it immediately after import.
    @discardableResult
    static func importFolder(from sourceFolder: URL) throws -> URL {
        let root = try importedStudiesRoot()
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)

        let accessed = sourceFolder.startAccessingSecurityScopedResource()
        defer { if accessed { sourceFolder.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: sourceFolder, to: destination)
        } catch {
            throw StudyImportError.copyFailed(error.localizedDescription)
        }

        try registerFolder(destination, source: .local)
        return destination
    }

    /// Extracts `zipURL` (a .zip archive picked via `.fileImporter`) into this app's own managed
    /// storage, then registers it. Returns the extracted folder URL.
    @discardableResult
    static func importZip(from zipURL: URL) throws -> URL {
        let root = try importedStudiesRoot()
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let accessed = zipURL.startAccessingSecurityScopedResource()
        defer { if accessed { zipURL.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager().unzipItem(at: zipURL, to: destination)
        } catch {
            throw StudyImportError.extractionFailed(error.localizedDescription)
        }

        try registerFolder(destination, source: .local)
        return destination
    }

    /// Extracts summary metadata (patient/study fields) from the first parsable DICOM file found
    /// (recursively) under `folder`, and upserts a StudyRecord into StudyDatabase.shared.
    /// `folder` MUST already be inside this app's own managed storage (see the design note at
    /// the top of this file). If `folder` contains files belonging to MORE than one study (e.g.
    /// a batch export), only the FIRST study found is used for the database row -- the folder
    /// still opens correctly in the viewer either way (DICOMModel.load(url:) already handles
    /// multi-study folders), but the Library list will show one entry, not several. A known,
    /// documented simplification rather than a silent bug.
    static func registerFolder(_ folder: URL, source: StudyImportSource) throws {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let relativePath = relativePath(of: folder, from: documents)

        var dicomFileURLs: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory { continue }
                if fileURL.lastPathComponent == "DICOMDIR" { continue }
                let ext = fileURL.pathExtension.lowercased()
                if ext != "dcm" && ext != "" { continue }
                dicomFileURLs.append(fileURL)
            }
        }
        guard !dicomFileURLs.isEmpty else { throw StudyImportError.noDICOMFilesFound }

        var record: StudyRecord?
        for fileURL in dicomFileURLs {
            if let parsed = summarize(fileURL: fileURL, relativeFolderPath: relativePath,
                                       source: source, instanceCount: dicomFileURLs.count) {
                record = parsed
                break
            }
        }
        guard let record else { throw StudyImportError.noDICOMFilesFound }
        StudyDatabase.shared.upsert(record)
    }

    /// Lightweight tag read (first 64KB of one file only) mirroring the approach
    /// DICOMModel.swift's private `quickParse(_:)` already uses via SimpleDicomParser -- not
    /// reused directly since `quickParse` is `private` to DICOMModel.swift and only reads the
    /// tags DICOMModel itself needs (series/geometry), not PatientName/StudyDate/
    /// AccessionNumber/StudyDescription, which is what a study-level summary needs instead.
    private static func summarize(fileURL: URL, relativeFolderPath: String,
                                   source: StudyImportSource, instanceCount: Int) -> StudyRecord? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65536), !data.isEmpty else { return nil }

        let parser = SimpleDicomParser(data: data)
        guard (try? parser.parse(stopAtPixelData: true)) != nil else { return nil }

        func value(_ group: UInt16, _ element: UInt16) -> String {
            (parser.findTagRaw(DicomTag(group: group, element: element)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let studyUID = value(0x0020, 0x000D) // StudyInstanceUID
        guard !studyUID.isEmpty else { return nil }

        return StudyRecord(
            studyInstanceUID: studyUID,
            patientName: value(0x0010, 0x0010),      // PatientName
            patientID: value(0x0010, 0x0020),        // PatientID
            studyDate: value(0x0008, 0x0020),        // StudyDate
            studyDescription: value(0x0008, 0x1030), // StudyDescription
            modalities: value(0x0008, 0x0060),       // Modality
            accessionNumber: value(0x0008, 0x0050),  // AccessionNumber
            folderPath: relativeFolderPath,
            source: source.rawValue,
            numberOfInstances: instanceCount,
            dateAdded: Date().timeIntervalSince1970
        )
    }

    private static func relativePath(of url: URL, from base: URL) -> String {
        let full = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        guard full.hasPrefix(basePath) else { return full }
        return String(full.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Delete

    /// Deletes a study's managed folder from disk and removes its database row. No-op (beyond
    /// the database delete) if the folder is already missing.
    static func deleteStudy(_ record: StudyRecord) {
        if let url = try? absoluteURL(for: record) {
            try? FileManager.default.removeItem(at: url)
        }
        StudyDatabase.shared.delete(studyInstanceUID: record.studyInstanceUID)
    }

    // MARK: - Sharing

    /// Zips every file under `folder` into a single archive under a fresh temporary directory,
    /// for sharing/emailing as one attachment. The caller is responsible for cleaning up the
    /// returned URL's containing temp directory when convenient -- not done automatically here,
    /// since there's no single reliable "share sheet finished" callback across both of
    /// `ShareLink`'s platforms; stale entries are plain temp files the OS may reclaim on its own.
    static func zipForSharing(folder: URL, name: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let destination = tempDir.appendingPathComponent("\(sanitizedFilename(name)).zip")
        try FileManager().zipItem(at: folder, to: destination, shouldKeepParent: false)
        return destination
    }

    /// Zips an explicit list of files (e.g. "just the images in this one series", not a whole
    /// study folder) into a single archive for sharing. Stages the files into a flat temporary
    /// folder first (by filename) rather than driving ZIPFoundation's lower-level Archive API
    /// entry-by-entry -- simpler and reuses the same folder-zip path as `zipForSharing(folder:)`.
    static func zipForSharing(files: [URL], name: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Share-\(UUID().uuidString)", isDirectory: true)
        let stagingDir = tempDir.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        for file in files {
            let target = stagingDir.appendingPathComponent(file.lastPathComponent)
            try? FileManager.default.copyItem(at: file, to: target)
        }
        let destination = tempDir.appendingPathComponent("\(sanitizedFilename(name)).zip")
        try FileManager().zipItem(at: stagingDir, to: destination, shouldKeepParent: false)
        return destination
    }

    private static func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "Export" : cleaned
    }
}
