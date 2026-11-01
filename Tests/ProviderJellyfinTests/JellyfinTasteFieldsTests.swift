import CoreModels
@testable import ProviderJellyfin
import XCTest

/// "Tonight" scans the whole movie catalogue with `.taste` detail. The grid
/// must stay lean; the scan needs synopsis, directors and ratings.
final class JellyfinTasteFieldsTests: XCTestCase {
    func testBrowseAndIdentityKeepTheLeanGridFields() {
        let lean = "PrimaryImageAspectRatio,ProviderIds,SortName,DateCreated,Genres"
        XCTAssertEqual(JellyfinProvider.listFields(for: .browse), lean)
        XCTAssertEqual(JellyfinProvider.listFields(for: .identity), lean)
    }

    func testTasteScanAddsSynopsisDirectorsAndRatings() {
        let fields = Set(JellyfinProvider.listFields(for: .taste).split(separator: ",").map(String.init))
        XCTAssertTrue(fields.isSuperset(of: ["Genres", "ProviderIds", "Overview", "People", "OfficialRating", "CommunityRating"]))
    }
}
