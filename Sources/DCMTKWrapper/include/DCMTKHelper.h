// DCMTKHelper.h
// OpenDicomViewer
//
// Public Objective-C interface for the DCMTK wrapper. Exposes DICOM image
// decoding functionality to Swift via two classes:
//   - DCMTKHelper: Stateless class methods for one-shot decoding
//   - DCMTKImageObject: Retains decoded image state for efficient re-rendering
//
// NOTE (iOS port): this header used to `#import <AppKit/AppKit.h>` and return
// `NSImage *` from two methods (DCMTKHelper's DICOM->image conversion and
// DCMTKImageObject's window/level render). AppKit is macOS-only, so that
// hard-blocked this target from compiling for iOS at all -- independent of
// the DCMTK/OpenJPEG XCFrameworks now being built and linked for iOS (see
// docs/iOS-Build.md). Both methods now return the decoded/rendered image as
// raw 8-bit pixel bytes (NSData, gray if samples==1, interleaved RGB if
// samples==3) plus its dimensions instead of a platform-specific image
// object -- CGImage/PlatformImage construction from those bytes now happens
// on the Swift side (see PlatformImageFactory.make(dcmtkPixelData:...) in
// PlatformCompat.swift), which is identical on macOS and iOS. This mirrors
// the shape `getRawPixelData:`/`decodeJPEG2000DICOM:` below already used --
// they never touched AppKit in the first place.
//
// NS_SWIFT_NAME pins the exact Swift call site for both renamed methods
// rather than relying on the Clang importer's preposition-splitting heuristic
// (the kind that turned the old `convertDICOMToNSImage:` into Swift's
// `convertDICOM(toNSImage:)`) -- this couldn't be verified against a real
// Swift toolchain in the sandbox that made this change, so pinning removes
// the guesswork.
#import <Foundation/Foundation.h>

@interface DCMTKHelper : NSObject

/// Decodes `path` and returns its default-windowed 8-bit display pixels as
/// raw bytes (gray if `*samples==1`, interleaved RGB if `*samples==3`), with
/// `*width`/`*height`/`*samples` set to the decoded image's actual pixel
/// dimensions. Returns nil on failure.
+ (nullable NSData *)convertDICOMToDisplayPixels:(NSString *)path
                                            width:(NSInteger *)width
                                           height:(NSInteger *)height
                                          samples:(NSInteger *)samples
    NS_SWIFT_NAME(convertDICOMToDisplayPixels(_:width:height:samples:));
+ (NSData *)getRawPixelData:(NSString *)path
                      width:(NSInteger *)width
                     height:(NSInteger *)height
                   bitDepth:(NSInteger *)bitDepth
                    samples:(NSInteger *)samples
                   isSigned:(BOOL *)isSigned;

/// Returns a human-readable error string for the last failed DICOM load, or nil if no error.
+ (NSString *)lastErrorForPath:(NSString *)path;

/// Attempts to decode a JPEG2000-compressed DICOM file using OpenJPEG.
/// Returns raw decompressed pixel data, or nil on failure.
+ (NSData *)decodeJPEG2000DICOM:(NSString *)path
                          width:(NSInteger *)width
                         height:(NSInteger *)height
                       bitDepth:(NSInteger *)bitDepth
                        samples:(NSInteger *)samples
                       isSigned:(BOOL *)isSigned;

@end

@interface DCMTKImageObject : NSObject

- (instancetype)initWithPath:(NSString *)path;
/// Applies window/level (`ww`/`wc`) and returns the rendered 8-bit display
/// pixels as raw bytes (gray if `*samples==1`, interleaved RGB if
/// `*samples==3`), with `*width`/`*height`/`*samples` set to the decoded
/// image's actual pixel dimensions. Returns nil on failure. (Previously took
/// explicit target width/height to bake a non-uniform display size into the
/// returned NSImage -- every call site in this codebase always passed 0/0
/// for "use natural size", so that parameter pair was dropped rather than
/// carried over as dead API surface.)
- (nullable NSData *)renderPixelDataWithWW:(double)ww
                                         wc:(double)wc
                                      width:(NSInteger *)width
                                     height:(NSInteger *)height
                                    samples:(NSInteger *)samples
    NS_SWIFT_NAME(renderPixelData(ww:wc:width:height:samples:));
- (NSData *)getRawDataWidth:(NSInteger *)width
                     height:(NSInteger *)height
                   bitDepth:(NSInteger *)bitDepth
                    samples:(NSInteger *)samples
                   isSigned:(BOOL *)isSigned;
- (double)getWindowWidth;
- (double)getWindowCenter;

@end
