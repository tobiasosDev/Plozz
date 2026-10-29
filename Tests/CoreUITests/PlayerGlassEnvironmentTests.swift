import CoreModels
import SwiftUI
import XCTest
@testable import CoreUI

@MainActor
final class PlayerGlassEnvironmentTests: XCTestCase {
    func testPlayerGlassAvailabilityPreservesTheCurrentScheme() {
        for scheme in [ColorScheme.light, .dark] {
            for reduced in [false, true] {
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                environment.plozzReduceTransparency = reduced
                if #available(iOS 26.0, tvOS 26.0, *) {
                    XCTAssertEqual(environment.playerUsesNativeGlass, !reduced)
                } else {
                    XCTAssertFalse(environment.playerUsesNativeGlass)
                }
                environment.plozzReducePanelGlass = true
                XCTAssertFalse(environment.playerUsesNativeGlass)
                XCTAssertEqual(environment.colorScheme, scheme)
            }
        }
    }

    func testExplicitPanelPreviewCannotOverrideReducedTransparency() {
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        environment.plozzReduceTransparency = true
        environment.plozzReducePanelGlass = false
        XCTAssertFalse(environment.playerUsesNativeGlass)
        XCTAssertEqual(environment.colorScheme, .light)
    }

    func testPanelsFollowTheResolvedProfileAndAccessibilityPreferenceWithoutAnotherGate() {
        for preference in TransparencyPreference.allCases {
            for systemReduced in [false, true] {
                var environment = EnvironmentValues()
                let expected = preference.reducesTransparency(systemReduceTransparency: systemReduced)
                environment.plozzReduceTransparency = expected
                XCTAssertEqual(environment.plozzReducePanelGlass, expected)
                environment.plozzReduceTransparency = !expected
                XCTAssertEqual(environment.plozzReducePanelGlass, !expected,
                               "Panels must read the live preference, not a copied launch-time value.")
            }
        }
    }

    func testPlayerGlassFollowsTheSystemExceptOnGlassLimitedAppleTVs() {
        for model in ["AppleTV6,2", "AppleTV5,3"] {
            XCTAssertTrue(TransparencyPreference.system.reducesPlayerGlass(
                systemReduceTransparency: false, modelIdentifier: model
            ))
            XCTAssertFalse(TransparencyPreference.on.reducesPlayerGlass(
                systemReduceTransparency: true, modelIdentifier: model
            ), "An explicit choice keeps the glass.")
            XCTAssertTrue(TransparencyPreference.off.reducesPlayerGlass(
                systemReduceTransparency: false, modelIdentifier: model
            ))
        }
        for model in ["AppleTV11,1", "AppleTV14,1", "iPad16,3", ""] {
            for preference in TransparencyPreference.allCases {
                for systemReduced in [false, true] {
                    XCTAssertEqual(
                        preference.reducesPlayerGlass(systemReduceTransparency: systemReduced, modelIdentifier: model),
                        preference.reducesTransparency(systemReduceTransparency: systemReduced)
                    )
                }
            }
        }

        var environment = EnvironmentValues()
        environment.plozzReduceTransparency = false
        XCTAssertFalse(environment.plozzReducePlayerGlass, "Without a root value the player follows its panels.")
        environment.plozzReducePlayerGlass = true
        environment.plozzReducePanelGlass = environment.plozzReducePlayerGlass
        XCTAssertFalse(environment.playerUsesNativeGlass)
        XCTAssertFalse(environment.plozzReduceTransparency, "Glass outside the player is unaffected.")
    }

    func testMaterialPreviewsCanStillSelectEachActualSurfaceExplicitly() {
        var environment = EnvironmentValues()
        environment.plozzReducePanelGlass = true
        XCTAssertTrue(environment.plozzReducePanelGlass)
        environment.plozzReducePanelGlass = false
        XCTAssertFalse(environment.plozzReducePanelGlass)
    }
}
