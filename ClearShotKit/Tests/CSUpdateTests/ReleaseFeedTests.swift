import Foundation
import Testing
import CSUpdate

/// The feed's JSON has the shape GitHub's `releases/latest` answers with: the fields the updater reads, plus a few it
/// ignores, as the real answer has many more. The values are synthetic.
struct ReleaseFeedTests {
    static let downloads = "https://example.com/app/releases/download"

    /// One asset as the API lists it: the fields used plus extras (`digest`, `content_type`, a nested `uploader`).
    static func asset(_ name: String, size: Int = 3_763_969, tag: String = "v1.2.0", url: String? = nil, extra: String = "") -> String {
        """
        {
          "id": 4242, "name": "\(name)", "label": null, "state": "uploaded",
          "content_type": "application/octet-stream", "size": \(size),
          "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "uploader": { "login": "release-bot", "type": "Bot" },
          "browser_download_url": "\(url ?? "\(downloads)/\(tag)/\(name)")"\(extra)
        }
        """
    }

    /// The notes as a JSON string literal.
    static let notesJSON = ###""## What's new\n\n- Updates arrive in the app.\n""###

    static let goodDMG = asset("ClearShot-1.2.0.dmg")
    static let goodChecksum = asset("ClearShot-1.2.0.dmg.sha256", size: 86)

    /// A release as `releases/latest` returns it. `assets` are JSON snippets, joined into the array; the default is
    /// the two a good release has.
    static func release(
        tag: String? = "v1.2.0", draft: String? = "false", prerelease: String? = "false",
        body: String? = notesJSON,
        pageURL: String? = "https://example.com/app/releases/tag/v1.2.0",
        assets: [String]? = [goodDMG, goodChecksum]
    ) -> Data {
        var fields = [#""id": 1001"#, #""name": "ClearShot 1.2.0""#, #""immutable": true"#,
                      #""author": { "login": "release-bot", "id": 7 }"#,
                      #""published_at": "2026-10-09T08:00:00Z""#]
        if let tag { fields.append(#""tag_name": "\#(tag)""#) }
        if let draft { fields.append(#""draft": \#(draft)"#) }
        if let prerelease { fields.append(#""prerelease": \#(prerelease)"#) }
        if let body { fields.append(#""body": \#(body)"#) }
        if let pageURL { fields.append(#""html_url": "\#(pageURL)""#) }
        if let assets { fields.append(#""assets": [\#(assets.joined(separator: ","))]"#) }
        return Data("{\(fields.joined(separator: ",\n"))}".utf8)
    }

    // MARK: A good release

    @Test func decodesAGoodRelease() throws {
        let info = try #require(ReleaseFeed.latest(from: Self.release()))
        #expect(info.version == VersionNumber("1.2.0"))
        #expect(info.notes == "## What's new\n\n- Updates arrive in the app.\n")
        #expect(info.pageURL == URL(string: "https://example.com/app/releases/tag/v1.2.0"))
        #expect(info.dmg == ReleaseInfo.Asset(
            name: "ClearShot-1.2.0.dmg", size: 3_763_969,
            url: URL(string: "https://example.com/app/releases/download/v1.2.0/ClearShot-1.2.0.dmg")!))
        #expect(info.checksum == ReleaseInfo.Asset(
            name: "ClearShot-1.2.0.dmg.sha256", size: 86,
            url: URL(string: "https://example.com/app/releases/download/v1.2.0/ClearShot-1.2.0.dmg.sha256")!))
    }

    @Test func aTagWithoutTheLeadingVIsFine() throws {
        let info = try #require(ReleaseFeed.latest(from: Self.release(tag: "1.2.0")))
        #expect(info.version == VersionNumber("1.2.0"))
    }

    @Test func aNullBodyGivesEmptyNotes() throws {
        let info = try #require(ReleaseFeed.latest(from: Self.release(body: "null")))
        #expect(info.notes == "")
    }

    @Test func aMissingBodyGivesEmptyNotes() throws {
        let info = try #require(ReleaseFeed.latest(from: Self.release(body: nil)))
        #expect(info.notes == "")
    }

    @Test func notesKeepTheirMarkdownVerbatim() throws {
        let body = #""**Fixed**\r\n\r\n- A `crash`, see [notes](https://example.com/n)\r\né—""#
        let info = try #require(ReleaseFeed.latest(from: Self.release(body: body)))
        #expect(info.notes == "**Fixed**\r\n\r\n- A `crash`, see [notes](https://example.com/n)\r\n\u{e9}\u{2014}")
    }

    @Test func unknownTopLevelAndAssetFieldsAreIgnored() throws {
        let noisy = Self.asset("ClearShot-1.2.0.dmg", extra: #", "future_field": { "a": [1, 2, {"b": null}] }, "reactions": 3"#)
        let data = Self.release(assets: [noisy, Self.goodChecksum])
        #expect(ReleaseFeed.latest(from: data)?.dmg.name == "ClearShot-1.2.0.dmg")
    }

    @Test func theAssetsMayComeInAnyOrder() throws {
        let info = try #require(ReleaseFeed.latest(from: Self.release(assets: [Self.goodChecksum, Self.goodDMG])))
        #expect(info.dmg.name == "ClearShot-1.2.0.dmg")
        #expect(info.checksum.name == "ClearShot-1.2.0.dmg.sha256")
    }

    /// The release's `digest` field is optional: the `.sha256` asset is the checksum's source of truth.
    @Test func theDigestFieldIsNotNeeded() throws {
        let bare = #"{"name": "ClearShot-1.2.0.dmg", "size": 100, "browser_download_url": "https://example.com/a/ClearShot-1.2.0.dmg"}"#
        let bareSum = #"{"name": "ClearShot-1.2.0.dmg.sha256", "size": 86, "browser_download_url": "https://example.com/a/ClearShot-1.2.0.dmg.sha256"}"#
        #expect(ReleaseFeed.latest(from: Self.release(assets: [bare, bareSum])) != nil)
    }

    // MARK: Drafts and pre-releases

    @Test func aDraftGivesNothing() {
        #expect(ReleaseFeed.latest(from: Self.release(draft: "true")) == nil)
    }

    @Test func aPreReleaseGivesNothing() {
        #expect(ReleaseFeed.latest(from: Self.release(prerelease: "true")) == nil)
    }

    @Test func aDraftPreReleaseGivesNothing() {
        #expect(ReleaseFeed.latest(from: Self.release(draft: "true", prerelease: "true")) == nil)
    }

    /// The endpoint always sends both flags; a release that carries neither isn't marked as either.
    @Test func missingFlagsMeanNotMarked() {
        #expect(ReleaseFeed.latest(from: Self.release(draft: nil, prerelease: nil)) != nil)
    }

    @Test func flagsOfTheWrongTypeAreGarbage() {
        #expect(ReleaseFeed.latest(from: Self.release(draft: #""false""#)) == nil)
        #expect(ReleaseFeed.latest(from: Self.release(prerelease: "0")) == nil)
    }

    // MARK: The tag

    @Test(arguments: ["latest", "v1.2", "1.2", "v1.2.0.1", "1.2.0-beta.1", "v1.2.0-rc1", "v01.2.0", "V1.2.0", "", " v1.2.0", "release-1.2.0"])
    func aMalformedTagGivesNothing(tag: String) {
        #expect(ReleaseFeed.latest(from: Self.release(tag: tag)) == nil)
    }

    @Test func aMissingTagGivesNothing() {
        #expect(ReleaseFeed.latest(from: Self.release(tag: nil)) == nil)
    }

    // MARK: The assets

    @Test func assetsNamedForAnotherVersionThanTheTagGiveNothing() {
        let dmg = Self.asset("ClearShot-1.1.0.dmg", tag: "v1.1.0")
        let sum = Self.asset("ClearShot-1.1.0.dmg.sha256", size: 86, tag: "v1.1.0")
        #expect(ReleaseFeed.latest(from: Self.release(assets: [dmg, sum])) == nil)
    }

    @Test func aDMGOfAnotherVersionGivesNothing() {
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.asset("ClearShot-1.1.0.dmg"), Self.goodChecksum])) == nil)
    }

    @Test func aChecksumOfAnotherVersionGivesNothing() {
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodDMG, Self.asset("ClearShot-1.1.0.dmg.sha256", size: 86)])) == nil)
    }

    @Test func aMissingChecksumGivesNothing() {
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodDMG])) == nil)
    }

    @Test func aMissingDMGGivesNothing() {
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodChecksum])) == nil)
    }

    @Test func noAssetsGiveNothing() {
        #expect(ReleaseFeed.latest(from: Self.release(assets: [])) == nil)
        #expect(ReleaseFeed.latest(from: Self.release(assets: nil)) == nil)
        let nullAssets = #"{"tag_name": "v1.2.0", "draft": false, "prerelease": false, "html_url": "https://example.com/r", "assets": null}"#
        #expect(ReleaseFeed.latest(from: Data(nullAssets.utf8)) == nil)
    }

    @Test func extraAssetsAreIgnored() throws {
        let extras = [
            Self.asset("ClearShot-1.2.0.zip"), Self.asset("ClearShot-1.2.0.dmg.sig", size: 300),
            Self.asset("ClearShot-1.1.0.dmg", tag: "v1.1.0"), Self.asset("notes.txt", size: 12), Self.asset("Source code (zip)"),
        ]
        let info = try #require(ReleaseFeed.latest(from: Self.release(assets: extras + [Self.goodDMG] + [Self.goodChecksum])))
        #expect(info.dmg.name == "ClearShot-1.2.0.dmg")
        #expect(info.checksum.name == "ClearShot-1.2.0.dmg.sha256")
    }

    @Test func aDuplicatedDMGIsAmbiguous() {
        let again = Self.asset("ClearShot-1.2.0.dmg", size: 999, url: "https://example.com/mirror/ClearShot-1.2.0.dmg")
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodDMG, again, Self.goodChecksum])) == nil)
    }

    @Test func aDuplicatedChecksumIsAmbiguous() {
        let again = Self.asset("ClearShot-1.2.0.dmg.sha256", size: 86, url: "https://example.com/mirror/ClearShot-1.2.0.dmg.sha256")
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodDMG, Self.goodChecksum, again])) == nil)
    }

    /// Names are matched exactly: case, spacing, and any extra suffix all count.
    @Test(arguments: [
        "clearshot-1.2.0.dmg", "ClearShot-1.2.0.DMG", "ClearShot-1.2.0.dmg ", " ClearShot-1.2.0.dmg", "ClearShot 1.2.0.dmg",
        "ClearShot-v1.2.0.dmg", "ClearShot-1.2.dmg", "ClearShot-1.2.0.dmg.zip", "ClearShot-1.2.0-arm64.dmg", "Other-1.2.0.dmg",
    ])
    func aDMGNamedAnyOtherWayDoesNotCount(name: String) {
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.asset(name), Self.goodChecksum])) == nil)
    }

    @Test(arguments: [
        "clearshot-1.2.0.dmg.sha256", "ClearShot-1.2.0.dmg.SHA256", "ClearShot-1.2.0.dmg.sha256.txt",
        "ClearShot-1.2.0.sha256", "ClearShot-1.2.0.dmg.sha256 ", "ClearShot-1.2.0.dmg.sha512",
    ])
    func aChecksumNamedAnyOtherWayDoesNotCount(name: String) {
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodDMG, Self.asset(name, size: 86)])) == nil)
    }

    // MARK: Sizes and links

    @Test(arguments: ["0", "-5", "null", #""3763969""#, "1.5"])
    func aDMGWithoutAUsableSizeGivesNothing(size: String) {
        let dmg = #"{"name": "ClearShot-1.2.0.dmg", "size": \#(size), "browser_download_url": "https://example.com/a/ClearShot-1.2.0.dmg"}"#
        #expect(ReleaseFeed.latest(from: Self.release(assets: [dmg, Self.goodChecksum])) == nil)
    }

    @Test func aChecksumWithoutAUsableSizeGivesNothing() {
        let sum = #"{"name": "ClearShot-1.2.0.dmg.sha256", "size": 0, "browser_download_url": "https://example.com/a/ClearShot-1.2.0.dmg.sha256"}"#
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodDMG, sum])) == nil)
    }

    @Test func aWantedAssetWithoutASizeOrALinkGivesNothing() {
        let noSize = #"{"name": "ClearShot-1.2.0.dmg", "browser_download_url": "https://example.com/a/ClearShot-1.2.0.dmg"}"#
        let noLink = #"{"name": "ClearShot-1.2.0.dmg", "size": 100}"#
        #expect(ReleaseFeed.latest(from: Self.release(assets: [noSize, Self.goodChecksum])) == nil)
        #expect(ReleaseFeed.latest(from: Self.release(assets: [noLink, Self.goodChecksum])) == nil)
    }

    @Test(arguments: [
        "http://example.com/a/ClearShot-1.2.0.dmg", "file:///tmp/ClearShot-1.2.0.dmg", "ftp://example.com/ClearShot-1.2.0.dmg",
        "/relative/ClearShot-1.2.0.dmg", "ClearShot-1.2.0.dmg", "https:///ClearShot-1.2.0.dmg", "",
    ])
    func onlyHTTPSDownloadLinksCount(link: String) {
        let dmg = Self.asset("ClearShot-1.2.0.dmg", url: link)
        #expect(ReleaseFeed.latest(from: Self.release(assets: [dmg, Self.goodChecksum])) == nil)
        let sum = Self.asset("ClearShot-1.2.0.dmg.sha256", size: 86, url: link)
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodDMG, sum])) == nil)
    }

    @Test func aMissingOrNonHTTPSPageLinkGivesNothing() {
        #expect(ReleaseFeed.latest(from: Self.release(pageURL: nil)) == nil)
        #expect(ReleaseFeed.latest(from: Self.release(pageURL: "http://example.com/app/releases/tag/v1.2.0")) == nil)
        #expect(ReleaseFeed.latest(from: Self.release(pageURL: "")) == nil)
    }

    // MARK: Unrelated assets can't break the decoding

    @Test func malformedExtraAssetsAreIgnored() throws {
        let junk = ["null", "7", #""text""#, "[]", #"{"name": 5, "size": "x"}"#, #"{"size": 3}"#, "{}"]
        let info = try #require(ReleaseFeed.latest(from: Self.release(assets: junk + [Self.goodDMG, Self.goodChecksum])))
        #expect(info.dmg.name == "ClearShot-1.2.0.dmg")
    }

    /// A malformed copy of a wanted name still counts toward ambiguity: it isn't silently dropped in favour of the
    /// well-formed twin.
    @Test func aMalformedTwinOfTheDMGMakesItAmbiguous() {
        let twin = #"{"name": "ClearShot-1.2.0.dmg", "size": "big", "browser_download_url": "https://example.com/x"}"#
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodDMG, twin, Self.goodChecksum])) == nil)
    }

    // MARK: Garbage

    @Test(arguments: ["", "not json", "{", "[]", "null", "7", #""text""#, "{}", #"{"tag_name": 5}"#, #"{"tag_name": null}"#, "[{\"tag_name\": \"v1.2.0\"}]"])
    func garbageGivesNothing(text: String) {
        #expect(ReleaseFeed.latest(from: Data(text.utf8)) == nil)
    }

    @Test func aTruncatedReleaseGivesNothing() {
        let whole = Self.release()
        #expect(ReleaseFeed.latest(from: whole.prefix(whole.count / 2)) == nil)
    }

    @Test func binaryGarbageGivesNothing() {
        #expect(ReleaseFeed.latest(from: Data([0x00, 0xFF, 0xFE, 0x7B, 0x80])) == nil)
    }

    @Test func assetsThatAreNotAnArrayAreGarbage() {
        let data = Data(#"{"tag_name": "v1.2.0", "draft": false, "prerelease": false, "html_url": "https://example.com/r", "assets": {"name": "x"}}"#.utf8)
        #expect(ReleaseFeed.latest(from: data) == nil)
    }
}
