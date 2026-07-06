import XCTest
@testable import FeedYu

final class PlaceInfoParserTests: XCTestCase {
    func testParsesOGImageAndDescription() {
        // Synthetic head modeled on a guide.michelin.com restaurant page.
        let html = """
        <html><head>
        <meta property="og:title" content="Sample Place – a MICHELIN Guide Restaurant">
        <meta property="og:image" content="https://example.com/photos/cover.jpg">
        <meta name="description" content="MICHELIN Guide">
        <meta property="og:description" content="Chef Lin&#39;s tasting menu leans on coastal produce &amp; charcoal — a calm, seasonal room.">
        </head><body></body></html>
        """
        let info = PlaceInfoFetcher.parseInfo(fromHTML: html)
        XCTAssertEqual(info.imageURL?.absoluteString, "https://example.com/photos/cover.jpg")
        XCTAssertEqual(info.summary,
                       "Chef Lin's tasting menu leans on coastal produce & charcoal — a calm, seasonal room.")
    }

    func testReversedAttributeOrderAndSingleQuotes() {
        let html = """
        <meta content='https://example.com/p.png' property='og:image'>
        <meta content='★★★★☆ · $$ · Izakaya' name='description'>
        """
        let info = PlaceInfoFetcher.parseInfo(fromHTML: html)
        XCTAssertEqual(info.imageURL?.absoluteString, "https://example.com/p.png")
        XCTAssertEqual(info.summary, "★★★★☆ · $$ · Izakaya")
    }

    func testRejectsGenericGooglePlaceholderImages() {
        // Places with no photos get a static map / stock geocode card as
        // og:image — those must count as "no image".
        for generic in [
            "https://maps.googleapis.com/maps/api/staticmap?center=25.03,121.56&zoom=15",
            "https://www.gstatic.com/tactile/pane/default_geocode-2x.png",
        ] {
            let html = "<meta property=\"og:image\" content=\"\(generic)\">"
            XCTAssertNil(PlaceInfoFetcher.parseInfo(fromHTML: html).imageURL, generic)
        }
        let real = "<meta property=\"og:image\" content=\"https://lh5.googleusercontent.com/p/AF1Q=w900\">"
        XCTAssertNotNil(PlaceInfoFetcher.parseInfo(fromHTML: real).imageURL)
    }

    func testRejectsNonHTTPImageAndEmptyContent() {
        let html = """
        <meta property="og:image" content="data:image/png;base64,AAAA">
        <meta property="og:description" content="   ">
        """
        let info = PlaceInfoFetcher.parseInfo(fromHTML: html)
        XCTAssertNil(info.imageURL)
        XCTAssertNil(info.summary)
    }

    func testGarbageInputProducesEmptyInfo() {
        let info = PlaceInfoFetcher.parseInfo(fromHTML: ")]}'[[null,3,[1,2]]] not html at all {{{")
        XCTAssertNil(info.imageURL)
        XCTAssertNil(info.summary)
    }

    func testSummaryCappedAt500Characters() {
        let long = String(repeating: "a", count: 900)
        let html = "<meta property=\"og:description\" content=\"\(long)\">"
        XCTAssertEqual(PlaceInfoFetcher.parseInfo(fromHTML: html).summary?.count, 500)
    }
}
