//
//  PlatformCompat.swift
//  OpenDicomViewer
//
//  Cross-platform (macOS + iOS) type aliases and helpers, added for the iOS port.
//
//  DESIGN NOTE: the original macOS-only code leans on a genuinely AppKit-specific trick in
//  several places -- `NSImage(cgImage:size:)` lets you give an image an arbitrary *logical*
//  display size completely decoupled from its underlying CGImage's pixel dimensions. This is
//  used deliberately in MPREngine.renderSlice (see below) to bake non-isotropic voxel spacing
//  (e.g. a sagittal/coronal MPR reformat where in-plane pixel spacing differs from slice
//  spacing) into the image itself, so every consumer displays it correctly for free without
//  needing to know about physical spacing.
//
//  UIImage has NO equivalent: its `size` is always derived from the CGImage's pixel dimensions
//  and a single uniform `scale` factor -- there's no way to give it an independent, non-uniform
//  logical width/height the way NSImage allows. Rather than pushing aspect-correction logic out
//  into every view that displays one of these images (a much bigger change, touching
//  ContentView.swift and MultiPanelContainer.swift's rendering paths), `PlatformImage.make`
//  below preserves the "the image's own size is authoritative for display" contract on iOS too,
//  by actually resampling the CGImage to the target aspect-corrected pixel dimensions before
//  wrapping it. This costs one extra CGContext redraw pass per MPR slice render on iOS only --
//  negligible next to the per-slice window/level pixel loop already happening there, and it
//  means every downstream view (SwiftUI `Image`, gesture math, etc.) can keep trusting
//  `image.size` exactly like the macOS code already does.
//

import Foundation
import CoreGraphics
import SwiftUI

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformView = NSView
#else
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformView = UIView
#endif

/// Wraps a `PlatformImage` (NSImage/UIImage) in SwiftUI's `Image`, hiding the fact that
/// `Image(nsImage:)`/`Image(uiImage:)` are separate, platform-specific initializers.
///
/// NOTE (iOS port): call sites used to spell this inline as
/// `#if os(macOS) Image(nsImage: x).resizable() #else Image(uiImage: x).resizable() #endif`
/// followed by further chained modifiers (`.aspectRatio(...)`, `.frame(...)`, ...) *after* the
/// `#endif`. That pattern fails to compile: once each `#if`/`#else` branch already contains its
/// own chained call (`.resizable()`), the compiler cannot unify the branches back into a single
/// postfix-expression chain for the modifiers that follow `#endif`, and erases the result to the
/// bare `View` existential -- which then can't use protocol-extension members like
/// `aspectRatio(contentMode:)` that return `some View` (error: "instance member 'aspectRatio'
/// cannot be used on type 'View'"). Routing the *construction* of the plain `Image` through this
/// single-expression helper (no chained calls, no #if inside the helper's call sites) keeps every
/// call site's modifier chain unconditional and unbroken.
public func platformImage(_ image: PlatformImage) -> Image {
    #if os(macOS)
    return Image(nsImage: image)
    #else
    return Image(uiImage: image)
    #endif
}

public enum PlatformImageFactory {
    /// Wraps `cgImage` for display at `displaySize` (in points/logical units, which may differ
    /// from the CGImage's own pixel dimensions to correct for non-isotropic pixel/voxel
    /// spacing). Use this everywhere the old code called `NSImage(cgImage:size:)` directly.
    public static func make(cgImage: CGImage, displaySize: CGSize) -> PlatformImage? {
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: displaySize.width, height: displaySize.height))
        #else
        let nativeWidth = CGFloat(cgImage.width)
        let nativeHeight = CGFloat(cgImage.height)

        // Common case (the overwhelming majority of call sites): the requested display size
        // already matches the CGImage's native pixel dimensions -- e.g. axial slices with
        // square in-plane pixel spacing. No resampling needed, just wrap it directly.
        if abs(nativeWidth - displaySize.width) < 0.5 && abs(nativeHeight - displaySize.height) < 0.5 {
            return UIImage(cgImage: cgImage)
        }

        // Non-isotropic case (e.g. an MPR reformat needing aspect correction): redraw into a
        // new bitmap at the corrected pixel dimensions so the resulting UIImage's own size
        // (pixels / scale 1.0) already reflects the intended physical aspect ratio.
        let targetWidth = max(1, Int(displaySize.width.rounded()))
        let targetHeight = max(1, Int(displaySize.height.rounded()))
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: cgImage.bitmapInfo.rawValue
        ) else {
            // Fall back to an undistorted image rather than failing outright -- aspect ratio
            // will be slightly off, but that's better than no image at all.
            return UIImage(cgImage: cgImage)
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let resized = context.makeImage() else { return UIImage(cgImage: cgImage) }
        return UIImage(cgImage: resized)
        #endif
    }

    /// Re-tags an already-built image with a new *logical* display size, to bake in aspect-ratio
    /// correction for non-isotropic spacing after the fact (e.g. GPU renderers that hand back a
    /// fixed-size image and only know the correct display aspect ratio afterward).
    /// On macOS this is a cheap in-place mutation of NSImage's decoupled `size` property, matching
    /// the original single-platform code. On iOS, where UIImage.size is derived from pixel
    /// dimensions and read-only, this resamples the underlying CGImage to the target size instead.
    public static func resized(_ image: PlatformImage, to displaySize: CGSize) -> PlatformImage? {
        #if os(macOS)
        image.size = NSSize(width: displaySize.width, height: displaySize.height)
        return image
        #else
        guard let cg = cgImage(from: image) else { return nil }
        return make(cgImage: cg, displaySize: displaySize)
        #endif
    }

    /// Cross-platform CGImage extraction. NSImage requires the `cgImage(forProposedRect:context:hints:)`
    /// call (it's not always backed by a single bitmap rep); UIImage exposes `cgImage` directly.
    public static func cgImage(from image: PlatformImage) -> CGImage? {
        #if os(macOS)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }

    /// Builds a PlatformImage from raw 8-bit display pixel bytes as returned by
    /// DCMTKHelper.convertDICOMToDisplayPixels(_:width:height:samples:) and
    /// DCMTKImageObject.renderPixelData(ww:wc:width:height:samples:) in DCMTKWrapper
    /// (gray if `samples == 1`, interleaved RGB if `samples == 3`).
    ///
    /// DCMTKHelper used to build the CGImage/NSImage itself and hand back a finished
    /// NSImage, but NSImage is AppKit-only. It now hands back the raw windowed pixel
    /// bytes instead (identical on macOS/iOS -- see the NOTE in DCMTKHelper.h), and this
    /// is the Swift-side counterpart that reconstructs the CGImage from them, mirroring
    /// exactly what the Objective-C++ code used to do inline (same colorspace/bitmap-info
    /// choices). Always renders at the pixel data's own natural size -- every call site
    /// that used to pass an explicit display width/height to the old NSImage-returning
    /// methods always passed 0/0 ("use natural size"), so that parameter pair wasn't
    /// carried over into this helper; call `resized(_:to:)` afterward if a caller ever
    /// needs non-uniform display-size baking for one of these images.
    public static func make(dcmtkPixelData data: Data, width: Int, height: Int, samples: Int) -> PlatformImage? {
        guard width > 0, height > 0, samples == 1 || samples == 3 else { return nil }
        let colorSpace = samples == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8 * samples,
            bytesPerRow: width * samples,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return make(cgImage: cgImage, displaySize: CGSize(width: width, height: height))
    }
}
