import AppKit

/// Small HUD confirmation shown near the bottom of the screen.
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?
    /// Title of a visible progress toast (updated in place instead of re-showing).
    private static var progressTitle: NSTextField?

    static func show(_ message: String, detail: String? = nil) {
        guard Settings.showToasts else { return }
        present(message, detail: detail, persistent: false)
    }

    /// Sticky toast for long tasks (encoding, installing); stays until the next `show`/`progress` or `dismiss`.
    static func progress(_ message: String) {
        if let progressTitle, panel != nil {
            progressTitle.stringValue = message
            return
        }
        present(message, detail: nil, persistent: true)
    }

    static func dismiss() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
        progressTitle = nil
    }

    private static func present(_ message: String, detail: String?, persistent: Bool) {
        hideWork?.cancel()
        panel?.orderOut(nil)
        progressTitle = nil

        let title = NSTextField(labelWithString: message)
        title.font = persistent ? .monospacedDigitSystemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        if persistent {
            title.widthAnchor.constraint(equalToConstant: 300).isActive = true
            progressTitle = title
        }
        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        if let detail {
            let d = NSTextField(wrappingLabelWithString: detail)
            d.font = .systemFont(ofSize: 11)
            d.textColor = .secondaryLabelColor
            d.maximumNumberOfLines = 3
            d.preferredMaxLayoutWidth = 320
            stack.addArrangedSubview(d)
        }
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        let size = stack.fittingSize

        let p = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = effect
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            p.setFrameOrigin(CGPoint(x: vf.midX - size.width / 2, y: vf.minY + 60))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        panel = p

        guard !persistent else { return }
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) {
                p.orderOut(nil)
                if panel === p { panel = nil }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}
