import Cocoa
import QuartzCore

private final class StartupOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum StartupAnimation {
    static func play(in window: NSWindow?) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window, !window.styleMask.contains(.fullScreen),
              let contentView = window.contentView,
              let image = NSImage(named: "MacflixDock"),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let mark = cgImage.cropping(to: CGRect(x: CGFloat(cgImage.width) / 5,
                                                y: CGFloat(cgImage.height) / 5,
                                                width: CGFloat(cgImage.width) * 3 / 5,
                                                height: CGFloat(cgImage.height) * 3 / 5)) else { return }

        let overlay = StartupOverlay(frame: contentView.bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.cgColor
        overlay.autoresizingMask = [.width, .height]

        let markLayer = CALayer()
        markLayer.contents = mark
        markLayer.contentsGravity = .resizeAspect
        markLayer.bounds = CGRect(x: 0, y: 0, width: 176, height: 176)
        markLayer.position = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY + 30)
        overlay.layer?.addSublayer(markLayer)

        let wordmark = CATextLayer()
        wordmark.string = "Macflix"
        wordmark.font = NSFont.systemFont(ofSize: 36, weight: .semibold)
        wordmark.fontSize = 36
        wordmark.alignmentMode = .center
        wordmark.foregroundColor = NSColor.white.cgColor
        wordmark.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        wordmark.bounds = CGRect(x: 0, y: 0, width: 320, height: 48)
        wordmark.position = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY - 126)
        overlay.layer?.addSublayer(wordmark)
        contentView.addSubview(overlay, positioned: .above, relativeTo: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let zoom = CABasicAnimation(keyPath: "transform.scale")
            zoom.fromValue = 1
            zoom.toValue = max(overlay.bounds.width, overlay.bounds.height) / 80
            zoom.duration = 0.95
            zoom.timingFunction = CAMediaTimingFunction(name: .easeIn)
            zoom.fillMode = .both
            zoom.isRemovedOnCompletion = false

            let wordmarkFade = CABasicAnimation(keyPath: "opacity")
            wordmarkFade.fromValue = 1
            wordmarkFade.toValue = 0
            wordmarkFade.duration = 0.45
            wordmarkFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            wordmarkFade.fillMode = .both
            wordmarkFade.isRemovedOnCompletion = false

            let overlayFade = CABasicAnimation(keyPath: "opacity")
            overlayFade.fromValue = 1
            overlayFade.toValue = 0
            overlayFade.beginTime = 0.75
            overlayFade.duration = 0.2
            overlayFade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            overlayFade.fillMode = .both
            overlayFade.isRemovedOnCompletion = false

            CATransaction.begin()
            CATransaction.setCompletionBlock { overlay.removeFromSuperview() }
            markLayer.add(zoom, forKey: "macflix-startup-zoom")
            wordmark.add(wordmarkFade, forKey: "macflix-startup-wordmark-fade")
            overlay.layer?.add(overlayFade, forKey: "macflix-startup-fade")
            CATransaction.commit()
        }
    }
}
