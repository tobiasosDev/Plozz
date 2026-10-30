#if canImport(SwiftUI)
import SwiftUI

private struct PlozzHiddenDestinationKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// The content is mounted but not on screen: an unselected tab the native
    /// sidebar keeps alive at zero opacity, or the page the custom rail keeps
    /// behind Live TV. Nothing anyone can see should animate there, since an
    /// endless animation keeps rendering every frame whether or not it shows.
    var plozzHiddenDestination: Bool {
        get { self[PlozzHiddenDestinationKey.self] }
        set { self[PlozzHiddenDestinationKey.self] = newValue }
    }
}
#endif
