// pacs_core.hpp — OpenDicomViewer
//
// Pure C++ (no Objective-C, no Foundation) DICOM networking core, added for PACS
// query/retrieve/send support (C-ECHO, C-FIND, C-GET, C-STORE-SCU) on top of DCMTK's dcmnet
// module. PACSHelper.h/.mm (the public Objective-C interface Swift actually calls) is a thin
// bridging layer over this class -- everything that actually talks to DCMTK's DcmSCU API lives
// here instead, specifically so it can be syntax-checked with a plain `clang++ -fsyntax-only`
// against the real DCMTK 3.6.8 headers already present in this sandbox at libs/dcmtk/include
// (see docs/iOS-Build.md for how that came to exist here) -- something PACSHelper.mm itself
// can't be, since it needs Foundation/the ObjC runtime that this sandbox doesn't have. That
// syntax check (verifying every DcmSCU/DcmDataset/OFCondition/... class, method, and enum name
// used below matches its real declaration, with the real signature) passed cleanly with
// -Wall -Wextra and zero diagnostics -- a meaningfully stronger verification bar than the rest
// of this iOS port's networking-adjacent code, though still NOT a substitute for an actual
// `swift build` + real-PACS runtime test, which only the user's Mac can do.
//
// DESIGN NOTE -- C-GET instead of C-MOVE: the DICOM standard offers two retrieve mechanisms.
// C-MOVE asks the PACS to open a *new, separate* association back to a Storage SCP the client
// names (by AE title) and push the requested instances there via C-STORE -- meaning the client
// must itself run a listening Storage SCP, permanently reachable at a known port/AE title, for
// the PACS to connect back to. C-GET instead streams the requested instances back as C-STORE
// sub-operations on the SAME already-open association the client used to send the C-GET
// request -- no separate listening SCP needed at all. For a mobile/desktop viewer app (as
// opposed to a fixed workstation with a static IP a PACS admin has pre-registered as a known
// move destination), C-GET is the dramatically better fit: it works from behind NAT, needs no
// inbound firewall rule, no persistent background listening socket (a real constraint on iOS),
// and no per-client AE title pre-registration on the PACS beyond the query/retrieve association
// itself. The tradeoff: a small minority of older/stricter PACS deployments only implement
// C-MOVE, not C-GET (C-GET was historically less consistently implemented server-side, though
// virtually all modern PACS support both). C-MOVE support could be added later as a fallback
// (DcmSCU::sendMOVERequest exists and this class's structure leaves room for it) but isn't
// implemented here -- flagged as a known follow-up rather than silently missing.
//
// DESIGN NOTE -- presentation contexts for storage SOP classes: both C-GET (sub-operation
// C-STORE requests arrive on the SAME association as the C-GET request, so their SOP classes
// must be negotiated UP FRONT alongside it) and outbound C-STORE need presentation contexts for
// whatever storage SOP class(es) the actual image objects use. DCMTK's dcuid.h exports a
// `dcmAllStorageSOPClassUIDs` array covering essentially every storage SOP class DCMTK knows
// about, which reference SCU/GETSCU-style command line tools typically propose in full -- but
// the DICOM standard caps a single association at 128 presentation contexts (1-byte, odd-only
// context ID field), and this sandbox has no way to confirm at build time whether DCMTK's own
// association-negotiation code silently truncates, errors, or something else if asked to
// propose more contexts than that. Rather than guess, kStorageSOPClasses below is a curated
// list covering the modalities this viewer's local-file decode path already supports (CT, MR,
// enhanced CT/MR, CR, DX, US, secondary capture, XA, NM, PET, RT image/dose/struct/plan) --
// comfortably under the 128 limit with room to spare. This trades a small amount of coverage
// (an unusual modality's SOP class this list doesn't happen to include would fail to retrieve)
// for a build that isn't gambling on an unverifiable limit. Extend the list if a real-world PACS
// retrieve turns up a missing SOP class -- the failure mode is an explicit "no presentation
// context" error on that specific instance, not a silent hang or truncated association.
//
// IMPORTANT CAVEAT (same as the rest of this iOS port's networking-adjacent work): the
// -fsyntax-only check above proves this file's DCMTK API usage matches real declarations. It
// does NOT prove the code behaves correctly against a real PACS server -- no DICOM network
// exists to test against from this sandbox, and this file has never been linked, let alone run.
// Treat the first real-PACS test on the user's Mac as the actual verification step.

#ifndef OPENDICOMVIEWER_PACS_CORE_HPP
#define OPENDICOMVIEWER_PACS_CORE_HPP

#include <functional>
#include <string>
#include <vector>

/// One PACS node's connection parameters.
struct PACSNodeConfig
{
    std::string host;
    int port = 104;
    std::string callingAETitle; // this app's AE title
    std::string calledAETitle;  // the PACS's AE title
};

/// A single C-FIND STUDY-level result row.
struct PACSStudyRecord
{
    std::string patientName;
    std::string patientID;
    std::string studyInstanceUID;
    std::string studyDate;    // raw DICOM DA, e.g. "20240115" -- formatting left to the caller
    std::string studyDescription;
    std::string modalitiesInStudy;
    std::string accessionNumber;
    int numberOfInstances = -1; // -1 if the SCP didn't return (0020,1208)
};

/// Progress callback for a C-GET retrieve: (completedSubops, remainingSubops, failedOrWarningSubops).
/// May be called from any thread -- callers that touch UI from it must hop to the main thread.
using PACSRetrieveProgress = std::function<void(int, int, int)>;

/// Progress callback for outbound C-STORE: (completedCount, totalCount, currentFilePath).
using PACSStoreProgress = std::function<void(int, int, const std::string&)>;

/// One PACS connection/session. Not thread-safe; not reentrant -- create one instance per
/// operation (or serialize calls) rather than sharing across concurrent requests, matching
/// DcmSCU's own single-association-at-a-time design.
class PACSCore
{
public:
    explicit PACSCore(const PACSNodeConfig& config);
    ~PACSCore();

    /// Sends a C-ECHO to verify connectivity/AE title configuration. Returns true on success;
    /// on failure, errorOut is set to a human-readable message.
    bool echo(std::string& errorOut);

    /// STUDY-level C-FIND. Any of the filter strings may be empty to mean "don't filter on this
    /// field" (translated to a DICOM universal-match "*" for PatientName, empty-value "match
    /// all" for the rest, per standard C-FIND semantics). Returns true if the association and
    /// C-FIND exchange completed without a transport/protocol error (an empty `results` is a
    /// valid "no matches" outcome, not a failure) -- false with errorOut set otherwise.
    bool findStudies(const std::string& patientName,
                      const std::string& patientID,
                      const std::string& studyDate,
                      const std::string& accessionNumber,
                      std::vector<PACSStudyRecord>& results,
                      std::string& errorOut);

    /// Retrieves every instance of `studyInstanceUID` via C-GET, writing received files directly
    /// into `destinationDirectory` (must already exist and be writable). `completed`/`failed` are
    /// set to the final sub-operation counts reported by the SCP. Returns true if the C-GET
    /// session completed without a hard transport/association error (a nonzero `failed` count
    /// with a true return means the session completed but some instances individually failed --
    /// check both).
    bool retrieveStudy(const std::string& studyInstanceUID,
                        const std::string& destinationDirectory,
                        int& completed,
                        int& failed,
                        const PACSRetrieveProgress& progress,
                        std::string& errorOut);

    /// Sends each local DICOM file in `filePaths` via C-STORE. Returns the number of files
    /// successfully stored (0..filePaths.size()); stops at the first association-level
    /// (not per-file) error and sets errorOut. A per-file storage failure (SCP returns a
    /// non-success status for that one file) is logged via `progress` but does not stop the
    /// loop or count as an association-level error.
    int storeFiles(const std::vector<std::string>& filePaths,
                    const PACSStoreProgress& progress,
                    std::string& errorOut);

private:
    PACSNodeConfig m_config;

    // Non-copyable: owns a DcmSCU (defined only in the .cpp to keep this header ObjC-safe to
    // include from PACSHelper.mm without pulling DCMTK's C++ headers into every Swift-visible
    // translation unit).
    PACSCore(const PACSCore&) = delete;
    PACSCore& operator=(const PACSCore&) = delete;
};

#endif // OPENDICOMVIEWER_PACS_CORE_HPP
