import AppKit

/// The placement rectangle: a borderless, click-through window showing where
/// the focused window will land on release.
final class Overlay {
    private var window: NSWindow?
    private var view: NSView?

    /// On first appearance in a gesture, grows out of `startRect`.
    func show(axRect: CGRect, from startRect: CGRect? = nil) {
        let panel = ensureWindow()
        applyColor()

        let target = flipRect(axRect)
        if !panel.isVisible, let startRect {
            panel.setFrame(flipRect(startRect), display: false)
        }
        panel.orderFrontRegardless()

        let duration = Settings.shared.animationDuration
        if duration <= 0 {
            panel.setFrame(target, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func applyColor() {
        let color = Settings.shared.overlayColor
        view?.layer?.borderColor = color.cgColor
        view?.layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }

        let panel = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let content = NSView()
        content.wantsLayer = true
        content.layer?.borderWidth = 2.5
        content.layer?.cornerRadius = 10
        panel.contentView = content

        window = panel
        view = content
        return panel
    }
}
