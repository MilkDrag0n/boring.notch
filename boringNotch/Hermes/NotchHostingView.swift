import AppKit
import QuartzCore
import SwiftUI

/// Marks only the visible shell or an intentional native drag/chin target as interactive.
@MainActor protocol IslandInteractionRegionProviding: AnyObject {}

struct IslandInteractionRegionMarker: NSViewRepresentable {
    final class Marker: NSView, IslandInteractionRegionProviding {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Marker { Marker(frame: .zero) }
    func updateNSView(_ view: Marker, context: Context) {}
}

@MainActor protocol IslandViewportHosting: AnyObject {
    func setViewportSize(_ size: CGSize)
}

/// Keep the hosting view out of NSWindow's content-view slot. On macOS 27,
/// SwiftUI can still animate the containing window's size during a tab change
/// even when sizingOptions is empty. The plain container owns the window bounds;
/// its hosting child keeps a top-centered layout proposal independent of trimmed native bounds.
@MainActor
final class NotchHostingContainer<Content: View>: NSView, IslandViewportHosting {
    private var viewportSize: CGSize?
    let hostingView: NSHostingView<Content>

    init(rootView: Content) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = bounds
        addSubview(hostingView)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setViewportSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, viewportSize != size else { return }
        viewportSize = size
        hostingView.autoresizingMask = []
        positionHostingView()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if viewportSize != nil { positionHostingView() }
    }

    private func positionHostingView() {
        guard let size = viewportSize else { return }
        // Resize the OS window without changing SwiftUI's layout proposal or its screen anchor.
        hostingView.frame = NSRect(x: (bounds.width - size.width) / 2,
                                   y: bounds.height - size.height, width: size.width, height: size.height)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        var regions: [NSView] = []
        func collect(_ view: NSView) {
            guard !view.isHidden else { return }
            if view is IslandInteractionRegionProviding { regions.append(view) }
            view.subviews.forEach(collect)
        }
        collect(hostingView)
        // Generic harnesses/early unattached hosts have no shell yet. Once installed,
        // transparent viewport padding must not become a large mouse/drop target.
        if !regions.isEmpty {
            let local = convert(point, from: superview)
            guard regions.contains(where: { $0.bounds.contains($0.convert(local, from: self)) }) else { return nil }
        }
        return super.hitTest(point)
    }
}

@MainActor
func makeNotchHostingView<Content: View>(rootView: Content) -> NotchHostingContainer<Content> {
    NotchHostingContainer(rootView: rootView)
}

/// Only the transparent animation canvas stays large. The WindowServer rectangle fits the
/// actual surface once SwiftUI reports the entire spring removed; no timer guesses its duration.
@MainActor final class IslandWindowViewport {
    private var target: CGSize?
    private var viewport: CGSize = .zero
    private var ticket: UInt = 0
    private var settled = false
    private weak var window: NSWindow?
    private var pending: DispatchWorkItem?
    private var animationTrace: IslandAnimationTrace?

    func prepareInitial(_ target: CGSize) {
        // transaction(value:) only mutates a changed value. A cold closed launch has no
        // size transition, so establish its resting rectangle without waiting for one.
        guard self.target == nil else { return }
        let token = begin(target)
        complete(token)
    }
    func begin(_ target: CGSize) -> UInt {
        guard target.width.isFinite, target.height.isFinite, target.width > 0, target.height > 0 else { return ticket }
        if self.target != target {
            animationTrace?.finish(reason: "interrupted")
            animationTrace = nil
            if InteractionDiagnostics.enabled, let window {
                animationTrace = IslandAnimationTrace(window: window, target: target)
            }
            self.target = target
            ticket &+= 1
            settled = false
            schedule()
        }
        return ticket
    }
    func complete(_ token: UInt) {
        guard token == ticket, target != nil else { return }
        animationTrace?.finish(reason: "completed")
        animationTrace = nil
        settled = true
        schedule()
    }
    func attach(_ window: NSWindow, viewport: CGSize) {
        let changed = self.window !== window || self.viewport != viewport
        self.window = window
        self.viewport = viewport
        (window.contentView as? any IslandViewportHosting)?.setViewportSize(viewport)
        if changed { schedule() }
    }
    func detach(_ window: NSWindow?) {
        guard self.window === window else { return }
        animationTrace?.finish(reason: "detached")
        animationTrace = nil
        ticket &+= 1
        pending?.cancel(); pending = nil
        self.window = nil
    }
    private func schedule() {
        pending?.cancel()
        guard let window, let target, viewport.width > 0, viewport.height > 0 else { return }
        let expected = ticket
        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window, self.window === window, self.ticket == expected,
                  let screen = window.screen else { return }
            self.pending = nil
            let size = self.settled ? target : self.viewport
            let scale = max(1, screen.backingScaleFactor)
            func aligned(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
            let frame = NSRect(x: aligned(screen.frame.midX - size.width / 2),
                               y: aligned(screen.frame.maxY - size.height),
                               width: aligned(size.width), height: aligned(size.height))
            let current = window.frame
            if abs(current.minX - frame.minX) > 0.5 || abs(current.minY - frame.minY) > 0.5
                || abs(current.width - frame.width) > 0.5 || abs(current.height - frame.height) > 0.5 {
                let started = InteractionDiagnostics.enabled ? CACurrentMediaTime() : nil
                window.setFrame(frame, display: false)
                if let started {
                    self.animationTrace?.recordFrameWrite()
                    InteractionDiagnostics.record("animation", "native-frame", ["window": String(window.windowNumber),
                        "reason": self.settled ? "fitted" : "prepared",
                        "width": String(describing: frame.width), "height": String(describing: frame.height),
                        "durationMs": String((CACurrentMediaTime() - started) * 1_000)])
                }
            }
        }
        pending = work
        DispatchQueue.main.async(execute: work)
    }
}

/// Display callbacks measure main-thread scheduling during the spring, not GPU presentation.
/// Aggregate in memory and stop at completion; the existing bounded writer handles disk I/O.
@MainActor private final class IslandAnimationTrace: NSObject {
    private let windowNumber: Int
    private let started = CACurrentMediaTime()
    private var displayLink: CADisplayLink?
    private var previousCallback: CFTimeInterval?
    private var callbacks = 0
    private var lateCallbacks = 0
    private var maxGap: CFTimeInterval = 0
    private var frameWrites = 0

    init(window: NSWindow, target: CGSize) {
        windowNumber = window.windowNumber
        super.init()
        InteractionDiagnostics.record("animation", "started", ["window": String(windowNumber),
            "width": String(describing: target.width), "height": String(describing: target.height)])
        let link = window.displayLink(target: self, selector: #selector(sample(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func sample(_ link: CADisplayLink) {
        guard InteractionDiagnostics.enabled else { finish(reason: "disabled"); return }
        let now = CACurrentMediaTime()
        let gap = now - (previousCallback ?? started)
        let budget = link.targetTimestamp - link.timestamp
        callbacks += 1
        maxGap = max(maxGap, gap)
        if budget > 0, gap > budget * 1.5 {
            lateCallbacks += 1
            if lateCallbacks <= 8 {
                InteractionDiagnostics.record("animation", "late-callback", ["window": String(windowNumber),
                    "durationMs": String(gap * 1_000), "budgetMs": String(budget * 1_000),
                    "elapsedMs": String((now - started) * 1_000)])
            }
        }
        previousCallback = now
        if now - started > 3 { finish(reason: "timeout") }
    }

    func recordFrameWrite() {
        guard displayLink != nil else { return }
        frameWrites += 1
    }

    func finish(reason: String) {
        guard let link = displayLink else { return }
        link.invalidate()
        displayLink = nil
        InteractionDiagnostics.record("animation", "finished", ["window": String(windowNumber),
            "reason": reason, "durationMs": String((CACurrentMediaTime() - started) * 1_000),
            "callbacks": String(callbacks), "lateCallbacks": String(lateCallbacks),
            "maxGapMs": String(maxGap * 1_000), "frameWrites": String(frameWrites)])
    }
}

private struct IslandWindowViewportKey: EnvironmentKey {
    static let defaultValue: IslandWindowViewport? = nil
}
extension EnvironmentValues {
    var islandWindowViewport: IslandWindowViewport? {
        get { self[IslandWindowViewportKey.self] }
        set { self[IslandWindowViewportKey.self] = newValue }
    }
}

/// Outside the animatable shell so completion observes that shell's spring, rather than
/// a child transaction with no animations of its own.
private typealias IslandViewportState = SwiftUI.State<IslandWindowViewport>

struct IslandFittedWindow: ViewModifier {
    let size: CGSize
    var enabled = true
    @IslandViewportState private var viewport = IslandWindowViewport()
    func body(content: Content) -> some View {
        content
            .environment(\.islandWindowViewport, enabled ? viewport : nil)
            .onAppear { if enabled { viewport.prepareInitial(size) } }
            .transaction(value: size) { transaction in
                guard enabled else { return }
                let token = viewport.begin(size)
                transaction.addAnimationCompletion(criteria: .removed) { viewport.complete(token) }
            }
    }
}
