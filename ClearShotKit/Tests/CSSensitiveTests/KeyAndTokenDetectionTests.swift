import Testing
@testable import CSSensitive

/// Every format is pinned with a synthetic example built from parts (`Fake`), never a real key.
struct KeyAndTokenDetectionTests {
    func keys(_ line: String) -> [String] { foundText(line, .keysAndTokens) }

    // MARK: GitHub

    @Test(arguments: ["p", "o", "u", "s", "r"] as [Character])
    func aGitHubTokenIsFound(letter: Character) {
        let token = Fake.github(letter)
        #expect(found("export GH=\(token)") == [Found(.keyOrToken, token)])
    }

    @Test func aLongerGitHubTokenIsFoundWhole() {
        let token = Fake.github(body: 40)
        #expect(keys("token \(token) end") == [token])
    }

    @Test func aFineGrainedGitHubTokenIsFound() {
        let token = Fake.githubFineGrained()
        #expect(keys("use \(token)") == [token])
    }

    @Test func aGitHubTokenTooShortIsNotFound() {
        #expect(keys(Fake.github(body: 35)) == [])
        #expect(keys("gh" + "x_" + Fake.chars(36)) == [])
        #expect(keys(Fake.githubFineGrained(body: 21)) == [])
    }

    @Test func aTokenInsideALongerWordIsNotFound() {
        #expect(keys("x" + Fake.github()) == [])
    }

    // MARK: AWS

    @Test(arguments: ["AKIA", "ASIA"])
    func anAWSAccessKeyIdIsFound(prefix: String) {
        let key = Fake.aws(prefix)
        #expect(found("id \(key)") == [Found(.keyOrToken, key)])
    }

    @Test func anAWSKeyOfTheWrongShapeIsNotFound() {
        #expect(keys(Fake.aws(body: 15)) == [])
        #expect(keys(Fake.aws(body: 17)) == [])
        #expect(keys("AKIA" + Fake.chars(16).lowercased()) == [])
        #expect(keys("AKIB" + Fake.chars(16, from: Fake.capitals)) == [])
    }

    // MARK: Stripe

    @Test(arguments: ["sk_live_", "sk_test_", "rk_live_"])
    func aStripeKeyIsFound(prefix: String) {
        let key = Fake.stripe(prefix)
        #expect(found("STRIPE=\(key)") == [Found(.keyOrToken, key)])
    }

    @Test func aStripeKeyTooShortIsNotFound() {
        #expect(keys(Fake.stripe(body: 15)) == [])
        #expect(keys("pk_live_" + Fake.chars(24)) == [])
    }

    // MARK: Slack

    @Test(arguments: ["a", "b", "p", "r", "s"] as [Character])
    func aSlackTokenIsFound(letter: Character) {
        let token = Fake.slack(letter)
        #expect(found("bot \(token)") == [Found(.keyOrToken, token)])
    }

    @Test func aSlackLookalikeIsNotFound() {
        #expect(keys("xoxb-") == [])
        #expect(keys("xoxz-" + Fake.chars(24)) == [])
    }

    // MARK: Google

    @Test func aGoogleKeyIsFound() {
        let key = Fake.google()
        #expect(found("key=\(key)") == [Found(.keyOrToken, key)])
    }

    @Test func aGoogleKeyTooShortIsNotFound() {
        #expect(keys(Fake.google(body: 34)) == [])
    }

    // MARK: JWT

    @Test func aJWTIsFound() {
        let jwt = Fake.jwt()
        #expect(found("Authorization: Bearer \(jwt)") == [Found(.keyOrToken, jwt)])
    }

    /// A JWT wraps across lines when it's read from a screenshot, so a payload cut off by the line's end is a token.
    @Test func aJWTCutOffInItsPayloadIsFound() {
        let cut = Fake.jwtHeader() + "." + Fake.jwtPayload(10)
        #expect(found("Authorization: Bearer \(cut)") == [Found(.keyOrToken, cut)])
        let barely = Fake.jwtHeader() + ".eyJ"
        #expect(keys("jwt \(barely)") == [barely])
    }

    @Test func aJWTWithoutASignatureIsFound() {
        let unsigned = Fake.jwtHeader() + "." + Fake.jwtPayload()
        #expect(keys("jwt \(unsigned) end") == [unsigned])
        #expect(keys("jwt \(unsigned). end") == [unsigned + "."])
    }

    @Test func aSignedJWTIsFoundWholeWithItsSignature() {
        let signed = Fake.jwtHeader() + "." + Fake.jwtPayload() + "." + Fake.chars(43)
        #expect(keys("jwt \(signed) end") == [signed])
    }

    @Test func somethingThatIsNotAJWTIsNotFound() {
        #expect(keys("eyJ.eyJ.") == [])
        #expect(keys("ey" + "J" + "abc.eyJdef") == [])
        #expect(keys(Fake.jwtHeader()) == [])
        #expect(keys(Fake.jwtHeader() + "." + Fake.chars(24)) == [])
        #expect(keys("x" + Fake.jwtHeader() + "." + Fake.jwtPayload()) == [])
    }

    // MARK: Generic secret keys

    @Test func aSecretKeyIsFound() {
        let key = Fake.secretKey()
        #expect(found("SERVICE=\(key)") == [Found(.keyOrToken, key)])
    }

    @Test func aSecretKeyWithHyphensAndUnderscoresIsFoundWhole() {
        let key = "sk" + "-" + "proj" + "-" + Fake.chars(12) + "_" + Fake.chars(12) + "-" + Fake.chars(8)
        #expect(keys("key: \(key) ok") == [key])
    }

    @Test func aSecretKeyOfAllLowercaseLettersIsFound() {
        let key = "sk" + "-" + String(repeating: "a", count: 20)
        #expect(keys(key) == [key])
    }

    @Test func aShortSecretKeyIsNotFound() {
        #expect(keys("sk" + "-" + Fake.chars(19)) == [])
    }

    @Test func wordsThatEndInSkAreNotSecretKeys() {
        #expect(keys("risk-assessment-for-the-next-quarter") == [])
        #expect(keys("desk-lamp-with-adjustable-arm") == [])
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

    @Test func aBearerTokenIsNotFoundInsideAWord() {
        #expect(found("Pallbearer " + Fake.chars(24)) == [])
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
