// WindowAccessor.swift
// OpenDicomViewer
//
// NSViewRepresentable that customizes the hosting NSWindow on appear:
// hides the titlebar, removes traffic light buttons, enables
// window dragging by background, and installs a key interceptor
// for IME-independent keyboard shortcuts.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import AppKit

/// NSView returned directly by WindowAccessor.makeNSView (see below for why).
/// Overrides performKeyEquivalent which fires BEFORE the Input Method (Korean/Japanese/Chinese IME)
/// processes the event. This is the only reliable way to handle single-letter shortcuts
/// when a CJK input method is active.
///
/// Not marked `private`: it's used as WindowAccessor's inferred NSViewRepresentable
/// `NSViewType` (the return type of makeNSView / parameter type of updateNSView),
/// and WindowAccessor itself is `internal`, so this needs to be at least as visible.
class KeyInterceptorView: NSView {
    weak var model: DICOMModel?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let model = model else { return super.performKeyEquivalent(with: event) }
        // Only handle unmodified keys
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { return super.performKeyEquivalent(with: event) }
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }

        switch key {
        case "1":
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.single) } }
            return true
        case "2":
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoHorizontal) } }
            return true
        case "3":
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoVertical) } }
            return true
        case "4":
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.quad) } }
            return true
        case "r": model.resetViewForPanel(model.activePanel); return true
        case "l": model.synchronizedScrolling.toggle(); return true
        case "x": model.showCrossReference.toggle(); return true
        case "t": model.showTags.toggle(); return true
        case "i": model.invertForPanel(model.activePanel); return true
        case "f": model.fitToWindowForPanel(model.activePanel); return true
        case "a":
            if let panel = model.activePanel { model.autoWindowLevelForPanel(panel) }
            return true
        case "o": model.activeTool = .roiWL; return true
        case "s": model.activeTool = .roiStats; return true
        case "d": model.activeTool = .ruler; return true
        case "n": model.activeTool = .angle; return true
        case "e": model.activeTool = .eraser; return true
        case "]", ".": model.rotateClockwiseForPanel(model.activePanel); return true
        case "[", ",": model.rotateCounterClockwiseForPanel(model.activePanel); return true
        case "w": model.activeTool = .windowLevel; return true
        case "v": model.activeTool = .select; return true
        case "p": model.activeTool = .pan; return true
        case "z": model.activeTool = .zoom; return true
        case "h": model.flipHorizontalForPanel(model.activePanel); return true
        case " ":
            if let panel = model.activePanel, panel.isMultiFrame && panel.numberOfFrames > 1 {
                model.toggleCinePlayback(panel); return true
            }
            return false
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let model: DICOMModel

    // The returned view IS the key interceptor (rather than a separate NSView
    // manually appended to window.contentView's subviews after the fact).
    // An earlier version created a plain NSView here and then reached out to
    // `window.contentView?.addSubview(interceptor)` to insert the interceptor
    // separately -- that triggers AppKit's runtime warning "Adding
    // 'KeyInterceptorView' as a subview of NSHostingController.view is not
    // supported and may result in a broken view hierarchy", because
    // window.contentView in a SwiftUI-hosted window is SwiftUI's own
    // NSHostingView, and inserting an extra subview into it directly conflicts
    // with SwiftUI's management of that hierarchy -- in practice this could
    // manifest as the window rendering with no visible content at all.
    // Returning the interceptor itself from makeNSView keeps it fully inside
    // the supported NSViewRepresentable path (SwiftUI embeds the returned view
    // for us, correctly, since WindowAccessor is placed via `.background(...)`
    // in ContentView.swift) while still getting a real NSView in the window's
    // key view loop for performKeyEquivalent to fire on.
    func makeNSView(context: Context) -> KeyInterceptorView {
        let view = KeyInterceptorView()
        view.model = model
        DispatchQueue.main.async {
            if let window = view.window {
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)

                // Hide Traffic Lights, but keep the zoom (green) button visible --
                // with titleVisibility = .hidden there's no title bar region left to
                // double-click for maximize/restore, so hiding all three buttons
                // left no way to grow the window beyond its initial size at all.
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true

                // Allow moving by dragging background
                window.isMovableByWindowBackground = true
            }
        }
        return view
    }

    func updateNSView(_ nsView: KeyInterceptorView, context: Context) {
        nsView.model = model
    }
}
