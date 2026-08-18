// PACSHelper.h — OpenDicomViewer
//
// Public Objective-C interface for PACS networking (DICOM C-ECHO / C-FIND / C-GET / C-STORE),
// added as part of the iOS port's networking task. This is a thin bridge: the actual DCMTK
// dcmnet API usage lives in pacs_core.hpp/.cpp (pure C++, no Foundation/ObjC dependency), which
// was syntax-checked with a real C++ compiler against the real DCMTK 3.6.8 headers cross-built
// in this project's libs/dcmtk -- see pacs_core.hpp for the full verification-level writeup and
// the C-GET-vs-C-MOVE design rationale. This .h/.mm bridging layer itself, like DCMTKHelper.mm's
// ObjC surface before it, has NOT been compiler-verified (no Swift/ObjC toolchain in the sandbox
// that wrote it) -- ordinary NSString/NSArray/block bridging code, but still unverified.
//
// NS_SWIFT_NAME pins exact Swift call-site spellings rather than relying on the Clang importer's
// preposition-splitting heuristic, matching the convention established in DCMTKHelper.h.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One C-FIND STUDY-level result row.
@interface PACSStudyResult : NSObject

@property (nonatomic, copy, readonly) NSString *patientName;
@property (nonatomic, copy, readonly) NSString *patientID;
@property (nonatomic, copy, readonly) NSString *studyInstanceUID;
/// Raw DICOM DA value (e.g. "20240115"), or empty string if the SCP didn't return one.
/// Formatting into a display date is left to the Swift side.
@property (nonatomic, copy, readonly) NSString *studyDate;
@property (nonatomic, copy, readonly) NSString *studyDescription;
/// Space-separated modality codes, e.g. "CT" or "CT PT", per DICOM (0008,0061). May be empty
/// even for a real study if the SCP doesn't populate this optional attribute.
@property (nonatomic, copy, readonly) NSString *modalitiesInStudy;
@property (nonatomic, copy, readonly) NSString *accessionNumber;
/// -1 if the SCP didn't return (0020,1208); otherwise the SCP-reported instance count.
@property (nonatomic, assign, readonly) NSInteger numberOfInstances;

@end

/// A single PACS connection/session. Not thread-safe and not reentrant: each method opens its
/// own DICOM association, uses it for exactly one operation, and closes it before returning --
/// do not call two methods on the same instance concurrently from different threads. All
/// methods below are synchronous/blocking (real network I/O) -- call from a background queue,
/// never from the main thread.
@interface PACSClient : NSObject

/// `callingAETitle` is this app's own AE title (how it identifies itself to the PACS);
/// `calledAETitle` is the PACS's AE title. Neither is validated here -- an invalid/mismatched
/// AE title will surface as an association-rejection error from the corresponding method.
- (instancetype)initWithHost:(NSString *)host
                         port:(NSInteger)port
               callingAETitle:(NSString *)callingAETitle
                calledAETitle:(NSString *)calledAETitle;

/// Human-readable error from the most recently failed operation on this client. Nil if no
/// operation has failed yet. Overwritten by each call (success clears it to nil).
@property (nonatomic, copy, readonly, nullable) NSString *lastError;

/// Sends a C-ECHO to verify connectivity and AE title configuration. Returns YES on success;
/// on failure, `lastError` is set and this returns NO.
- (BOOL)echo;

/// STUDY-level C-FIND. Pass nil or an empty string for any filter to mean "don't filter on this
/// field". `studyDate` accepts a single DICOM DA value ("20240115") or a DICOM date range
/// ("20240101-20241231"), passed through to the SCP as-is. Returns nil (with `lastError` set)
/// only on an association/protocol-level failure -- an empty array is a valid "no matches"
/// result, not a failure.
- (nullable NSArray<PACSStudyResult *> *)findStudiesWithPatientName:(nullable NSString *)patientName
                                                            patientID:(nullable NSString *)patientID
                                                            studyDate:(nullable NSString *)studyDate
                                                      accessionNumber:(nullable NSString *)accessionNumber
    NS_SWIFT_NAME(findStudies(patientName:patientID:studyDate:accessionNumber:));

/// Retrieves every instance of `studyInstanceUID` via C-GET (see pacs_core.hpp for why C-GET
/// rather than C-MOVE), writing received DICOM files directly into `destinationDirectory`
/// (must already exist and be writable; DCMTK names each file by SOP Class/Instance UID).
/// `progressHandler`, if non-nil, is invoked on an arbitrary background thread (NOT necessarily
/// the calling thread) after each C-GET status update with cumulative (completed, remaining,
/// failed) sub-operation counts -- hop to the main thread yourself before touching UI.
/// `completedCount`/`failedCount` out-params receive the final totals. Returns YES if the C-GET
/// session completed without a hard transport/association error -- a nonzero failedCount together
/// with YES means the session completed but some individual instances failed; check both.
- (BOOL)retrieveStudyWithInstanceUID:(NSString *)studyInstanceUID
                 destinationDirectory:(NSString *)destinationDirectory
                       completedCount:(NSInteger *)completedCount
                          failedCount:(NSInteger *)failedCount
                      progressHandler:(nullable void (^)(NSInteger completed, NSInteger remaining, NSInteger failed))progressHandler
    NS_SWIFT_NAME(retrieveStudy(instanceUID:destinationDirectory:completedCount:failedCount:progressHandler:));

/// Sends each local DICOM file in `filePaths` to this node via C-STORE. Returns the number of
/// files successfully stored (0...filePaths.count) -- always check this against
/// filePaths.count rather than only `lastError`, since a per-file storage failure does not stop
/// the batch or count as an association-level error (only a lost connection does; see
/// `lastError` in that case). `progressHandler`, if non-nil, is invoked on an arbitrary
/// background thread after each file is attempted.
- (NSInteger)storeFiles:(NSArray<NSString *> *)filePaths
         progressHandler:(nullable void (^)(NSInteger completed, NSInteger total, NSString *currentFile))progressHandler
    NS_SWIFT_NAME(storeFiles(_:progressHandler:));

@end

NS_ASSUME_NONNULL_END
