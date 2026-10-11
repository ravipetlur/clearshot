import Foundation
import Testing
import CSUpdate

/// What the app does with GitHub's answer: the HTTP status and the body in, a release, nothing to offer, or a failure out.
/// The endpoint's address is checked here too, since a bad repository name must never reach a URL.
struct FeedResultTests {
    let good = ReleaseFeedTests.release()

    // MARK: The status and the body

    @Test func aGoodReleaseWith200IsARelease() throws {
        let result = ReleaseFeed.result(status: 200, body: good)
        let info = try #require(ReleaseFeed.latest(from: good))
        #expect(result == .release(info))
    }

    /// Valid JSON that holds no release to install: a pre-release, a draft, an odd tag, no disk image.
    @Test func jsonThatHoldsNoInstallableReleaseIsNoRelease() {
        let cases: [Data] = [
            ReleaseFeedTests.release(prerelease: "true"),
            ReleaseFeedTests.release(draft: "true"),
            ReleaseFeedTests.release(tag: "v1.2.0-beta.1"),
            ReleaseFeedTests.release(assets: []),
            ReleaseFeedTests.release(assets: nil),
            Data("{}".utf8),
            Data(#"{"message": "something else"}"#.utf8),
        ]
        for body in cases {
            #expect(ReleaseFeed.result(status: 200, body: body) == .noRelease)
        }
    }

    /// A 200 that isn't JSON, or isn't an object (a captive portal's page, an empty body), is the server's fault.
    @Test func aBodyThatIsNotAJSONObjectIsAServerError() {
        let cases: [Data] = [
            Data(),
            Data("<html><body>Sign in to the network</body></html>".utf8),
            Data("[]".utf8),
            Data("42".utf8),
            Data("null".utf8),
            Data("{".utf8),
        ]
        for body in cases {
            #expect(ReleaseFeed.result(status: 200, body: body) == .failed(.serverError))
        }
    }

    /// The endpoint answers 404 when the repository has no release to call the latest.
    @Test func a404IsNoRelease() {
        #expect(ReleaseFeed.result(status: 404, body: Data(#"{"message":"Not Found"}"#.utf8)) == .noRelease)
        #expect(ReleaseFeed.result(status: 404, body: Data()) == .noRelease)
    }

    @Test func a403Or429IsRateLimiting() {
        for status in [403, 429] {
            #expect(ReleaseFeed.result(status: status, body: Data(#"{"message":"rate limit exceeded"}"#.utf8)) == .failed(.rateLimited))
            #expect(ReleaseFeed.result(status: status, body: Data()) == .failed(.rateLimited))
        }
    }

    @Test func a5xxIsAServerError() {
        for status in [500, 502, 503, 504, 599] {
            #expect(ReleaseFeed.result(status: status, body: Data()) == .failed(.serverError))
        }
    }

    @Test func anyOtherStatusIsAServerError() {
        for status in [0, 100, 201, 204, 301, 304, 400, 401, 410, 418, 451, 600] {
            #expect(ReleaseFeed.result(status: status, body: Data()) == .failed(.serverError), "\(status)")
        }
    }

    /// The status decides; a good-looking body under an error status is not read.
    @Test func theStatusWinsOverTheBody() {
        #expect(ReleaseFeed.result(status: 403, body: good) == .failed(.rateLimited))
        #expect(ReleaseFeed.result(status: 500, body: good) == .failed(.serverError))
        #expect(ReleaseFeed.result(status: 404, body: good) == .noRelease)
        #expect(ReleaseFeed.result(status: 304, body: good) == .failed(.serverError))
    }

    // MARK: The endpoint

    @Test func theEndpointIsTheLatestReleaseOfTheRepository() {
        #expect(ReleaseFeed.endpoint(repository: "owner/repo")
                == URL(string: "https://api.github.com/repos/owner/repo/releases/latest"))
    }

    @Test func dotsDashesUnderscoresAndDigitsAreAllowed() {
        #expect(ReleaseFeed.endpoint(repository: "My-Org_2/clear.shot-app_v2")
                == URL(string: "https://api.github.com/repos/My-Org_2/clear.shot-app_v2/releases/latest"))
    }

    @Test func aRepositoryThatIsNotOwnerSlashNameHasNoEndpoint() {
        let bad = [
            "", " ", "owner", "owner/", "/repo", "/", "a/b/c", "owner/repo/", "/owner/repo", " owner/repo", "owner/repo ",
            "owner /repo", "owner/re po", "owner/repo\n", "owner//repo",
            "../x", "owner/..", "owner/.", "./repo", "../..", "owner/../repo",
            "owner/repo?x=1", "owner/repo#frag", "owner/repo%2F..", "ow%6Eer/repo", "owner:pw@host/repo", "own@er/repo",
            "$(CLEARSHOT_UPDATE_REPO)", "${CLEARSHOT_UPDATE_REPO}", "https://github.com/owner/repo", "github.com/owner/repo",
            "ow\u{f1}er/repo", "owner/r\u{e9}po", "owner/repo\u{0}", "owner\\repo",
        ]
        for repository in bad {
            #expect(ReleaseFeed.endpoint(repository: repository) == nil, "\(repository.debugDescription)")
        }
    }
}
