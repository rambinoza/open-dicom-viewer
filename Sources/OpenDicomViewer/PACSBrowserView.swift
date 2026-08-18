// PACSBrowserView.swift — OpenDicomViewer
//
// SwiftUI PACS query/retrieve sheet, added as part of the iOS port's networking task. Presented
// from SidebarView's toolbar (ContentView.swift) on both platforms -- this view is intentionally
// plain SwiftUI (Form/List/TextField/Button) with no AppKit/UIKit dependency at all, so unlike
// most of this port's view-layer work, it needs no #if os(...) platform gating anywhere in this
// file.
//
// Flow: configure/edit the PACS node (host/port/AE titles, persisted via PACSSettingsStore) ->
// C-ECHO to verify connectivity -> STUDY-level C-FIND search -> pick a result -> C-GET retrieve
// into a per-study folder under this app's Documents directory -> hand that folder to
// DICOMModel.load(url:) to open it, reusing the exact same folder-loading path local files
// already use.
//
// IMPORTANT CAVEAT: same as PACSService.swift -- this file has not been compiler-verified (no
// Swift toolchain in the sandbox that wrote it). See docs/iOS-Build.md for the full picture of
// what has and hasn't been build/runtime-verified in this port.
import SwiftUI

struct PACSBrowserView: View {
    @ObservedObject var model: DICOMModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var pacsService = PACSService()

    @State private var node: PACSNode = PACSSettingsStore.load()

    @State private var patientName = ""
    @State private var patientID = ""
    @State private var studyDate = ""
    @State private var accessionNumber = ""

    @State private var results: [PACSStudy] = []
    @State private var statusMessage: String = ""
    @State private var errorMessage: String?
    @State private var retrievingStudyUID: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("PACS Server") {
                    TextField("Host or IP Address", text: $node.host)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    TextField("Port", value: $node.port, format: .number.grouping(.never))
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    TextField("Calling AE Title (this app)", text: $node.callingAETitle)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .autocorrectionDisabled()
                    TextField("Called AE Title (PACS)", text: $node.calledAETitle)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .autocorrectionDisabled()

                    Button {
                        testConnection()
                    } label: {
                        if pacsService.isBusy {
                            ProgressView()
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(pacsService.isBusy || node.host.isEmpty)
                }

                Section("Search") {
                    TextField("Patient Name", text: $patientName)
                        .autocorrectionDisabled()
                    TextField("Patient ID", text: $patientID)
                        .autocorrectionDisabled()
                    TextField("Study Date (YYYYMMDD or range)", text: $studyDate)
                        .autocorrectionDisabled()
                    TextField("Accession Number", text: $accessionNumber)
                        .autocorrectionDisabled()

                    Button {
                        search()
                    } label: {
                        if pacsService.isBusy && retrievingStudyUID == nil {
                            ProgressView()
                        } else {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                    }
                    .disabled(pacsService.isBusy || node.host.isEmpty)
                }

                if !statusMessage.isEmpty {
                    Section {
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                if !results.isEmpty {
                    Section("Results (\(results.count))") {
                        ForEach(results) { study in
                            studyRow(study)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("PACS Query/Retrieve")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onDisappear {
                PACSSettingsStore.save(node)
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    @ViewBuilder
    private func studyRow(_ study: PACSStudy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(study.patientName.isEmpty ? "Unnamed Patient" : study.patientName)
                    .font(.headline)
                Spacer()
                Text(study.formattedStudyDate)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !study.studyDescription.isEmpty {
                Text(study.studyDescription)
                    .font(.subheadline)
            }
            HStack(spacing: 12) {
                if !study.modalitiesInStudy.isEmpty {
                    Text(study.modalitiesInStudy)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
                if study.numberOfInstances >= 0 {
                    Text("\(study.numberOfInstances) images")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !study.accessionNumber.isEmpty {
                    Text("Acc: \(study.accessionNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                retrieveButton(study)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func retrieveButton(_ study: PACSStudy) -> some View {
        if retrievingStudyUID == study.studyInstanceUID {
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView()
                let p = pacsService.lastRetrieveProgress
                if p.completed + p.remaining > 0 {
                    Text("\(p.completed)/\(p.completed + p.remaining)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Button {
                retrieve(study)
            } label: {
                Label("Retrieve", systemImage: "arrow.down.circle")
            }
            .disabled(pacsService.isBusy)
        }
    }

    private func testConnection() {
        errorMessage = nil
        statusMessage = ""
        Task {
            do {
                try await pacsService.echo(node: node)
                statusMessage = "Connection succeeded."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func search() {
        errorMessage = nil
        statusMessage = ""
        results = []
        Task {
            do {
                let found = try await pacsService.findStudies(
                    node: node,
                    patientName: patientName,
                    patientID: patientID,
                    studyDate: studyDate,
                    accessionNumber: accessionNumber
                )
                results = found
                statusMessage = found.isEmpty ? "No studies matched." : ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func retrieve(_ study: PACSStudy) {
        errorMessage = nil
        retrievingStudyUID = study.studyInstanceUID
        Task {
            defer { retrievingStudyUID = nil }
            do {
                let destination = try pacsRetrievalDirectory(forStudyInstanceUID: study.studyInstanceUID)
                let (completed, failed) = try await pacsService.retrieveStudy(
                    node: node,
                    studyInstanceUID: study.studyInstanceUID,
                    destinationDirectory: destination
                )
                if failed > 0 {
                    statusMessage = "Retrieved \(completed) image(s), \(failed) failed."
                } else {
                    statusMessage = "Retrieved \(completed) image(s)."
                }
                model.load(url: destination)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Creates (if needed) and returns a per-study folder under this app's Documents directory
    /// to receive C-GET output -- Documents rather than a temp/cache directory since retrieved
    /// studies should survive app relaunches like any other locally-opened DICOM folder.
    private func pacsRetrievalDirectory(forStudyInstanceUID studyInstanceUID: String) throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        // StudyInstanceUID is a DICOM UID (digits and dots only), always a safe path component --
        // no sanitization needed beyond what it already guarantees.
        let studyDirectory = documents
            .appendingPathComponent("PACSRetrieved", isDirectory: true)
            .appendingPathComponent(studyInstanceUID, isDirectory: true)
        try FileManager.default.createDirectory(at: studyDirectory, withIntermediateDirectories: true)
        return studyDirectory
    }
}
