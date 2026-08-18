// PanelTouchInteractView.swift
// OpenDicomViewer
//
// iOS touch counterpart of MultiPanelContainer.swift's macOS-only
// PanelInteractiveDICOMView/PanelDICOMInteractView (an NSViewRepresentable/NSView pair
// handling every mouse/keyboard interaction for a panel: pan, zoom, window/level,
// ROI/ruler/angle/eraser tools, slice navigation, drag & drop, and cine playback).
//
// NOTE (iOS port): this file supplies the SAME symbol names
// (`PanelInteractiveDICOMView`, nested `PanelDICOMInteractView`) as the macOS
// implementation, which is now wrapped in `#if os(macOS)` in MultiPanelContainer.swift.
// PanelView (MultiPanelContainer.swift) calls `PanelInteractiveDICOMView(model:panel:image:)`
// completely unconditionally -- it never needed to change, because whichever platform's
// version of this symbol exists is the only one visible to that build. DICOMModel.swift's
// cine-playback code also does `panel.cineDisplayView as? PanelInteractiveDICOMView.PanelDICOMInteractView`
// unconditionally (calling `setCineFrame(_:)`), which is why the nested class name and that
// one method's signature are matched exactly here too.
//
// Design mapping from mouse/keyboard to touch (see the exhaustive NOTE comments inline
// below for the reasoning behind each choice):
//   - 1-finger touch (touchesBegan/Moved/Ended) = mirrors mouseDown/mouseDragged/mouseUp,
//     dispatching on `model.activeTool` exactly like the macOS switch statements do. This
//     uses raw UITouch handling rather than UIGestureRecognizer for the primary tool
//     interactions, both because it's the closest analogue to macOS's raw NSEvent overrides
//     (same architecture, easier to keep in sync) and because a competing
//     UITapGestureRecognizer here risks fighting the SwiftUI `.onTapGesture(count: 2)`
//     already attached to the containing PanelView for fullscreen toggle
//     (MultiPanelContainer.swift) -- raw touch overrides on this UIView participate in the
//     UIKit responder chain more predictably alongside that.
//   - 2-finger pan gesture = always window/level, replacing macOS's right-click-drag (which
//     works regardless of `activeTool`, same as this).
//   - Pinch gesture = always zoom, replacing macOS's scroll-wheel/Option-scroll zoom.
//   - Long-press = toggles this panel's group-selection (`panel.isGroupSelected`), replacing
//     Shift+click (there's no modifier-key equivalent on touch). Known simplification: unlike
//     Shift+click, a long-press does NOT suppress the ordinary touchesBegan tool-dispatch that
//     already fired at touch-down (e.g. this may also place a ruler point) -- there is no
//     touch equivalent of "hold a modifier down before the initial press", so this is an
//     accepted rough edge rather than something worth a fragile workaround; flagged for
//     follow-up if it proves annoying in practice.
//   - Vertical 1-finger drag while `activeTool == .select` = slice navigation, replacing
//     scroll-wheel slice-stepping. `.select` is the one tool where macOS's mouseDragged does
//     nothing at all, so this reuses that otherwise-idle gesture slot rather than stealing one
//     from an active tool.
//   - Mouse hover (mouseMoved/mouseEntered/mouseExited -- HU cursor readout, live ruler/angle
//     preview between the first and second tap) has no direct touch equivalent (touch has no
//     "hover"). NOT ported in this pass: the HU readout overlay simply won't populate on iOS
//     yet, and ruler/angle preview lines only update while a second touch is actively down
//     (via touchesMoved) rather than continuously following an idle cursor. Tracked as a
//     follow-up, not blocking core pan/zoom/W-L/tool-placement functionality.
//   - Drag-and-drop of a sidebar series row onto a panel (NSDraggingDestination on macOS) is
//     NOT ported here -- SwiftUI's cross-platform `.onDrag`/`.onDrop` could work on
//     iPadOS/iPhone but needs its own design pass (e.g. a tap-to-assign fallback for
//     compact-width iPhone layouts) rather than a mechanical NSView->UIView port. Tracked as a
//     follow-up; `model.assignSeriesToPanel`/`model.load(url:)` (the same methods the macOS
//     drop handler calls) are unaffected and ready to be wired up whenever that UI lands.
//   - `PanelScrollerInteractionView` (the small NSView backing `PanelDICOMScroller`'s
//     drag-to-scrub track + hover-preview thumbnail, MultiPanelContainer.swift) IS ported
//     below -- its callback interface (onDrag/onHover/onEnter/onExit) was already a clean,
//     narrow abstraction, so `PanelDICOMScroller`'s SwiftUI body (the visual track/handle/
//     thumbnail-popup code) is reused completely unchanged on iOS. `onHover`/`onEnter` map to
//     touch-began (there's no true hover on touch, but showing the thumbnail preview as soon
//     as a finger touches the track is a reasonable substitute), and `onExit` maps to
//     touch-ended/cancelled.
//
// IMPORTANT: this file has never been compiled. The sandbox that wrote it has no Swift
// toolchain, and -- unlike every other iOS-port change so far -- `swift build` on macOS
// cannot type-check `#if os(iOS)` code at all (Package.swift's `platforms:` is still
// macOS-only, so the compiler never even parses this file in a macOS build). This will only
// get real compiler feedback once `.iOS(.v17)` is back in Package.swift's `platforms:` and an
// actual Xcode iOS App target exists (docs/iOS-Build.md steps 0-3) and someone builds for an
// iOS destination in Xcode. Expect a debugging pass at that point, the same way the DCMTK
// cross-compile itself took several rounds against real build output -- this is written as
// carefully as possible against the exact macOS implementation it mirrors, but "carefully
// written, never compiled" is a real and different risk profile from the fixes earlier in
// this port that a macOS `swift build` could actually catch mistakes in.
//
// Licensed under the MIT License. See LICENSE for details.

#if os(iOS)
import SwiftUI
import UIKit
import CoreGraphics
import QuartzCore

struct PanelInteractiveDICOMView: UIViewRepresentable {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState
    var image: PlatformImage

    func makeUIView(context: Context) -> PanelDICOMInteractView {
        let view = PanelDICOMInteractView()
        view.model = model
        view.panel = panel
        panel.cineDisplayView = view
        return view
    }

    func updateUIView(_ uiView: PanelDICOMInteractView, context: Context) {
        uiView.model = model
        uiView.panel = panel
        // During cine playback, frames are rendered directly via setCineFrame on the
        // CALayer -- skip the expensive SwiftUI image pipeline but still apply the
        // transform (zoom/pan) so W/L and navigation work. Mirrors the macOS
        // PanelInteractiveDICOMView.updateNSView exactly.
        if !panel.isPlaying {
            uiView.setImage(image)
            uiView.applyFilters()
        }
        uiView.updateTransform()
    }

    class PanelDICOMInteractView: UIView {
        weak var model: DICOMModel?
        var panel: PanelState?
        private let imageView = UIImageView()

        // MARK: - Single-finger touch state (mirrors mouseDown/mouseDragged/mouseUp)
        private var activeTouch: UITouch?
        private var lastTouchLocation: CGPoint?
        private var touchStartLocation: CGPoint?
        private var touchMoved: Bool = false
        private var wlPendingDeltaWidth: Double = 0
        private var wlPendingDeltaCenter: Double = 0
        private var wlLastRenderTime: CFTimeInterval = 0
        private let wlRenderInterval: CFTimeInterval = 1.0 / 60.0
        private var roiStartPixel: CGPoint?
        private var sliceScrollAccumulator: CGFloat = 0

        // In-progress annotation state (identical shape to the macOS implementation)
        private var rulerStartPixel: CGPoint?
        private var anglePoints: [CGPoint] = []

        // MARK: - Multi-touch gesture recognizers
        private var pinchRecognizer: UIPinchGestureRecognizer!
        private var twoFingerPanRecognizer: UIPanGestureRecognizer!
        private var longPressRecognizer: UILongPressGestureRecognizer!
        private var pinchStartScale: CGFloat = 1.0
        private var twoFingerPanLastLocation: CGPoint?

        // Prevent image dimensions from influencing SwiftUI layout
        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.frame = bounds
            if let layer = imageView.layer as CALayer? {
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                let midX = bounds.width / 2.0
                let midY = bounds.height / 2.0
                layer.position = CGPoint(x: midX, y: midY)
            }
        }

        private func setup() {
            backgroundColor = .black
            layer.masksToBounds = true

            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
            imageView.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

            pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            addGestureRecognizer(pinchRecognizer)

            twoFingerPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
            twoFingerPanRecognizer.minimumNumberOfTouches = 2
            twoFingerPanRecognizer.maximumNumberOfTouches = 2
            addGestureRecognizer(twoFingerPanRecognizer)

            longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPressRecognizer.minimumPressDuration = 0.5
            addGestureRecognizer(longPressRecognizer)

            isMultipleTouchEnabled = true
        }

        func setImage(_ img: PlatformImage) {
            if imageView.image != img {
                imageView.image = img
                DispatchQueue.main.async { [weak self] in
                    self?.restoreState()
                }
            }
        }

        /// Set a CGImage directly on the layer for high-performance cine playback.
        /// Bypasses UIImageView.image and SwiftUI update cycle entirely. Called by
        /// DICOMModel.swift's cine-playback timer via `panel.cineDisplayView as?
        /// PanelInteractiveDICOMView.PanelDICOMInteractView` -- see the file-level NOTE for
        /// why this method name/signature must match the macOS implementation exactly.
        func setCineFrame(_ cgImage: CGImage) {
            imageView.layer.contents = cgImage
        }

        func updateTransform() { restoreState() }

        private func restoreState() {
            guard let panel = panel else { return }
            let layer = imageView.layer

            // Build transform: flip -> rotate -> scale -> translate. Identical math to the
            // macOS PanelDICOMInteractView.restoreState.
            var t = CATransform3DIdentity

            let flipX: CGFloat = panel.isFlippedH ? -1.0 : 1.0
            let flipY: CGFloat = panel.isFlippedV ? -1.0 : 1.0
            t = CATransform3DScale(t, flipX, flipY, 1.0)

            let angle = CGFloat(panel.rotationSteps) * .pi / 2.0
            t = CATransform3DRotate(t, angle, 0, 0, 1)

            t = CATransform3DScale(t, panel.scale, panel.scale, 1.0)

            t = CATransform3DTranslate(t, panel.translation.x / panel.scale, panel.translation.y / panel.scale, 0)

            layer.transform = t
        }

        func applyFilters() {
            // NOTE (iOS port): macOS applies window/level (when raw pixel data isn't available
            // for CPU re-rendering) and invert via NSImageView.contentFilters (CIFilter list).
            // UIImageView has no equivalent contentFilters property -- CIFilter-based live
            // preview would need a CIContext-backed rendering path (e.g. a CALayer with a
            // CIFilter-driven contents provider, or Core Image running through Metal). Not
            // implemented in this pass: on iOS, W/L and invert always take the
            // full-re-render path through DICOMModel (renderImage/renderPlatformImage,
            // DICOMModel.swift) instead of a live filter preview, which is correct but not as
            // instantaneous under fast W/L dragging as the macOS CIFilter path. Since
            // `panel.isRawDataAvailable` is true for the overwhelming majority of images (raw
            // pixel re-render is the primary path; the CIFilter path is macOS's fallback for
            // when it's unavailable), this should rarely be visible in practice. Tracked as a
            // follow-up if fast-drag W/L preview responsiveness on iOS proves to be an issue.
        }

        private func saveState() {
            guard let panel = panel, let model = model else { return }
            let layer = imageView.layer
            let tx = layer.transform.m41
            let ty = layer.transform.m42

            panel.translation = CGPoint(x: tx, y: ty)
            model.saveViewStateForPanel(panel, scale: panel.scale, translation: CGPoint(x: tx, y: ty))
            model.syncZoomFromPanel(panel)
        }

        /// Convert a view-space point to image pixel coordinates. Touch counterpart of the
        /// macOS PanelDICOMInteractView.screenToPixel(_ event: NSEvent) -- identical math,
        /// adapted for a CGPoint already in this view's coordinate space (UIKit's coordinate
        /// system is already Y-down like image space, so unlike the macOS version this does
        /// NOT need the `y = viewH - loc.y` flip AppKit's Y-up coordinate space required).
        private func screenToPixel(_ location: CGPoint) -> CGPoint? {
            guard let panel = panel, imageView.image != nil else { return nil }

            let viewW = bounds.width
            let viewH = bounds.height
            let imgW = panel.displayImageWidth
            let imgH = panel.displayImageHeight
            guard imgW > 0, imgH > 0 else { return nil }

            let fitScale = min(viewW / imgW, viewH / imgH)
            let displayW = imgW * fitScale
            let displayH = imgH * fitScale
            let offsetX = (viewW - displayW) / 2
            let offsetY = (viewH - displayH) / 2

            let cx = viewW / 2
            let cy = viewH / 2

            var x = location.x
            var y = location.y

            // Undo pan
            x -= panel.translation.x
            y -= panel.translation.y

            // Undo zoom (center-relative)
            x = (x - cx) / panel.scale + cx
            y = (y - cy) / panel.scale + cy

            // Undo rotation (center-relative, negative angle to reverse)
            let angle = -CGFloat(panel.rotationSteps) * .pi / 2.0
            let dx = x - cx
            let dy = y - cy
            let cosA = cos(angle)
            let sinA = sin(angle)
            x = dx * cosA - dy * sinA + cx
            y = dx * sinA + dy * cosA + cy

            // Undo flip (center-relative)
            if panel.isFlippedH { x = 2 * cx - x }
            if panel.isFlippedV { y = 2 * cy - y }

            let pixelX = (x - offsetX) / fitScale
            let pixelY = (y - offsetY) / fitScale

            guard pixelX.isFinite, pixelY.isFinite else { return nil }
            return CGPoint(x: pixelX, y: pixelY)
        }

        /// Compute minimum distance from a point to an annotation (identical logic to the
        /// macOS implementation's distanceToAnnotation/pointToSegmentDistance, used by the
        /// eraser tool's nearest-annotation hit test).
        private func distanceToAnnotation(_ annotation: Annotation, from point: CGPoint) -> CGFloat {
            switch annotation.type {
            case .ruler(let start, let end, _):
                return pointToSegmentDistance(point, start, end)
            case .angle(let vertex, let arm1, let arm2, _):
                let d1 = pointToSegmentDistance(point, arm1, vertex)
                let d2 = pointToSegmentDistance(point, vertex, arm2)
                return min(d1, d2)
            case .roiStats(let rect, _, _, _, _, _):
                let closest = CGPoint(
                    x: max(rect.minX, min(point.x, rect.maxX)),
                    y: max(rect.minY, min(point.y, rect.maxY))
                )
                return hypot(point.x - closest.x, point.y - closest.y)
            }
        }

        private func pointToSegmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lenSq = dx * dx + dy * dy
            if lenSq == 0 { return hypot(p.x - a.x, p.y - a.y) }
            var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
            t = max(0, min(1, t))
            let projX = a.x + t * dx
            let projY = a.y + t * dy
            return hypot(p.x - projX, p.y - projY)
        }

        private func flushPendingWindowLevelIfNeeded(force: Bool) {
            guard let model = model, let panel = panel else { return }
            guard wlPendingDeltaWidth != 0 || wlPendingDeltaCenter != 0 else { return }

            let now = CACurrentMediaTime()
            if !force && (now - wlLastRenderTime) < wlRenderInterval {
                return
            }

            model.adjustWindowLevelForPanel(panel, deltaWidth: wlPendingDeltaWidth, deltaCenter: wlPendingDeltaCenter)
            applyFilters()
            wlPendingDeltaWidth = 0
            wlPendingDeltaCenter = 0
            wlLastRenderTime = now
        }

        // MARK: - Single-finger touch (mirrors mouseDown/mouseDragged/mouseUp)

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            // Only track a single primary touch here; the two-finger pan/pinch recognizers
            // handle multi-touch gestures independently.
            guard activeTouch == nil, let touch = touches.first, touches.count == 1 else { return }
            guard let model = model, let panel = panel else { return }

            activeTouch = touch
            let location = touch.location(in: self)
            lastTouchLocation = location
            touchStartLocation = location
            touchMoved = false

            // Activate this panel on touch-down, mirroring macOS's "click always activates,
            // unless Shift+click" -- there's no modifier-key equivalent on touch, so this
            // always activates (see the file-level NOTE re: long-press/group-select overlap).
            DispatchQueue.main.async {
                model.activePanelID = panel.id
            }

            switch model.activeTool {
            case .select, .pan:
                break

            case .windowLevel:
                wlPendingDeltaWidth = 0
                wlPendingDeltaCenter = 0

            case .zoom:
                break

            case .roiWL, .roiStats:
                if let px = screenToPixel(location) {
                    roiStartPixel = px
                    panel.roiRect = CGRect(x: px.x, y: px.y, width: 0, height: 0)
                }

            case .ruler:
                if let px = screenToPixel(location) {
                    if rulerStartPixel == nil {
                        rulerStartPixel = px
                        panel.rulerPreviewStart = px
                        panel.rulerPreviewEnd = px
                    } else {
                        let start = rulerStartPixel!
                        let dx = Double(px.x - start.x)
                        let dy = Double(px.y - start.y)
                        var distance: Double
                        if let ps = panel.pixelSpacing {
                            distance = sqrt(pow(dx * ps.1, 2) + pow(dy * ps.0, 2))
                        } else {
                            distance = sqrt(dx * dx + dy * dy)
                        }
                        let annotation = Annotation(type: .ruler(start: start, end: px, distanceMM: distance))
                        panel.annotations.append(annotation)
                        rulerStartPixel = nil
                        panel.rulerPreviewStart = nil
                        panel.rulerPreviewEnd = nil
                    }
                }

            case .angle:
                if let px = screenToPixel(location) {
                    anglePoints.append(px)
                    panel.anglePreviewPoints = anglePoints
                    if anglePoints.count == 3 {
                        let vertex = anglePoints[1]
                        let arm1 = anglePoints[0]
                        let arm2 = anglePoints[2]
                        let v1 = CGPoint(x: arm1.x - vertex.x, y: arm1.y - vertex.y)
                        let v2 = CGPoint(x: arm2.x - vertex.x, y: arm2.y - vertex.y)
                        let dot = Double(v1.x * v2.x + v1.y * v2.y)
                        let mag1 = sqrt(Double(v1.x * v1.x + v1.y * v1.y))
                        let mag2 = sqrt(Double(v2.x * v2.x + v2.y * v2.y))
                        var degrees = 0.0
                        if mag1 > 0 && mag2 > 0 {
                            let cosAngle = max(-1, min(1, dot / (mag1 * mag2)))
                            degrees = acos(cosAngle) * 180.0 / .pi
                        }
                        let annotation = Annotation(type: .angle(vertex: vertex, arm1: arm1, arm2: arm2, degrees: degrees))
                        panel.annotations.append(annotation)
                        anglePoints = []
                        panel.anglePreviewPoints = []
                    }
                }

            case .eraser:
                if let px = screenToPixel(location) {
                    let threshold: CGFloat = 20.0 // slightly larger than macOS's 15pt -- touch is less precise than a mouse cursor
                    var bestIdx: Int? = nil
                    var bestDist: CGFloat = .infinity
                    for (i, ann) in panel.annotations.enumerated() {
                        let dist = distanceToAnnotation(ann, from: px)
                        if dist < bestDist {
                            bestDist = dist
                            bestIdx = i
                        }
                    }
                    if let idx = bestIdx, bestDist < threshold {
                        panel.annotations.remove(at: idx)
                    }
                }
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = activeTouch, touches.contains(touch) else { return }
            guard let model = model, let panel = panel else { return }

            let location = touch.location(in: self)
            guard let start = lastTouchLocation else { lastTouchLocation = location; return }

            let dx = location.x - start.x
            let dy = location.y - start.y
            if abs(dx) > 2 || abs(dy) > 2 { touchMoved = true }

            switch model.activeTool {
            case .select:
                // The one tool with no drag behavior on macOS -- reused here for slice
                // navigation, see the file-level NOTE for why.
                sliceScrollAccumulator += dy
                let threshold: CGFloat = 25.0
                if abs(sliceScrollAccumulator) >= threshold {
                    if sliceScrollAccumulator > 0 {
                        model.navigatePanelWithGroup(panel, direction: .nextImage)
                    } else {
                        model.navigatePanelWithGroup(panel, direction: .prevImage)
                    }
                    sliceScrollAccumulator = 0
                }

            case .pan:
                let layer = imageView.layer
                layer.transform.m41 += dx
                layer.transform.m42 += dy
                saveState()

            case .windowLevel:
                let currentWW = panel.windowWidth
                let dynamicFactor = max(0.1, currentWW / 500.0)
                let sensitivity: Double = 1.0 * dynamicFactor
                // Note: dy is inverted relative to the macOS right-drag mapping below because
                // UIKit's Y axis already points down (screen-space down == positive dy here),
                // whereas AppKit's NSEvent locationInWindow is Y-up -- to keep "drag down =
                // darker/narrower window" feeling consistent with the two-finger W/L gesture
                // below and with macOS, dy's sign is negated here.
                wlPendingDeltaWidth += Double(dx) * sensitivity
                wlPendingDeltaCenter += Double(-dy) * sensitivity
                flushPendingWindowLevelIfNeeded(force: false)

            case .zoom:
                // Drag up = zoom in, drag down = zoom out (matches macOS's mapping; dy here
                // is already screen-down-positive so this is `-dy` where macOS used `+dy` in
                // its Y-up window-coordinate space).
                let zoomSpeed: CGFloat = 0.005
                var newScale = panel.scale + (-dy) * zoomSpeed
                newScale = max(0.1, min(10.0, newScale))
                panel.scale = newScale
                restoreState()

            case .roiWL, .roiStats:
                if let start = roiStartPixel, let current = screenToPixel(location) {
                    let x = min(start.x, current.x)
                    let y = min(start.y, current.y)
                    let w = abs(current.x - start.x)
                    let h = abs(current.y - start.y)
                    panel.roiRect = CGRect(x: x, y: y, width: w, height: h)
                }

            case .ruler:
                if rulerStartPixel != nil, let current = screenToPixel(location) {
                    panel.rulerPreviewEnd = current
                }

            case .angle:
                if !anglePoints.isEmpty, let current = screenToPixel(location) {
                    var preview = anglePoints
                    preview.append(current)
                    panel.anglePreviewPoints = preview
                }

            case .eraser:
                break
            }

            lastTouchLocation = location
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = activeTouch, touches.contains(touch) else { return }
            finishTouch()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = activeTouch, touches.contains(touch) else { return }
            finishTouch()
        }

        private func finishTouch() {
            guard let model = model, let panel = panel else {
                activeTouch = nil
                lastTouchLocation = nil
                touchStartLocation = nil
                return
            }

            switch model.activeTool {
            case .roiWL:
                if let rect = panel.roiRect, rect.width > 1 && rect.height > 1 {
                    model.autoWindowLevelForPanelROI(panel, rect: rect)
                }
                roiStartPixel = nil
                panel.roiRect = nil

            case .roiStats:
                if let rect = panel.roiRect, rect.width > 1 && rect.height > 1 {
                    if let stats = model.computeROIStats(panel: panel, rect: rect) {
                        let annotation = Annotation(type: .roiStats(
                            rect: rect,
                            mean: stats.mean, max: stats.max, min: stats.min,
                            stdDev: stats.stdDev, count: stats.count
                        ))
                        panel.annotations.append(annotation)
                    }
                }
                roiStartPixel = nil
                panel.roiRect = nil

            case .windowLevel:
                flushPendingWindowLevelIfNeeded(force: true)

            default:
                break
            }

            activeTouch = nil
            lastTouchLocation = nil
            touchStartLocation = nil
            touchMoved = false
        }

        // MARK: - Two-finger pan = window/level (replaces macOS right-click-drag)

        @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let panel = panel else { return }

            switch recognizer.state {
            case .began:
                twoFingerPanLastLocation = recognizer.location(in: self)
                wlPendingDeltaWidth = 0
                wlPendingDeltaCenter = 0

            case .changed:
                guard let start = twoFingerPanLastLocation else { return }
                let current = recognizer.location(in: self)
                let dx = Double(current.x - start.x)
                let dy = Double(current.y - start.y)
                let currentWW = panel.windowWidth
                let dynamicFactor = max(0.1, currentWW / 500.0)
                let sensitivity: Double = 1.0 * dynamicFactor
                wlPendingDeltaWidth += dx * sensitivity
                wlPendingDeltaCenter += -dy * sensitivity
                flushPendingWindowLevelIfNeeded(force: false)
                twoFingerPanLastLocation = current

            case .ended, .cancelled, .failed:
                flushPendingWindowLevelIfNeeded(force: true)
                twoFingerPanLastLocation = nil

            default:
                break
            }
        }

        // MARK: - Pinch = zoom (replaces macOS scroll-wheel/Option-scroll zoom)

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let panel = panel else { return }

            switch recognizer.state {
            case .began:
                pinchStartScale = panel.scale

            case .changed:
                var newScale = pinchStartScale * recognizer.scale
                newScale = max(0.1, min(10.0, newScale))
                panel.scale = newScale
                restoreState()

            default:
                break
            }
        }

        // MARK: - Long-press = toggle group selection (replaces Shift+click)

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            guard let panel = panel, let model = model, model.panels.count > 1 else { return }
            DispatchQueue.main.async {
                panel.isGroupSelected.toggle()
            }
        }
    }
}

// MARK: - Panel Scroller Interaction View (iOS)
//
// iOS counterpart of MultiPanelContainer.swift's macOS-only PanelScrollerInteractionView.
// Same callback interface (onDrag/onHover/onEnter/onExit) and same coordinate convention
// (origin top-left, Y increasing downward -- UIKit's native coordinate space already matches
// this, unlike the macOS version which had to flip AppKit's Y-up window coordinates). Backs
// PanelDICOMScroller (MultiPanelContainer.swift), whose SwiftUI track/handle/thumbnail-popup
// body is reused completely unchanged.

struct PanelScrollerInteractionView: UIViewRepresentable {
    var onDrag: (CGPoint) -> Void
    var onHover: (CGPoint) -> Void
    var onEnter: () -> Void
    var onExit: () -> Void

    func makeUIView(context: Context) -> InteractionView {
        let v = InteractionView()
        v.onDrag = onDrag
        v.onHover = onHover
        v.onEnter = onEnter
        v.onExit = onExit
        return v
    }

    func updateUIView(_ uiView: InteractionView, context: Context) {
        uiView.onDrag = onDrag
        uiView.onHover = onHover
        uiView.onEnter = onEnter
        uiView.onExit = onExit
    }

    class InteractionView: UIView {
        var onDrag: ((CGPoint) -> Void)?
        var onHover: ((CGPoint) -> Void)?
        var onEnter: (() -> Void)?
        var onExit: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            addGestureRecognizer(pan)
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            addGestureRecognizer(pan)
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let loc = recognizer.location(in: self)
            switch recognizer.state {
            case .began:
                onEnter?()
                onHover?(loc)
                onDrag?(loc)
            case .changed:
                onHover?(loc)
                onDrag?(loc)
            case .ended, .cancelled, .failed:
                onExit?()
            default:
                break
            }
        }
    }
}
#endif
