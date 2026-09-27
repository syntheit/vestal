import Foundation
import VestalCore
import XCTest

final class FeedParserTests: XCTestCase {

    // MARK: Helpers

    private func item(id: String?, title: String?, url: String?, date: Int?, author: String?,
                      summary: String?) -> AnyJSON {
        func s(_ v: String?) -> AnyJSON { v.map(AnyJSON.string) ?? .null }
        return .object([
            "id": s(id), "title": s(title), "url": s(url),
            "date": date.map(AnyJSON.int) ?? .null, "author": s(author), "summary": s(summary),
        ])
    }

    private func items(_ feed: AnyJSON) -> [AnyJSON] {
        feed.objectValue?["items"]?.arrayValue ?? []
    }

    private func parse(_ text: String) throws -> AnyJSON {
        try FeedParser.parse(Data(text.utf8))
    }

    /// The `date` of the one item in an RSS feed with this `pubDate`.
    private func rssDate(_ pubDate: String) throws -> AnyJSON? {
        let feed = try parse("<rss version=\"2.0\"><channel><item><pubDate>\(pubDate)</pubDate></item></channel></rss>")
        return items(feed).first?.objectValue?["date"]
    }

    /// The `date` of the one entry in an Atom feed with this `updated`.
    private func atomDate(_ updated: String) throws -> AnyJSON? {
        let feed = try parse("<feed xmlns=\"http://www.w3.org/2005/Atom\"><entry><updated>\(updated)</updated></entry></feed>")
        return items(feed).first?.objectValue?["date"]
    }

    private func assertNotAFeed(_ text: String, _ fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(text), file: file, line: line) { error in
            let message = (error as? SourceError)?.description ?? ""
            XCTAssertTrue(message.hasPrefix("not a feed: "), message, file: file, line: line)
            XCTAssertTrue(message.contains(fragment), message, file: file, line: line)
        }
    }

    // MARK: RSS 2.0

    func testRSS2() throws {
        let feed = try FeedParser.parse(Fixture.data("feed/rss2.xml"))
        XCTAssertEqual(feed.objectValue?["title"], .string("Example News & Notes"))
        XCTAssertEqual(feed.objectValue?["url"], .string("https://example.com/"), "the RSS link, not atom:link")
        XCTAssertEqual(items(feed), [
            item(id: "tag:example.com,2026:parser", title: "Show HN: A <tiny> parser",
                 url: "https://example.com/posts/parser", date: 1031356801, author: "Ada Lovelace",
                 summary: "A parser in 200 lines. Tom & Jerry's \"favourite\" \u{2014} it\u{2019}s <fine>."),
            item(id: "https://example.com/posts/offset", title: "Offset date, escaped HTML",
                 url: "https://example.com/posts/offset", date: 1055235600, author: "editor@example.com (Editor)",
                 summary: "one two"),
            item(id: "https://example.com/posts/undated", title: "No date",
                 url: "https://example.com/posts/undated", date: nil, author: nil,
                 summary: "Only encoded content."),
            item(id: nil, title: nil, url: nil, date: 1704119400, author: nil,
                 summary: "Named zone EST, no title, no link."),
        ])
    }

    func testRSS1RDF() throws {
        let feed = try parse("""
            <?xml version="1.0"?>
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/"
                     xmlns:dc="http://purl.org/dc/elements/1.1/">
              <channel rdf:about="https://example.com/rdf"><title>RDF</title><link>https://example.com/</link></channel>
              <item rdf:about="https://example.com/1">
                <title>One</title><link>https://example.com/1</link>
                <dc:date>2002-09-07T00:00:01Z</dc:date><dc:creator>Someone</dc:creator>
                <description>Text.</description>
              </item>
            </rdf:RDF>
            """)
        XCTAssertEqual(feed, .object([
            "title": .string("RDF"),
            "url": .string("https://example.com/"),
            "items": .array([item(id: "https://example.com/1", title: "One", url: "https://example.com/1",
                                  date: 1031356801, author: "Someone", summary: "Text.")]),
        ]))
    }

    func testUndeclaredPrefixIsTolerated() throws {
        let feed = try parse("<rss><channel><item><dc:creator>Someone</dc:creator></item></channel></rss>")
        XCTAssertEqual(items(feed).first?.objectValue?["author"], .string("Someone"))
    }

    // MARK: Atom

    func testAtom() throws {
        let feed = try FeedParser.parse(Fixture.data("feed/atom.xml"))
        XCTAssertEqual(feed.objectValue?["title"], .string("Example Atom"))
        XCTAssertEqual(feed.objectValue?["url"], .string("https://example.org/"), "the rel-less link, not self")
        XCTAssertEqual(items(feed), [
            item(id: "urn:uuid:1225c695-cfb8-4ebb-aaaa-80da344efa6a", title: "Atom & XHTML",
                 url: "https://example.org/2026/09/xhtml", date: 1788370202, author: "Grace Hopper",
                 summary: "First paragraph. Second & last."),
            item(id: "tag:example.org,2026:published", title: "Published before updated",
                 url: "https://example.org/2026/08/published", date: 1785542400, author: "Feed Author",
                 summary: "An HTML summary."),
            item(id: "tag:example.org,2026:bare", title: nil, url: nil, date: 1782910800, author: "Feed Author",
                 summary: "Plain text summary."),
        ])
    }

    func testAtomWithPrefixedElements() throws {
        let feed = try parse("""
            <atom:feed xmlns:atom="http://www.w3.org/2005/Atom">
              <atom:title>Prefixed</atom:title>
              <atom:link rel="alternate" href="https://example.org/"/>
              <atom:entry>
                <atom:id>1</atom:id><atom:title>Entry</atom:title>
                <atom:link href="https://example.org/1"/>
                <atom:updated>2002-09-07T00:00:01Z</atom:updated>
                <atom:content type="html"><![CDATA[<b>Bold</b> move]]></atom:content>
              </atom:entry>
            </atom:feed>
            """)
        XCTAssertEqual(feed, .object([
            "title": .string("Prefixed"),
            "url": .string("https://example.org/"),
            "items": .array([item(id: "1", title: "Entry", url: "https://example.org/1", date: 1031356801,
                                  author: nil, summary: "Bold move")]),
        ]))
    }

    // MARK: JSON Feed

    func testJSONFeed() throws {
        let feed = try FeedParser.parse(Fixture.data("feed/jsonfeed.json"))
        XCTAssertEqual(feed.objectValue?["title"], .string("Example JSON Feed"))
        XCTAssertEqual(feed.objectValue?["url"], .string("https://example.net/"))
        XCTAssertEqual(items(feed), [
            item(id: "https://example.net/2026/first", title: "First post", url: "https://example.net/2026/first",
                 date: 1789917330, author: "Linus", summary: "Hello, world & friends."),
            item(id: "42", title: nil, url: "https://elsewhere.example/story", date: nil, author: "Feed Author",
                 summary: "Numeric id, no date, no title."),
            item(id: "modified-only", title: "Summary wins", url: nil, date: 1767323045, author: "One-point-oh",
                 summary: "The summary."),
        ])
    }

    func testJSONFeedWithoutItemsOrVersionThrows() {
        assertNotAFeed(#"{"name": "not a feed"}"#, "JSON Feed")
        assertNotAFeed(#"{"items": [}"#, "malformed JSON")
    }

    // MARK: Limits

    func testItemCap() throws {
        let entries = (1...600).map { "<item><guid>\($0)</guid></item>" }.joined()
        let rss = try parse("<rss version=\"2.0\"><channel><title>Many</title>\(entries)</channel></rss>")
        XCTAssertEqual(items(rss).count, FeedParser.maxItems)
        XCTAssertEqual(items(rss).first?.objectValue?["id"], .string("1"))
        XCTAssertEqual(items(rss).last?.objectValue?["id"], .string("500"))

        let json = "{\"version\": \"https://jsonfeed.org/version/1.1\", \"items\": ["
            + (1...600).map { "{\"id\": \($0)}" }.joined(separator: ",") + "]}"
        let jsonFeed = try parse(json)
        XCTAssertEqual(items(jsonFeed).count, 500)
        XCTAssertEqual(items(jsonFeed).last?.objectValue?["id"], .string("500"))
    }

    func testSummaryIsCut() throws {
        let long = String(repeating: "word ", count: 300)
        let feed = try parse("<rss><channel><item><description>&lt;p&gt;\(long)&lt;/p&gt;</description></item></channel></rss>")
        guard case .string(let summary)? = items(feed).first?.objectValue?["summary"] else {
            return XCTFail("no summary")
        }
        XCTAssertLessThanOrEqual(summary.count, FeedParser.maxSummary)
        XCTAssertGreaterThan(summary.count, 490)
        XCTAssertTrue(summary.hasSuffix("word…"), summary)
    }

    // MARK: Not a feed

    func testHTMLPageThrows() {
        assertNotAFeed("<!DOCTYPE html>\n<html><head><title>Hi</title></head><body><p>Hello<br></body></html>",
                       "HTML")
        assertNotAFeed("<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><body/></html>",
                       "root element is <html>")
    }

    func testOtherDocumentsThrow() {
        assertNotAFeed("", "empty")
        assertNotAFeed("  \n", "empty")
        assertNotAFeed("hello", "neither XML nor JSON")
        assertNotAFeed("<rss><channel><item></channel></rss>", "malformed XML")
        assertNotAFeed("<opml version=\"2.0\"><body/></opml>", "<opml>")
    }

    // MARK: Dates

    func testRFC822Dates() throws {
        let expected = AnyJSON.int(1031356801)  // 2002-09-07T00:00:01Z
        XCTAssertEqual(try rssDate("Sat, 07 Sep 2002 00:00:01 GMT"), expected)
        XCTAssertEqual(try rssDate("Sat, 7 Sep 2002 00:00:01 +0000"), expected)
        XCTAssertEqual(try rssDate("07 Sep 2002 00:00:01 UT"), expected, "no weekday")
        XCTAssertEqual(try rssDate("Sat, 07 Sep 02 00:00:01 Z"), expected, "two-digit year")
        XCTAssertEqual(try rssDate("Fri, 06 Sep 2002 20:00:01 EDT"), expected)
        XCTAssertEqual(try rssDate("Fri, 06 Sep 2002 16:00:01 PST"), expected)
        XCTAssertEqual(try rssDate("Sat, 07 Sep 2002 01:00:01 +01:00"), expected)
        XCTAssertEqual(try rssDate("Fri, 06 Sep 2002 18:30:01 -0530"), expected)
        XCTAssertEqual(try rssDate("Saturday, 07 September 2002 00:00:01 GMT"), expected, "full names")
        XCTAssertEqual(try rssDate("Sat, 07 Sep 2002 00:00:01 +0000 (UTC)"), expected, "comment")
        XCTAssertEqual(try rssDate("Sat, 07 Sep 2002 00:00:01"), expected, "no zone is UTC")
        XCTAssertEqual(try rssDate("Sat, 07 Sep 2002 00:00 GMT"), .int(1031356800), "no seconds")
        XCTAssertEqual(try rssDate("Mon, 01 Jan 99 12:00:00 GMT"), .int(915192000), "99 is 1999")
        XCTAssertEqual(try rssDate("2002-09-07T00:00:01Z"), expected, "RFC 3339 in pubDate")
        XCTAssertEqual(try rssDate("yesterday"), .null)
        XCTAssertEqual(try rssDate("Sat, 32 Sep 2002 00:00:01 GMT"), .null)
    }

    func testRFC3339Dates() throws {
        let expected = AnyJSON.int(1031356801)
        XCTAssertEqual(try atomDate("2002-09-07T00:00:01Z"), expected)
        XCTAssertEqual(try atomDate("2002-09-07T00:00:01.999Z"), expected, "fraction dropped")
        XCTAssertEqual(try atomDate("2002-09-07t02:00:01.5+02:00"), expected)
        XCTAssertEqual(try atomDate("2002-09-06T19:00:01-05:00"), expected)
        XCTAssertEqual(try atomDate("2002-09-07 00:00:01z"), expected)
        XCTAssertEqual(try atomDate("2002-09-07T00:00:01"), expected, "no zone is UTC")
        XCTAssertEqual(try atomDate("2002-09-07"), .int(1031356800), "bare date")
        XCTAssertEqual(try atomDate("2000-02-29T00:00:00Z"), .int(951782400), "leap day")
        XCTAssertEqual(try atomDate("  2002-09-07T00:00:01Z\n"), expected)
        XCTAssertEqual(try atomDate("07/09/2002"), .null)
        XCTAssertEqual(try atomDate("2002-13-07T00:00:01Z"), .null)
    }

    // MARK: Plain text

    func testPlainText() {
        XCTAssertEqual(FeedParser.plainText("<p>One</p><p>Two</p>"), "One Two")
        XCTAssertEqual(FeedParser.plainText("<b>bold</b>face"), "boldface")
        XCTAssertEqual(FeedParser.plainText("a<br/>b<br>c"), "a b c")
        XCTAssertEqual(FeedParser.plainText("&amp; &lt; &gt; &quot; &#39; &apos; &#65;&#x42;&#X43;"), "& < > \" ' ' ABC")
        XCTAssertEqual(FeedParser.plainText("a&nbsp;&nbsp;b\u{A0}c"), "a b c")
        XCTAssertEqual(FeedParser.plainText("AT&T &bogus; &#xZZ; & ;"), "AT&T &bogus; &#xZZ; & ;")
        XCTAssertEqual(FeedParser.plainText("1 < 2 and 3 > 2"), "1 < 2 and 3 > 2")
        XCTAssertEqual(FeedParser.plainText("x<!-- <p>hidden</p> -->y"), "xy")
        XCTAssertEqual(FeedParser.plainText("<style>p { color: red }</style><SCRIPT>if (a<b) {}</SCRIPT>Shown"), "Shown")
        XCTAssertEqual(FeedParser.plainText("<a href=\"x?a>b\" title='c>d'>link</a>"), "link")
        XCTAssertEqual(FeedParser.plainText("  \n\t lots \n\n of \t space  "), "lots of space")
        XCTAssertEqual(FeedParser.plainText("&lt;b&gt;not a tag&lt;/b&gt;"), "<b>not a tag</b>")
        XCTAssertEqual(FeedParser.plainText(""), "")
    }
}
