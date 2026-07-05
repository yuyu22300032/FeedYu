import XCTest
@testable import FeedYu

final class CSVParserTests: XCTestCase {
    func testSimpleRows() {
        let rows = CSVParser.parse("a,b,c\n1,2,3\n")
        XCTAssertEqual(rows, [["a", "b", "c"], ["1", "2", "3"]])
    }

    func testQuotedCommaAndEscapedQuote() {
        let rows = CSVParser.parse(#"name,note"# + "\n" + #""Bar, Baz","He said ""hi""""#)
        XCTAssertEqual(rows[1], ["Bar, Baz", #"He said "hi""#])
    }

    func testNewlineInsideQuotes() {
        let rows = CSVParser.parse("a,b\n\"line1\nline2\",x\n")
        XCTAssertEqual(rows[1], ["line1\nline2", "x"])
    }

    func testCRLF() {
        let rows = CSVParser.parse("a,b\r\n1,2\r\n")
        XCTAssertEqual(rows, [["a", "b"], ["1", "2"]])
    }

    func testParseRecords() {
        let records = CSVParser.parseRecords("Title,URL\nSushi Yu,https://example.com\n")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["Title"], "Sushi Yu")
        XCTAssertEqual(records[0]["URL"], "https://example.com")
    }
}
