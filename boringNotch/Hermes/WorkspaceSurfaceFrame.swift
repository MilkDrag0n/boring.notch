import Foundation
import SwiftUI

/// All tabs use a single presentation rectangle inside a stable window viewport.
/// Its content proposal, clipping path, opaque background and shadow advance together.
struct WorkspaceSurfaceGeometry: Equatable {
    let visibleSize: CGSize
    let contentSize: CGSize
    let shadowPadding: CGFloat
    let minimumCanvasSize: CGSize

    static func preparedEnvelope(current: CGSize, target: CGSize, native: CGSize,
                                 shadowPadding: CGFloat) -> CGSize {
        // StandardAnimations.open has damping 0.8; 32 points also contains its maximum
        // overshoot across Hermes' supported widths. Retain larger previous bounds when reversing.
        let springRoom: CGFloat = 32
        return CGSize(width: max(native.width, current.width, target.width + springRoom),
                      height: max(native.height, current.height, target.height + shadowPadding + springRoom))
    }

    var canvasSize: CGSize {
        CGSize(width: max(minimumCanvasSize.width, visibleSize.width),
               height: max(minimumCanvasSize.height, visibleSize.height + shadowPadding))
    }
    var contentOrigin: CGPoint { CGPoint(x: (visibleSize.width - contentSize.width) / 2, y: 0) }
}

struct WorkspaceSurfaceFrame<WindowBridge: View>: ViewModifier {
    var presentationSize: CGSize
    let contentSize: CGSize
    let enabled: Bool
    let nativeWindowSize: CGSize
    let windowEnvelopeSize: CGSize
    let shadowPadding: CGFloat
    var topCornerRadius: CGFloat = 6
    var bottomCornerRadius: CGFloat = 14
    var shadowOpacity: CGFloat = 0
    @ViewBuilder var windowBridge: (CGSize) -> WindowBridge

    func body(content: Content) -> some View {
        let geometry = WorkspaceSurfaceGeometry(
            visibleSize: CGSize(width: max(1, presentationSize.width), height: max(1, presentationSize.height)),
            contentSize: contentSize, shadowPadding: shadowPadding, minimumCanvasSize: windowEnvelopeSize)
        Group {
            if enabled {
                WorkspaceSurfaceLayout(size: geometry.visibleSize, contentWidth: geometry.contentSize.width) {
                    content.animation(nil, value: geometry.contentSize.width)
                }
                    .geometryGroup()
                    .clipShape(NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius))
                    .background {
                        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
                            .fill(.black)
                            .shadow(color: .black.opacity(Double(max(0, min(1, shadowOpacity)))), radius: 6)
                    }
            } else {
                content
            }
        }
        // The representable keeps its identity. Production supplies the same prepared viewport
        // for every tab and closed state; no timed canvas release or second window animation.
        .background { windowBridge(enabled ? geometry.canvasSize : nativeWindowSize) }
    }
}

/// Interpolate layout proposals without rebuilding the modifier's content every frame.
/// Width stays at its destination while height follows the shell to keep footers visible.
private struct WorkspaceSurfaceLayout: Layout {
    var size: CGSize
    let contentWidth: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(size.width, size.height) }
        set { size = CGSize(width: newValue.first, height: newValue.second) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
            proposal: ProposedViewSize(width: contentWidth, height: bounds.height))
    }
}

struct WorkspaceClosedSizePreference: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct WorkspaceSurfaceAnimationKey: Equatable {
    let size: CGSize
    let open: Bool
    let shadow: Bool
}

struct WorkspaceSurfaceMeasurement: Equatable {
    enum Kind { case closed, compact, inactive }
    let kind: Kind
    let size: CGSize
}

struct WorkspaceSurfaceMeasurementPreference: PreferenceKey {
    static var defaultValue: WorkspaceSurfaceMeasurement { .init(kind: .inactive, size: .zero) }
    static func reduce(value: inout WorkspaceSurfaceMeasurement, nextValue: () -> WorkspaceSurfaceMeasurement) { value = nextValue() }
}
