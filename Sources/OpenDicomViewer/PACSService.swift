// PACSService.swift — OpenDicomViewer
//
// Swift-facing PACS networking layer, added as part of the iOS port's networking task. Wraps
// DCMTKWrapper's Objective-C++ PACSClient (see PACSHelper.h/.mm, pacs_core.hpp/.cpp in
// Sources/DCMTKWrapper) with async/await and Swift-native value types, so PACSBrowserView.swift
// and DICOMModel never touch the ObjC bridge directly.
//
// IMPORTANT CAVEAT: unlike pacs_core.cpp (syntax-checked against the real DCMTK headers with a
// real C++ compiler in this sandbox -- see pacs_core.hpp), this file has NOT been compiler-
// verified at all -- there has never been a Swift toolchain available in the sandbox that wrote
// it, for this file or any other .swift file in this whole iOS port. Treat the first real
// `swift build` on this file (and the first real-PACS test of the features it exposes) as the
// actual verification step, same as every other Swift file added or changed in this port.
import Foundation
import DCMTKWrapper

/// User-configured PACS connection settings. `Codable` for UserDefaults persistence via
/// PACSSettingsStore.
struct PACSNode: Codable, Equatable {
    var host: String = ""
    var port: Int = 104
    /// This app's own AE title, as it will identify itself to the PACS.
    var callingAETitle: String = "OPENDICOMVWR"
    /// The PACS's AE title.
    var calledAETitle: String = "ANY-SCP"
}

/// Swift-native mirror of PACSStudyResult (the ObjC C-FIND result row), so the rest of the app
/// never needs to import DCMTKWrapper directly. Conforms to Identifiable/Hashable for direct use
/// in a SwiftUI List.
struct PACSStudy: Identifiable, Hashable {
    let patientName: String
    let patientID: String
    let studyInstanceUID: String
    let studyDate: String
    let studyDescription: String
    let modalitiesInStudy: String
    let accessionNumber: String
    let numberOfInstances: Int

    var id: String { studyInstanceUID }

    /// Best-effort "YYYY-MM-DD" formatting of the raw DICOM DA (e.g. "20240115"). Falls back to
    /// the raw value (or a placeholder) if it isn't exactly 8 digits -- some SCPs return partial
    /// or empty dates, which shouldn't crash formatting, just display as-is.
    var formattedStudyDate: String {
        guard studyDate.count == 8 else {
            return studyDate.isEmpty ? "Unknown Date" : studyDate
        }
        let y = studyDate.prefix(4)
        let m = studyDate.dropFirst(4).prefix(2)
        let d = studyDate.dropFirst(6).prefix(2)
        return "\(y)-\(m)-\(d)"
    }

    init(_ result: PACSStudyResult) {
        patientName = result.patientName
        patientID = result.patientID
        studyInstanceUID = result.studyInstanceUID
        studyDate = result.studyDate
        studyDescription = result.studyDescription
        modalitiesInStudy = result.modalitiesInStudy
        accessionNumber = result.accessionNumber
        numberOfInstances = result.numberOfInstances
    }
}

enum PACSError: LocalizedError {
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let message):
            return message
        }
    }
}

/// Snapshot of C-GET sub-operation progress, published for direct SwiftUI binding.
struct PACSRetrieveProgress: Equatable {
    var completed: Int = 0
    var remaining: Int = 0
    var failed: Int = 0
}

/// Thin async/await-friendly wrapper over PACSClient. PACSClient's own methods are synchronous,
/// blocking (real network I/O), single-operation-at-a-time by contract (see PACSHelper.h) -- this
/// class dispatches each call onto a private background queue and bridges the result back with
/// a checked continuation, so callers never block the calling (typically main) actor.
@MainActor
final class PACSService: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var lastRetrieveProgress = PACSRetrieveProgress()

    private let queue = DispatchQueue(label: "com.opendicomviewer.pacs", qos: .userInitiated)

    func echo(node: PACSNode) async throws {
        let client = makeClient(node)
        isBusy = true
        defer { isBusy = false }
        try await run {
            guard client.echo() else {
                throw PACSError.operationFailed(client.lastError ?? "C-ECHO failed for an unknown reason")
            }
        }
    }

    func findStudies(node: PACSNode,
                      patientName: String,
                      patientID: String,
                      studyDate: String,
                      accessionNumber: String) async throws -> [PACSStudy] {
        let client = makeClient(node)
        isBusy = true
        defer { isBusy = false }
        return try await run {
            guard let results = client.findStudies(
                patientName: patientName.isEmpty ? nil : patientName,
                patientID: patientID.isEmpty ? nil : patientID,
                studyDate: studyDate.isEmpty ? nil : studyDate,
                accessionNumber: accessionNumber.isEmpty ? nil : accessionNumber
            ) else {
                throw PACSError.operationFailed(client.lastError ?? "C-FIND failed for an unknown reason")
            }
            return results.map(PACSStudy.init)
        }
    }

    /// Retrieves every instance of `studyInstanceUID` into `destinationDirectory` (created if
    /// needed by the caller -- this method does not create it). Publishes `lastRetrieveProgress`
    /// updates as sub-operations complete. Returns the final (completed, failed) counts.
    func retrieveStudy(node: PACSNode,
                        studyInstanceUID: String,
                        destinationDirectory: URL) async throws -> (completed: Int, failed: Int) {
        let client = makeClient(node)
        isBusy = true
        lastRetrieveProgress = PACSRetrieveProgress()
        defer { isBusy = false }

        return try await run {
            var completed: Int = 0
            var failed: Int = 0
            let ok = client.retrieveStudy(
                instanceUID: studyInstanceUID,
                destinationDirectory: destinationDirectory.path,
                completedCount: &completed,
                failedCount: &failed
            ) { [weak self] completedSoFar, remaining, failedSoFar in
                // Documented to fire on an arbitrary background thread (see PACSHelper.h) --
                // hop to the main actor before touching published state.
                guard let self else { return }
                Task { @MainActor in
                    self.lastRetrieveProgress = PACSRetrieveProgress(
                        completed: completedSoFar, remaining: remaining, failed: failedSoFar
                    )
                }
            }
            guard ok else {
                throw PACSError.operationFailed(client.lastError ?? "C-GET failed for an unknown reason")
            }
            return (completed, failed)
        }
    }

    /// Sends each local file in `filePaths` via C-STORE. Returns the number successfully stored.
    func storeFiles(node: PACSNode, filePaths: [String]) async throws -> Int {
        let client = makeClient(node)
        isBusy = true
        defer { isBusy = false }
        return try await run {
            client.storeFiles(filePaths, progressHandler: nil)
        }
    }

    private func makeClient(_ node: PACSNode) -> PACSClient {
        PACSClient(host: node.host, port: node.port,
                   callingAETitle: node.callingAETitle, calledAETitle: node.calledAETitle)
    }

    /// Runs a blocking `body` on a background queue and bridges its return value/throw back to
    /// the calling async context. Marked `nonisolated` (rather than inheriting this class's
    /// @MainActor isolation) since it touches no actor-isolated state itself -- only the plain
    /// local values each call site closes over (a freshly-created `client`, local `var`s).
    nonisolated private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Persists the single PACS node configuration this app remembers between launches. A real
/// multi-node "address book" (add/remove/rename several PACS servers) would be a natural
/// follow-up but is out of scope here -- flagged rather than silently simplified away.
enum PACSSettingsStore {
    private static let key = "PACSNode"

    static func load() -> PACSNode {
        guard let data = UserDefaults.standard.data(forKey: key),
              let node = try? JSONDecoder().decode(PACSNode.self, from: data) else {
            return PACSNode()
        }
        return node
    }

    static func save(_ node: PACSNode) {
        guard let data = try? JSONEncoder().encode(node) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
