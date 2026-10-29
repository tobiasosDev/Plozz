import Foundation
import QuartzCore
import UIKit
#if canImport(notify)
import notify
#endif

/// Counts the on-screen layers whose cost lands on the render server, which the
/// Process Sample profile cannot see: live blurs and glass (backdrop layers),
/// masks, filters, path-less shadows, group opacity and rasterization each need
/// an offscreen pass, and their covered area is what an A10X pays for per frame.
///
/// A test runner in the same simulator posts `<bundle id>.LayerCensus.<label>`;
/// the fixture answers with `Library/Caches/Plozz/layer-census-<label>.json`.
/// The walk runs on the main thread, so never post it inside a timed window.
enum LayerCensus {
    static let labels = ["hero", "rows", "rows-deep", "detail"]
    private static var tokens: [Int32] = []

    static func install() {
        #if canImport(notify)
        let prefix = (Bundle.main.bundleIdentifier ?? "FocusHost") + ".LayerCensus."
        for label in labels {
            var token: Int32 = 0
            notify_register_dispatch(prefix + label, &token, .main) { _ in
                MainActor.assumeIsolated { write(label: label) }
            }
            tokens.append(token)
        }
        #endif
    }

    @MainActor
    static func write(label: String) {
        var census = Census()
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows where !window.isHidden {
                census.screen = window.bounds
                census.visit(window.layer, in: window.layer)
            }
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plozz", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let data = try? JSONSerialization.data(
            withJSONObject: census.summary(label: label), options: [.prettyPrinted, .sortedKeys]
        )
        try? data?.write(to: caches.appendingPathComponent("layer-census-\(label).json"))
    }

    private struct Census {
        var screen = CGRect.zero
        var layers = 0
        var counts: [String: Int] = [:]
        /// Covered area in screens (1.0 = the whole display) per offscreen kind.
        var area: [String: Double] = [:]
        var classes: [String: Int] = [:]

        mutating func visit(_ layer: CALayer, in root: CALayer) {
            guard !layer.isHidden, layer.opacity > 0.01 else { return }
            let frame = layer.convert(layer.bounds, to: root).intersection(screen)
            let onScreen = !frame.isNull && frame.width > 0.5 && frame.height > 0.5
            if onScreen {
                layers += 1
                let className = NSStringFromClass(type(of: layer))
                let notable = ["Backdrop", "Glass", "SDF", "Portal", "Metal", "AVPlayer", "Gradient", "Shape", "Replicator", "Emitter"]
                if notable.contains(where: className.contains) { classes[className, default: 0] += 1 }
                let share = Double(frame.width * frame.height / max(1, screen.width * screen.height))
                let hasSublayers = !(layer.sublayers ?? []).isEmpty
                func mark(_ kind: String, _ condition: Bool) {
                    guard condition else { return }
                    counts[kind, default: 0] += 1
                    area[kind, default: 0] += share
                }
                mark("backdrop", className.contains("Backdrop"))
                mark("mask", layer.mask != nil)
                mark("filter", !(layer.filters ?? []).isEmpty || layer.compositingFilter != nil
                    || !(layer.backgroundFilters ?? []).isEmpty)
                mark("shadowWithoutPath", layer.shadowOpacity > 0 && layer.shadowPath == nil)
                mark("groupOpacity", layer.opacity < 0.99 && layer.allowsGroupOpacity && hasSublayers)
                mark("rasterized", layer.shouldRasterize)
                mark("roundedClip", layer.masksToBounds && layer.cornerRadius > 0 && hasSublayers)
                mark("video", className.contains("AVPlayer") || className.contains("Metal"))
            }
            for sublayer in layer.sublayers ?? [] { visit(sublayer, in: root) }
        }

        func summary(label: String) -> [String: Any] {
            [
                "label": label, "layers": layers, "counts": counts,
                "screens": area.mapValues { ($0 * 100).rounded() / 100 }, "classes": classes,
            ]
        }
    }
}
