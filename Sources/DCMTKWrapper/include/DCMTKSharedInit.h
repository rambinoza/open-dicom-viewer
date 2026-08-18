// DCMTKSharedInit.h — OpenDicomViewer
//
// Internal (not exposed to Swift -- not part of any target's public `include/` umbrella,
// nowhere else does an .mm file with a Swift-facing NS_SWIFT_NAME'd interface #import this)
// shared DCMTK one-time initialization, used by both DCMTKHelper.mm and PACSHelper.mm. DCMTK
// must have its data dictionary loaded (DCMDICTPATH pointed at the bundled dicom.dic) before
// ANY DCMTK API call from ANY file in this target -- tag/VR lookups throughout dcmdata and
// dcmnet depend on it being loaded, not just the image-decode paths DCMTKHelper.mm originally
// used this for. This was previously a `static` function private to DCMTKHelper.mm; pulled out
// to a shared internal header once PACSHelper.mm needed the same guarantee, rather than
// duplicating the dispatch_once/DCMDICTPATH/codec-registration logic a second time.
#ifndef OPENDICOMVIEWER_DCMTK_SHARED_INIT_H
#define OPENDICOMVIEWER_DCMTK_SHARED_INIT_H

#ifdef __cplusplus
extern "C" {
#endif

/// Idempotent (dispatch_once-guarded): safe to call at the top of every public entry point in
/// this target. Must run before any DCMTK API usage.
void ensureDCMTKInitialized(void);

#ifdef __cplusplus
}
#endif

#endif // OPENDICOMVIEWER_DCMTK_SHARED_INIT_H
