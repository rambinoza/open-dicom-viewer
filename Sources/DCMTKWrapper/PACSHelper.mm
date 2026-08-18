// PACSHelper.mm — OpenDicomViewer
//
// Thin Objective-C++ bridge over pacs_core.hpp/.cpp's pure-C++ DCMTK networking core -- see
// PACSHelper.h and pacs_core.hpp for the full design rationale and verification-level writeup.
// This file itself (NSString/NSArray/block <-> std::string/std::vector/std::function bridging)
// has NOT been compiler-verified, unlike pacs_core.cpp -- there's no Foundation/ObjC runtime
// available in the sandbox that wrote this to check it against. It follows the same ivar/init
// conventions already established by DCMTKHelper.mm's DCMTKImageObject (a raw/value C++ member
// declared directly in the @implementation block, matching that file's style) for consistency.
#import "PACSHelper.h"
#import "DCMTKSharedInit.h"

#include "pacs_core.hpp"

#pragma mark - PACSStudyResult

@implementation PACSStudyResult

- (instancetype)initWithRecord:(const PACSStudyRecord &)record {
  self = [super init];
  if (self) {
    _patientName = [NSString stringWithUTF8String:record.patientName.c_str()];
    _patientID = [NSString stringWithUTF8String:record.patientID.c_str()];
    _studyInstanceUID = [NSString stringWithUTF8String:record.studyInstanceUID.c_str()];
    _studyDate = [NSString stringWithUTF8String:record.studyDate.c_str()];
    _studyDescription = [NSString stringWithUTF8String:record.studyDescription.c_str()];
    _modalitiesInStudy = [NSString stringWithUTF8String:record.modalitiesInStudy.c_str()];
    _accessionNumber = [NSString stringWithUTF8String:record.accessionNumber.c_str()];
    _numberOfInstances = record.numberOfInstances;
  }
  return self;
}

@end

#pragma mark - PACSClient

// Converts a possibly-nil Swift/ObjC string to a std::string, treating nil the same as empty
// (both mean "don't filter on this field" throughout pacs_core's query methods).
static std::string stdString(NSString *_Nullable s) {
  return s ? std::string([s UTF8String]) : std::string();
}

@implementation PACSClient {
  PACSNodeConfig _config;
  NSString *_lastError;
}

- (instancetype)initWithHost:(NSString *)host
                         port:(NSInteger)port
               callingAETitle:(NSString *)callingAETitle
                calledAETitle:(NSString *)calledAETitle {
  self = [super init];
  if (self) {
    ensureDCMTKInitialized();
    _config.host = stdString(host);
    _config.port = (int)port;
    _config.callingAETitle = stdString(callingAETitle);
    _config.calledAETitle = stdString(calledAETitle);
    _lastError = nil;
  }
  return self;
}

- (NSString *)lastError {
  return _lastError;
}

- (BOOL)echo {
  ensureDCMTKInitialized();
  _lastError = nil;

  PACSCore core(_config);
  std::string error;
  BOOL ok = core.echo(error) ? YES : NO;
  if (!ok) {
    _lastError = [NSString stringWithUTF8String:error.c_str()];
  }
  return ok;
}

- (nullable NSArray<PACSStudyResult *> *)findStudiesWithPatientName:(nullable NSString *)patientName
                                                            patientID:(nullable NSString *)patientID
                                                            studyDate:(nullable NSString *)studyDate
                                                      accessionNumber:(nullable NSString *)accessionNumber {
  ensureDCMTKInitialized();
  _lastError = nil;

  PACSCore core(_config);
  std::vector<PACSStudyRecord> records;
  std::string error;
  BOOL ok = core.findStudies(stdString(patientName), stdString(patientID),
                              stdString(studyDate), stdString(accessionNumber),
                              records, error) ? YES : NO;
  if (!ok) {
    _lastError = [NSString stringWithUTF8String:error.c_str()];
    return nil;
  }

  NSMutableArray<PACSStudyResult *> *results = [NSMutableArray arrayWithCapacity:records.size()];
  for (const PACSStudyRecord &record : records) {
    [results addObject:[[PACSStudyResult alloc] initWithRecord:record]];
  }
  return results;
}

- (BOOL)retrieveStudyWithInstanceUID:(NSString *)studyInstanceUID
                 destinationDirectory:(NSString *)destinationDirectory
                       completedCount:(NSInteger *)completedCount
                          failedCount:(NSInteger *)failedCount
                      progressHandler:(nullable void (^)(NSInteger completed, NSInteger remaining, NSInteger failed))progressHandler {
  ensureDCMTKInitialized();
  _lastError = nil;

  PACSCore core(_config);

  // Capture the block by value into the C++ lambda (a strong copy under ARC) rather than
  // relying on std::function's templated constructor to accept the block type directly --
  // explicit and unambiguous, matching how completion-handler bridging is normally done in
  // Objective-C++.
  void (^handlerCopy)(NSInteger, NSInteger, NSInteger) = progressHandler ? [progressHandler copy] : nil;
  PACSRetrieveProgress cppProgress = nullptr;
  if (handlerCopy) {
    cppProgress = [handlerCopy](int completed, int remaining, int failed) {
      handlerCopy((NSInteger)completed, (NSInteger)remaining, (NSInteger)failed);
    };
  }

  int completed = 0;
  int failed = 0;
  std::string error;
  BOOL ok = core.retrieveStudy(stdString(studyInstanceUID), stdString(destinationDirectory),
                                completed, failed, cppProgress, error) ? YES : NO;
  if (completedCount) *completedCount = completed;
  if (failedCount) *failedCount = failed;
  if (!ok) {
    _lastError = [NSString stringWithUTF8String:error.c_str()];
  }
  return ok;
}

- (NSInteger)storeFiles:(NSArray<NSString *> *)filePaths
         progressHandler:(nullable void (^)(NSInteger completed, NSInteger total, NSString *currentFile))progressHandler {
  ensureDCMTKInitialized();
  _lastError = nil;

  PACSCore core(_config);

  std::vector<std::string> paths;
  paths.reserve(filePaths.count);
  for (NSString *path in filePaths) {
    paths.push_back(stdString(path));
  }

  void (^handlerCopy)(NSInteger, NSInteger, NSString *) = progressHandler ? [progressHandler copy] : nil;
  PACSStoreProgress cppProgress = nullptr;
  if (handlerCopy) {
    cppProgress = [handlerCopy](int completed, int total, const std::string &currentFile) {
      NSString *currentFileString = [NSString stringWithUTF8String:currentFile.c_str()];
      handlerCopy((NSInteger)completed, (NSInteger)total, currentFileString);
    };
  }

  std::string error;
  int successCount = core.storeFiles(paths, cppProgress, error);
  if (!error.empty()) {
    _lastError = [NSString stringWithUTF8String:error.c_str()];
  }
  return successCount;
}

@end
