import Testing
@testable import CSSensitive

/// Every format is pinned with a synthetic example built from parts (`Fake`), never a real key.
struct KeyAndTokenDetectionTests {
    func keys(_ line: String) -> [String] { foundText(line, .keysAndTokens) }

    /// A line, and the token the detector finds in it: nothing else in the line, of any kind.
    private static func row(_ before: String, _ token: String, _ after: String = "") -> (String, String) {
        (before + token + after, token)
    }

    // MARK: Service tokens and keys

    @Test(arguments: [
        // GitHub, every letter, a longer one found whole, and a fine-grained one.
        row("export GH=", Fake.github("p")),
        row("export GH=", Fake.github("o")),
        row("export GH=", Fake.github("u")),
        row("export GH=", Fake.github("s")),
        row("export GH=", Fake.github("r")),
        row("token ", Fake.github(body: 40), " end"),
        row("use ", Fake.githubFineGrained()),
        // AWS access key ids.
        row("id ", Fake.aws("AKIA")),
        row("id ", Fake.aws("ASIA")),
        // Stripe.
        row("STRIPE=", Fake.stripe("sk_live_")),
        row("STRIPE=", Fake.stripe("sk_test_")),
        row("STRIPE=", Fake.stripe("rk_live_")),
        // Slack, every letter.
        row("bot ", Fake.slack("a")),
        row("bot ", Fake.slack("b")),
        row("bot ", Fake.slack("p")),
        row("bot ", Fake.slack("r")),
        row("bot ", Fake.slack("s")),
        // Google.
        row("key=", Fake.google()),
        // Generic secret keys: with hyphens and underscores found whole, and of all lowercase letters.
        row("SERVICE=", Fake.secretKey()),
        row("key: ", parts("sk", "-", "proj", "-", Fake.chars(12), "_", Fake.chars(12), "-", Fake.chars(8)), " ok"),
        row("", parts("sk", "-", String(repeating: "a", count: 20))),
    ])
    func aServiceTokenIsFound(line: String, token: String) {
        #expect(found(line) == [Found(.keyOrToken, token)])
    }

    @Test(arguments: [
        // Too short, or the wrong prefix.
        Fake.github(body: 35),
        parts("gh", "x_", Fake.chars(36)),
        Fake.githubFineGrained(body: 21),
        Fake.aws(body: 15),
        Fake.aws(body: 17),
        parts("AKIA", Fake.chars(16).lowercased()),
        parts("AKIB", Fake.chars(16, from: Fake.capitals)),
        Fake.stripe(body: 15),
        parts("pk_live_", Fake.chars(24)),
        "xoxb-",
        parts("xoxz-", Fake.chars(24)),
        Fake.google(body: 34),
        parts("sk", "-", Fake.chars(19)),
        // Inside a longer word.
        parts("x", Fake.github()),
        parts("Pallbearer ", Fake.chars(24)),
        // Words that end in sk are not secret keys.
        "risk-assessment-for-the-next-quarter",
        "desk-lamp-with-adjustable-arm",
    ] as [String])
    func aLookalikeIsNotAToken(text: String) {
        #expect(found(text) == [])
    }

    // MARK: JWT

    @Test(arguments: [
        row("Authorization: Bearer ", Fake.jwt()),
        // A JWT wraps across lines when it's read from a screenshot, so a payload cut off by the line's end is a token.
        row("Authorization: Bearer ", parts(Fake.jwtHeader(), ".", Fake.jwtPayload(10))),
        row("jwt ", parts(Fake.jwtHeader(), ".eyJ")),
        // Without a signature.
        row("jwt ", parts(Fake.jwtHeader(), ".", Fake.jwtPayload()), " end"),
        row("jwt ", parts(Fake.jwtHeader(), ".", Fake.jwtPayload(), "."), " end"),
        // Signed: found whole with its signature.
        row("jwt ", parts(Fake.jwtHeader(), ".", Fake.jwtPayload(), ".", Fake.chars(43)), " end"),
    ])
    func aJWTIsFound(line: String, token: String) {
        #expect(found(line) == [Found(.keyOrToken, token)])
    }

    @Test func somethingThatIsNotAJWTIsNotFound() {
        #expect(keys("eyJ.eyJ.") == [])
        #expect(keys("ey" + "J" + "abc.eyJdef") == [])
        #expect(keys(Fake.jwtHeader()) == [])
        #expect(keys(Fake.jwtHeader() + "." + Fake.chars(24)) == [])
        #expect(keys("x" + Fake.jwtHeader() + "." + Fake.jwtPayload()) == [])
    }

    // MARK: Private-key blocks

    @Test(arguments: ["RSA", "", "OPENSSH", "EC", "ENCRYPTED", "DSA"])
    func aPrivateKeyBlockLineIsFound(kind: String) {
        let header = Fake.privateKeyBegin(kind)
        #expect(found(header) == [Found(.keyOrToken, header)])
    }

    @Test func aPGPPrivateKeyBlockLineIsFound() {
        let header = "-----" + "BEGIN PGP " + "PRIVATE KEY" + " BLOCK-----"
        #expect(found(header) == [Found(.keyOrToken, header)])
    }

    /// The words are what make it a private key's header; the dashes are optional, of any width and of any length.
    @Test(arguments: ["-----", "---", "--", "-", "", "——", "–––––", "—-–—-"])
    func aPrivateKeyHeaderIsFoundWhateverTheDashesAreOrAreNot(dashes: String) {
        let header = Fake.privateKeyBegin("OPENSSH", dashes: dashes)
        #expect(found("see " + header + " below") == [Found(.keyOrToken, header)])
    }

    @Test func aPrivateKeyHeaderWithOnlyOneEndOfDashesIsFound() {
        let leading = "-----" + "BEGIN RSA " + "PRIVATE" + " KEY"
        #expect(found(leading) == [Found(.keyOrToken, leading)])
        let trailing = "BEGIN RSA " + "PRIVATE" + " KEY" + "-----"
        #expect(found(trailing) == [Found(.keyOrToken, trailing)])
    }

    @Test(arguments: [
        parts("-----", "BEGIN CERTIFICATE-----"),
        parts("-----", "BEGIN PUBLIC", " KEY-----"),
        parts("-----", "END RSA ", "PRIVATE", " KEY-----"),
        parts("to begin ", "private", " key rotation"),
        parts("XBEGIN RSA ", "PRIVATE", " KEY"),
        parts("BEGINNING ", "PRIVATE", " KEY"),
        parts("BEGIN ", "PRIVATE"),
    ])
    func otherTextIsNotAPrivateKeyHeader(text: String) {
        #expect(keys(text) == [])
    }

    /// Only the header is a finding. The body is found by the scanner, with the predicates below, once it has a header.
    @Test func aBodyLineIsNotAFindingOnItsOwn() {
        #expect(found(Fake.privateKeyBody()) == [])
        #expect(found(Fake.privateKeyBody(70)) == [])
        #expect(found(Fake.privateKeyBody(20) + "==") == [])
        #expect(found(Fake.privateKeyEnd()) == [])
    }

    // MARK: Bearer tokens

    @Test func onlyTheTokenAfterBearerIsTheFinding() {
        let token = Fake.chars(24)
        #expect(found("Authorization: Bearer \(token)") == [Found(.keyOrToken, token)])
        #expect(found("authorization: bearer \(token) ok") == [Found(.keyOrToken, token)])
        #expect(found("-H 'Authorization: Bearer \(token)'") == [Found(.keyOrToken, token + "'")])
    }

    /// The token runs to the next space, whatever it holds: a token that stopped at a character it holds would leave the rest
    /// of it readable.
    @Test(arguments: ["abc!def@ghi#jkl$mno", "abcdefghij:klmnopqrstuvwxyz", "abcdefgh|ijklmnop;qrstuvwxyz", "abcdefghijklmnop%qrstuvwxyz", "abc,def,ghi,jkl,mno,pqr", "{abcdefghijklmnopqrstuvwxyz}", "abcdefghijklmnopq\"rstuv"])
    func aBearerTokenRunsToTheNextSpaceWhateverItHolds(token: String) {
        #expect(masked("Authorization: Bearer \(token) more") == "Authorization: Bearer ▓ more")
        #expect(masked("Authorization: Bearer \(token)") == "Authorization: Bearer ▓")
    }

    @Test func aBearerTokenMayHoldTheCharactersOAuthTokensUse() {
        let token = "abc.def_ghi~jkl+mno/pqr-stu=="
        #expect(found("Authorization: Bearer \(token)") == [Found(.keyOrToken, token)])
    }

    @Test(arguments: ["Bearer " + String(repeating: "a", count: 15), "the bearer of this letter", "Bearer tokens are sent", "Bearer", "Bearer  "])
    func somethingShortAfterBearerIsNotAToken(text: String) {
        #expect(found(text) == [])
    }

    // MARK: Passwords in URLs: only the password

    @Test func onlyThePasswordOfAURLIsTheFinding() {
        #expect(found("redis://:pw12@10.0.0.5") == [Found(.keyOrToken, "pw12"), Found(.ipAddress, "10.0.0.5")])
        #expect(found("postgres://admin:s3cret@db.example.com", .keysAndTokens) == [Found(.keyOrToken, "s3cret")])
        #expect(found("see postgres://admin:s3cret@db.example.com:5432/app?sslmode=require now", .keysAndTokens) == [Found(.keyOrToken, "s3cret")])
        #expect(found("HTTPS://user:p%40ss:word@example.com/x", .keysAndTokens) == [Found(.keyOrToken, "p%40ss:word")])
    }

    /// A password never hides an address: a password and a dotted host after it read as an address too, so with contact
    /// details on, the host is masked with the password.
    @Test func aPasswordAndTheHostAfterItReadAsAnAddress() {
        #expect(found("postgres://admin:s3cret@db.example.com", .contact) == [Found(.contact, "s3cret@db.example.com")])
        #expect(found("redis://:pw12@cache.example.com", .contact) == [Found(.contact, "pw12@cache.example.com")])
        #expect(found("postgres://admin:s3cret@db.example.com") == [Found(.keyOrToken, "s3cret@db.example.com")])
    }

    @Test func anEmailAddressAfterAColonInAURLPathIsStillOne() {
        #expect(found("see https://example.com/page:jane@example.test", .contact) == [Found(.contact, "jane@example.test")])
        #expect(found("mailto:jane@example.test", .contact) == [Found(.contact, "jane@example.test")])
    }

    @Test(arguments: [
        "http://example.com:8080/path",
        "ssh://git@example.com/repo.git",
        "redis://:@host.example.com",
        "https://example.com/a@b",
        "mailto:jane",
        "see http://[fd12::5]:8443/x",
    ])
    func aURLWithoutAPasswordHasNoFindingForOne(text: String) {
        #expect(found(text, .keysAndTokens) == [])
    }

    // MARK: Key file names

    @Test(arguments: [
        "AuthKey_AB12CD34EF.p8", "signing.p12", "identity.pfx", "server.pem", "SERVER.PEM", "my-cert.v2.pem",
        "server.key", "tls-private.KEY", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "ID_RSA",
    ])
    func aKeyFileNameIsFound(name: String) {
        #expect(found("upload \(name) first") == [Found(.keyOrToken, name)])
    }

    @Test func aKeyFileNameInAPathIsFoundWithoutTheDirectories() {
        #expect(keys("/etc/ssl/private/server.pem") == ["server.pem"])
        #expect(keys("Saved to server.pem.") == ["server.pem"])
        #expect(keys("ssh -i ~/.ssh/id_ed25519 host.example.com") == ["id_ed25519"])
        #expect(keys("cp id_rsa backup/id_rsa") == ["id_rsa", "id_rsa"])
    }

    /// A public key is no secret.
    @Test(arguments: ["id_rsa.pub", "id_dsa.pub", "id_ecdsa.pub", "id_ed25519.pub", "~/.ssh/id_rsa.pub"])
    func aPublicKeyFileIsNotAKeyFile(name: String) {
        #expect(keys("cat \(name)") == [])
    }

    @Test(arguments: [
        "notes.txt", "photo.png", "readme.pemx", "file.p80", "archive.p12x", ".pem", "p8", "the pem file",
        ".key", "the key file", "monkey", "keyboard.txt", "file.keyboard", "pid_rsa", "id_rsax", "id_ed25519x", "id_rsa2",
    ])
    func otherFileNamesAreNotKeyFiles(text: String) {
        #expect(keys(text) == [])
    }

    // MARK: Labelled secrets: only the value

    @Test(arguments: [
        "password: hunter2",
        "Password = hunter2",
        "passwd=hunter2",
        "PWD: hunter2",
        "secret: hunter2",
        "token = hunter2",
        "API_KEY=hunter2",
        "api-key: hunter2",
        "apikey=hunter2",
        "API key: hunter2",
        "GITHUB_TOKEN=hunter2",
        "client_secret: hunter2",
        "aws_secret_access_key = hunter2",
        "\"password\": \"hunter2\"",
        "password: 'hunter2'",
        "password: \"hunter2\"",
        "password => hunter2",
        "db.password=hunter2",
        "passphrase: hunter2",
        "ssh_passphrase=hunter2",
        "Passphrase = hunter2",
        "passwords: hunter2",
        "private_key = hunter2",
        "private-key: hunter2",
        "Private key: hunter2",
        "\"private_key\": \"hunter2\"",
    ])
    func onlyTheValueOfALabelledSecretIsTheFinding(line: String) {
        #expect(found(line) == [Found(.keyOrToken, "hunter2")])
    }

    @Test func aLongKeyValueIsTheFinding() {
        let value = "abc123" + Fake.chars(20)
        #expect(found("API_KEY=\(value)") == [Found(.keyOrToken, value)])
        #expect(found("token = \(value)") == [Found(.keyOrToken, value)])
    }

    @Test func aQuotedValueMayHoldSpaces() {
        #expect(found("password: \"correct horse battery\"") == [Found(.keyOrToken, "correct horse battery")])
    }

    @Test func anUnclosedQuoteStillMasksTheValue() {
        #expect(found("password: \"hunter2") == [Found(.keyOrToken, "hunter2")])
        #expect(found("set password: \"hunter2 and more") == [Found(.keyOrToken, "hunter2")])
    }

    @Test func aValueEndsAtASpaceAnAmpersandOrTrailingPunctuation() {
        #expect(found("use the password: hunter2 and more") == [Found(.keyOrToken, "hunter2")])
        #expect(found("https://example.com/reset?token=hunter2&next=/home") == [Found(.keyOrToken, "hunter2")])
        #expect(found("the password: hunter2, then") == [Found(.keyOrToken, "hunter2")])
        #expect(found("set token=hunter2.") == [Found(.keyOrToken, "hunter2")])
    }

    @Test func eachLabelledValueOnALineIsFound() {
        #expect(foundText("user: bob password: hunter2 token: hunter3") == ["hunter2", "hunter3"])
    }

    @Test(arguments: [
        "password",
        "my passwords are great",
        "password reset",
        "token == expected",
        "password:",
        "password: ",
        "password: ••••••••",
        "password: ********",
        "token: ab",
        "the secretary: Jane",
        "tokenizer: fast",
    ])
    func textWithoutALabelledValueIsNotFound(line: String) {
        #expect(found(line) == [])
    }
}
