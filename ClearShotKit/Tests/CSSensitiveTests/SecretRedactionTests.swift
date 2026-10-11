import Foundation
import Testing
@testable import CSSensitive

/// Incomplete redaction: a mask that leaves part of a secret readable. Each test compares what is left readable, with every
/// finding masked as one `▓`, to the line with its whole secret replaced by `▓`, so it fails if any part of the secret stays
/// outside a finding, and if a finding takes in more than the secret.
struct SecretRedactionTests {
    // MARK: A password in a URL with an @ in it

    @Test func aURLPasswordWithAnAtSignIsMaskedWhole() {
        #expect(masked("postgres://admin:P@ssw0rd!@db.example.com", .keysAndTokens) == "postgres://admin:▓@db.example.com")
        #expect(found("postgres://admin:P@ssw0rd!@db.example.com", .keysAndTokens) == [Found(.keyOrToken, "P@ssw0rd!")])
        #expect(masked("mongodb://user:p@ss:w@rd@host.example.com", .keysAndTokens) == "mongodb://user:▓@host.example.com")
        #expect(found("mongodb://user:p@ss:w@rd@host.example.com", .keysAndTokens) == [Found(.keyOrToken, "p@ss:w@rd")])
        #expect(readable("P@ssw0rd!", in: "postgres://admin:P@ssw0rd!@db.example.com") == "")
        #expect(readable("p@ss:w@rd", in: "mongodb://user:p@ss:w@rd@host.example.com") == "")
    }

    @Test func aURLPasswordEndsAtTheLastAtSignBeforeASlashOrASpace() {
        #expect(masked("DATABASE_URL=postgres://admin:P@ssw0rd@db.example.com:5432/app", .keysAndTokens) == "DATABASE_URL=postgres://admin:▓@db.example.com:5432/app")
        #expect(masked("connect postgres://admin:P@ssw0rd@db.example.com now, or me@example.test", .keysAndTokens) == "connect postgres://admin:▓@db.example.com now, or me@example.test")
        #expect(readable("me@example.test", in: "connect postgres://admin:P@ssw0rd@db.example.com now, or me@example.test") == "")
        #expect(masked("redis://:ab+cd==@cache.example.test", .keysAndTokens) == "redis://:▓@cache.example.test")
    }

    /// A password never hides an address: what ends at the host reads as an address too, so with contact details on, the
    /// host is masked with the password (more than the secret, nothing of it left).
    @Test func theTailOfAPasswordAndTheHostReadAsAnAddress() {
        #expect(found("postgres://admin:P@ssw0rd!@db.example.com", .contact).map(\.text) == ["ssw0rd!@db.example.com"])
        #expect(found("postgres://admin:P@ssw0rd!@db.example.com") == [Found(.keyOrToken, "P@ssw0rd!@db.example.com")])
    }

    // MARK: A URL password with a slash in it

    /// A generated password often holds `/` (and `+`): it runs from the colon after the user to the last `@` before a space,
    /// and a slash doesn't end it. Each case is the line, its password, and the line as it is left on screen.
    @Test(arguments: [
        ("postgres://app:Xy/9kQ+abc@db:5432/app", "Xy/9kQ+abc", "postgres://app:▓@db:5432/app"),
        ("https://user:ab/cd/ef@host", "ab/cd/ef", "https://user:▓@host"),
        ("DATABASE_URL=postgres://app:Xy/9kQ+abc@db", "Xy/9kQ+abc", "DATABASE_URL=postgres://app:▓@db"),
        ("DATABASE_URL=postgres://app:Xy/9kQ+abc@db:5432/app", "Xy/9kQ+abc", "DATABASE_URL=postgres://app:▓@db:5432/app"),
        ("mongodb://:/a/b/@cache.example.test/0", "/a/b/", "mongodb://:▓@cache.example.test/0"),
        ("redis://:q/@cache", "q/", "redis://:▓@cache"),
        ("https://user:a/b#c?d@host/p", "a/b#c?d", "https://user:▓@host/p"),
        ("see \"amqp://guest:q/W+e/r=@rabbit:5672\" now", "q/W+e/r=", "see \"amqp://guest:▓@rabbit:5672\" now"),
        ("smtp://jane@example.com:mail/pass@localhost", "mail/pass", "smtp://jane@example.com:▓@localhost"),
        ("mongodb://user:p@ss/w@rd@host.example.com", "p@ss/w@rd", "mongodb://user:▓@host.example.com"),
    ])
    func aURLPasswordWithASlashIsMaskedWhole(line: String, password: String, left: String) {
        #expect(masked(line, .keysAndTokens) == left)
        #expect(found(line, .keysAndTokens) == [Found(.keyOrToken, password)])
        #expect(readable(password, in: line, .keysAndTokens) == "")
        #expect(readable(password, in: line) == "", "\(masked(line))")
    }

    /// A password that ends in `@`, or holds a `#` or a `?` or a `:`, is read up to the last `@` like any other.
    @Test(arguments: [
        ("https://user:pw@@host", "pw@"),
        ("https://user:a/b@@host/x", "a/b@"),
        ("https://user:p#w?x:y/z@host", "p#w?x:y/z"),
        ("redis://:/#?@cache:6379/0", "/#?"),
    ])
    func aURLPasswordWithAnAtSignOrPunctuationAtItsEndIsMaskedWhole(line: String, password: String) {
        #expect(found(line, .keysAndTokens) == [Found(.keyOrToken, password)])
        #expect(readable(password, in: line, .keysAndTokens) == "")
        #expect(readable(password, in: line) == "", "\(masked(line))")
    }

    /// An `@` later on the line, in a path, ends the password there: the mask covers more than the secret (accepted), and
    /// none of it is left.
    @Test func anAtSignInAPathAfterAURLPasswordIsTakenIntoItsMask() {
        let line = "https://user:pw@host/a@b"
        #expect(found(line, .keysAndTokens) == [Found(.keyOrToken, "pw@host/a")])
        #expect(readable("pw", in: line, .keysAndTokens) == "")
        let slash = "https://user:Xy/9kQ@host/dir/file@2x.png"
        #expect(readable("Xy/9kQ", in: slash, .keysAndTokens) == "")
        #expect(found(slash, .keysAndTokens) == [Found(.keyOrToken, "Xy/9kQ@host/dir/file")])
    }

    /// Two URLs with passwords in one run of text, with no space between: neither password is left.
    @Test func twoURLsWithPasswordsWithoutASpaceBetweenThemAreBothMasked() {
        let line = "https://u:pw/1@h.test/a,https://v:qq/2@h2.test/b"
        #expect(readable("pw/1", in: line, .keysAndTokens) == "")
        #expect(readable("qq/2", in: line, .keysAndTokens) == "")
        #expect(readable("pw/1", in: line) == "")
        #expect(readable("qq/2", in: line) == "")
    }

    /// A space ends the password's run: the next URL after it is read on its own.
    @Test func eachURLAfterASpaceHasItsOwnPassword() {
        let line = "x://a:b/c@d.test x://e:f/g@h.test me@example.test"
        #expect(found(line, .keysAndTokens) == [Found(.keyOrToken, "b/c"), Found(.keyOrToken, "f/g")])
        #expect(masked(line, .keysAndTokens) == "x://a:▓@d.test x://e:▓@h.test me@example.test")
    }

    /// A password never hides an address, a slash or not.
    @Test func anAddressAfterAURLPasswordWithASlashIsMasked() {
        let line = "https://admin:s3/cret@api.example.com?notify=jane@example.com"
        #expect(readable("s3/cret", in: line, .keysAndTokens) == "")
        #expect(readable("s3/cret", in: line) == "")
        #expect(readable("jane@example.com", in: line, .contact) == "", "\(masked(line, .contact))")
        #expect(readable("jane@example.com", in: line) == "", "\(masked(line))")
    }

    /// A URL with no password has no finding for one, and nor does a host and a port that has no scheme in front of it,
    /// whatever follows the port.
    @Test(arguments: [
        "https://example.com/a@b",
        "https://example.com/a/b/c@d/e",
        "https://example.com/a:b/c@d",
        "ssh://git@github.test/org/repo",
        "example.com:8080/path@x",
        "localhost:3000/cb?next=/x@y",
        "redis://:/cache",
        "redis://:@cache",
        "see https://example.com/a@b and then x://a:",
    ])
    func noPasswordIsFoundWhereThereIsNone(line: String) {
        #expect(found(line, .keysAndTokens) == [])
    }

    // MARK: A URL password and an address never hide each other

    /// A password that starts with digits and then `?` or `#` is a password, not a port (round 2 masked these whole).
    @Test(arguments: [
        ("redis://:2024#Winter@cache:6379/0", "2024#Winter"),
        ("mysql://root:9#xY7!q@localhost", "9#xY7!q"),
        ("DATABASE_URL=postgres://app:123?abc@postgres:5432/app", "123?abc"),
        ("amqp://guest:1234#@rabbit:5672", "1234#"),
    ])
    func aPasswordThatStartsLikeAPortIsMaskedWhole(line: String, password: String) {
        #expect(found(line, .keysAndTokens) == [Found(.keyOrToken, password)])
        #expect(readable(password, in: line, .keysAndTokens) == "", "\(masked(line, .keysAndTokens))")
        #expect(readable(password, in: line) == "", "\(masked(line))")
    }

    @Test func aPasswordWithADottedHostThatStartsLikeAPortIsMaskedWhole() {
        let line = "postgres://admin:2024#Winter@db.example.com/app"
        #expect(readable("2024#Winter", in: line, .keysAndTokens) == "")
        #expect(readable("2024#Winter", in: line) == "")
    }

    @Test func anAddressAfterAPortIsMaskedWholeWithContactDetailsAlone() {
        let line = "http://localhost:3000?email=jane@example.com"
        #expect(readable("jane@example.com", in: line, .contact) == "", "\(masked(line, .contact))")
        #expect(readable("jane@example.com", in: line) == "", "\(masked(line))")
    }

    @Test func aPasswordAndAnAddressInTheQueryAfterItAreBothMasked() {
        let line = "https://admin:s3cret@api.example.com?notify=jane@example.com"
        #expect(readable("jane@example.com", in: line, .contact) == "", "\(masked(line, .contact))")
        #expect(readable("s3cret", in: line, .keysAndTokens) == "", "\(masked(line, .keysAndTokens))")
        #expect(readable("s3cret", in: line) == "", "\(masked(line))")
        #expect(readable("jane@example.com", in: line) == "", "\(masked(line))")
    }

    @Test func anAddressForAUserNameAndThePasswordAfterItAreBothMasked() {
        let line = "smtp://jane@example.com:mailpass@localhost"
        #expect(readable("mailpass", in: line, .keysAndTokens) == "")
        #expect(readable("mailpass", in: line) == "")
        #expect(readable("jane@example.com", in: line) == "")
    }

    // MARK: A value with an & in it

    @Test func anAmpersandInAnUnquotedValueIsPartOfTheValue() {
        #expect(masked("set password: Tr0ub4dor&3 now") == "set password: ▓ now")
        #expect(masked("set password: P&ssw0rd now") == "set password: ▓ now")
        #expect(masked("set token=a&b&c now") == "set token=▓ now")
    }

    @Test func anAmpersandAtTheStartOfALineValueIsPartOfTheValue() {
        #expect(masked("password: Tr0ub4dor&3") == "password: ▓")
        #expect(masked("password: P&ssw0rd") == "password: ▓")
    }

    @Test func anAmpersandThatStartsAQueryFieldEndsTheValue() {
        #expect(masked("curl -d password=abc&user=bob now") == "curl -d password=▓&user=bob now")
        #expect(masked("x password=Pq9&ssw0rd=y z") == "x password=▓&ssw0rd=y z")
    }

    @Test func inAQueryStringTheAmpersandEndsTheValue() {
        #expect(masked("https://example.com/r?token=hunter2&next=/home") == "https://example.com/r?token=▓&next=/home")
        #expect(masked("https://example.com/r?a=1&password=abc&cd&x=1") == "https://example.com/r?a=1&password=▓&cd&x=1")
        #expect(masked("https://example.com/r?client_secret=abcd&ef") == "https://example.com/r?client_secret=▓&ef")
    }

    // MARK: A value of several words

    @Test func aPassphraseRunsToTheEndOfTheLine() {
        #expect(masked("passphrase: correct horse battery staple") == "passphrase: ▓")
        #expect(masked("ssh_passphrase = correct horse battery staple") == "ssh_passphrase = ▓")
        #expect(found("passphrase: correct horse battery staple") == [Found(.keyOrToken, "correct horse battery staple")])
    }

    @Test func aPassphraseRunsToTheEndOfTheLineWhereverTheLabelIs() {
        #expect(masked("my passphrase: correct horse battery staple") == "my passphrase: ▓")
        #expect(masked("enter passphrase=correct horse battery staple.") == "enter passphrase=▓")
    }

    /// A line, and the secret in it that is masked whole.
    struct Case: CustomTestStringConvertible {
        let line: String, secret: String
        init(_ line: String, _ secret: String = "my secret pass") { self.line = line; self.secret = secret }
        var testDescription: String { line }
    }

    @Test(arguments: [
        Case("password: my secret pass"),
        Case("  password: my secret pass"),
        Case("\"password\": my secret pass"),
        Case("'password': my secret pass"),
        Case("export DB_PASSWORD=my secret pass"),
        Case("  export  DB_PASSWORD = my secret pass"),
        Case("Password: Must be 8 characters", "Must be 8 characters"),
        Case("token = my secret pass"),
        Case("api_key: my secret pass"),
    ])
    func aLabelAtTheStartOfALineHasTheRestOfTheLineForItsValue(example: Case) {
        #expect(masked(example.line) == example.line.replacingOccurrences(of: example.secret, with: "▓"))
    }

    @Test func aLabelElsewhereHasTheFirstWordForItsValue() {
        #expect(masked("use the password: swordfish rain man") == "use the password: ▓ rain man")
        #expect(masked("a b DB_PASSWORD=swordfish rain man") == "a b DB_PASSWORD=▓ rain man")
        #expect(masked("{\"password\": swordfish rain man}") == "{\"password\": ▓ rain man}")
    }

    @Test func aLineValueLosesItsTrailingSpaces() {
        #expect(masked("password: my secret pass   ") == "password: ▓   ")
    }

    @Test func aLineValueOfMaskCharactersIsNotASecret() {
        #expect(found("password: •••••••• Show") == [])
        #expect(found("password: ******** (hidden)") == [])
    }

    @Test func aLineValueIsMaskedForItsFirst1024Characters() throws {
        let value = String(repeating: "word ", count: 400)
        let line = "password: " + value
        let finding = try #require(SensitiveDetector.findings(in: line, kinds: .all).first)
        #expect(line[finding.range].count == 1024)
        #expect(line[finding.range].first == "w")
    }

    @Test func aTokenValueIsMaskedForItsFirst1024Characters() throws {
        let line = "set token=" + String(repeating: "a", count: 1500)
        let finding = try #require(SensitiveDetector.findings(in: line, kinds: .all).first)
        #expect(line[finding.range].count == 1024)
    }

    // MARK: A quoted value with a quote in it

    @Test func anEscapedQuoteDoesNotEndAQuotedValue() {
        #expect(masked("\"password\": \"ab\\\"cd\"") == "\"password\": \"▓\"")
        #expect(found("\"password\": \"ab\\\"cd\"") == [Found(.keyOrToken, "ab\\\"cd")])
        #expect(masked("set password: 'it\\'s a secret' ok") == "set password: '▓' ok")
    }

    @Test func anEscapedBackslashDoesNotEscapeTheClosingQuote() {
        #expect(masked("set password: \"ab\\\\\" tail") == "set password: \"▓\" tail")
    }

    // MARK: A private key written on one line

    /// The key as JSON and `.env` files write it: the lines of the PEM joined by a backslash and an `n`.
    private var key: String { Fake.escapedPrivateKey() }

    @Test func aPrivateKeyInJSONIsMaskedWholeUpToItsClosingQuote() {
        let json = "{\"type\": \"service_account\", \"private_key\": \"" + key + "\", \"client_email\": \"svc@example.test\"}"
        #expect(masked(json, .keysAndTokens) == "{\"type\": \"service_account\", \"private_key\": \"▓\", \"client_email\": \"svc@example.test\"}")
        #expect(key.count > 1_024, "longer than a labelled value is read for")
    }

    @Test func aPrivateKeyWithNoLabelIsMaskedWholeToo() {
        #expect(masked("{\"pem\": \"" + key + "\", \"n\": 1}", .keysAndTokens) == "{\"pem\": \"▓\", \"n\": 1}")
        #expect(masked(key, .keysAndTokens) == "▓")
        #expect(masked("key dump " + key + " done", .keysAndTokens) == "key dump ▓ done")
    }

    @Test func aPrivateKeyInADotEnvFileIsMaskedWhole() {
        let unfinished = Fake.escapedPrivateKey("RSA", lines: 3, withEnd: false)
        #expect(masked("PRIVATE_KEY=\"" + unfinished + "\"") == "PRIVATE_KEY=\"▓\"")
        #expect(masked("PRIVATE_KEY=\"" + key + "\"") == "PRIVATE_KEY=\"▓\"")
        #expect(masked("PRIVATE_KEY=" + key) == "PRIVATE_KEY=▓")
        #expect(masked("export PRIVATE_KEY='" + Fake.escapedPrivateKey("RSA", withEnd: false) + "'") == "export PRIVATE_KEY='▓'")
    }

    @Test func aKeyThatEndsAtTheEndOfTheLineIsMaskedToIt() {
        #expect(masked("data: " + Fake.escapedPrivateKey("EC", lines: 5, withEnd: false), .keysAndTokens) == "data: ▓")
    }

    @Test func theEndMarkerAndWhatIsGluedToItAreInTheFinding() {
        let end = Fake.privateKeyEnd("RSA")
        #expect(masked("x " + Fake.privateKeyBegin("RSA") + "\\nAbCdEfGh\\n" + end + "\\n y", .keysAndTokens) == "x ▓ y")
    }

    /// A PEM with its newlines turned into spaces.
    @Test func aKeyWithSpacesBetweenItsLinesIsMaskedWhole() {
        let body = (0..<4).map { Fake.privateKeyBody(64, line: $0) }.joined(separator: " ")
        let line = Fake.privateKeyBegin("RSA") + " " + body + " " + Fake.privateKeyEnd("RSA")
        #expect(masked(line, .keysAndTokens) == "▓")
        #expect(masked("pem: " + line + " done", .keysAndTokens) == "pem: ▓ done")
        let spaced = Fake.privateKeyBegin("RSA") + " " + body
        #expect(masked(spaced, .keysAndTokens) == "▓")
    }

    @Test func wordsAfterAHeaderAreNotPartOfTheKey() {
        #expect(masked(Fake.privateKeyBegin("RSA") + " see below", .keysAndTokens) == "▓ see below")
        #expect(masked(Fake.privateKeyBegin("RSA") + " Hello", .keysAndTokens) == "▓ Hello")
        #expect(masked(Fake.privateKeyBegin("RSA") + " 0123456789abcdef0123", .keysAndTokens) == "▓ 0123456789abcdef0123")
    }

    @Test func twoKeysOnALineAreBothMasked() {
        let line = "a " + key + " b " + Fake.escapedPrivateKey("EC", lines: 4) + " c"
        #expect(masked(line, .keysAndTokens) == "a ▓ b ▓ c")
    }

    @Test func aLineOfHeadersIsReadOnce() {
        let line = String(repeating: Fake.privateKeyBegin("RSA") + "x ", count: 300)
        #expect(SensitiveDetector.findings(in: line, kinds: .keysAndTokens).count == 300)
    }

    // MARK: A URL with an @ in its user name

    @Test func anAtSignInAURLUserNameIsKeptOutOfThePassword() {
        #expect(masked("smtp://jane@example.com:mailpass@localhost", .keysAndTokens) == "smtp://jane@example.com:▓@localhost")
        #expect(masked("smtp://jane@example.com:mailpass@localhost") == "smtp://▓:▓@localhost")
        #expect(found("smtp://jane@example.com:mailpass@localhost", .keysAndTokens) == [Found(.keyOrToken, "mailpass")])
    }

    @Test func thePasswordIsSplitFromTheUserAtTheFirstColon() {
        #expect(masked("postgres://admin:P@ssw0rd!@db.example.com", .keysAndTokens) == "postgres://admin:▓@db.example.com")
        #expect(masked("mongodb://user:p@ss:w@rd@host.example.com", .keysAndTokens) == "mongodb://user:▓@host.example.com")
        #expect(masked("x://a@b.test:p@ss@host.test", .keysAndTokens) == "x://a@b.test:▓@host.test")
    }

    @Test func aPortAndAPathAfterAUserNameWithAnAtSignAreNotAPassword() {
        #expect(found("ssh://git@github.test:2222/org/repo", .keysAndTokens) == [])
    }

    /// The user name is an address, and so is what follows `x=`; what follows the port reads as a password, and neither
    /// hides the other.
    @Test func bothAddressesOfAURLWithAPortAreMasked() {
        let line = "https://user@example.com:8443?x=jane@example.com"
        #expect(readable("user@example.com", in: line) == "", "\(masked(line))")
        #expect(readable("jane@example.com", in: line) == "", "\(masked(line))")
        #expect(readable("jane@example.com", in: line, .contact) == "", "\(masked(line, .contact))")
    }

    // MARK: A label after a list or comment marker is a label at the start of a line

    @Test(arguments: [
        Case("# password: correct horse battery staple", "correct horse battery staple"),
        Case("#   password: my secret pass"),
        Case("// password: my secret pass"),
        Case("  // password: my secret pass"),
        Case("; password: my secret pass"),
        Case("- password: my secret pass"),
        Case("  - POSTGRES_PASSWORD=my secret pass"),
        Case("* Password: my secret pass"),
        Case("• Password: my secret pass"),
        Case("1. Password: my secret pass"),
        Case("12) Password: my secret pass"),
        Case("> password: my secret pass"),
        Case("> > password: my secret pass"),
        Case("12  password: my secret pass"),
        Case("$ export PASSWORD=my secret pass"),
        Case("$ password=my secret pass"),
        Case("| password: my secret pass"),
        Case("[db] password: my secret pass"),
        Case("[database.prod] password: my secret pass"),
        Case("  # - password: my secret pass"),
        Case("- # export DB_PASSWORD=my secret pass"),
    ])
    func aLabelAfterAMarkerHasTheRestOfTheLineForItsValue(example: Case) {
        #expect(masked(example.line) == example.line.replacingOccurrences(of: example.secret, with: "▓"))
    }

    @Test(arguments: [
        "see 1. password: swordfish rain man",
        "x - password: swordfish rain man",
        "Total 12 words password: swordfish rain man",
        "a # password: swordfish rain man",
        "[db] ok password: swordfish rain man",
    ])
    func aLabelAfterWordsStillHasTheFirstWordForItsValue(line: String) {
        #expect(masked(line) == line.replacingOccurrences(of: "swordfish", with: "▓"))
    }

    // MARK: A label inside a value the cap cut off

    @Test func aLabelInsideAValueTheCapCutOffIsStillRead() {
        let line = "token=" + String(repeating: "a", count: 1_020) + " password=hunter2secret"
        let result = masked(line)
        #expect(!result.contains("hunter"), "the nested password stays readable")
        #expect(result == "token=▓sword=▓")
        let second = "password: " + String(repeating: "w ", count: 502) + "token=SECRETVALUE1234"
        #expect(masked(second) == "password: ▓")
    }

    // MARK: A quoted value that starts with mask characters

    @Test func aQuotedValueIsNotASecretOnlyIfItIsAllMaskCharacters() {
        #expect(masked("\"password\": \"•• abc\"") == "\"password\": \"▓\"")
        #expect(masked("set password: '**** real' ok") == "set password: '▓' ok")
        #expect(found("\"password\": \"••••\"") == [])
        #expect(found("\"password\": \"•• ••\"") == [])
        #expect(found("set password: \"********\" ok") == [])
    }

    // MARK: Other quotes

    @Test func aPairOfDoubledSingleQuotesDoesNotEndASingleQuotedValue() {
        #expect(masked("set password: 'it''s secret' ok") == "set password: '▓' ok")
        #expect(masked("set password: 'a''''b c' ok") == "set password: '▓' ok")
        #expect(masked("set password: 'abc' 'def' ok") == "set password: '▓' 'def' ok")
    }

    @Test func guillemetsQuoteAValue() {
        #expect(masked("set password: «my secret» ok") == "set password: «▓» ok")
        #expect(masked("password: «my secret»") == "password: «▓»")
    }

    // MARK: A key whose lines were joined by spaces, with a last line of its own

    @Test func aKeyWithAShortLastLineIsMaskedUpToItsEndMarker() {
        let lines = (0..<4).map { Fake.privateKeyBody(64, line: $0) }.joined(separator: " ")
        for last in [Fake.privateKeyBody(10, line: 9) + "==", Fake.privateKeyBody(20, line: 9), Fake.privateKeyBody(3, line: 2), "hJ9kL1mN2p=="] {
            let line = Fake.privateKeyBegin("RSA") + " " + lines + " " + last + " " + Fake.privateKeyEnd("RSA")
            #expect(masked(line, .keysAndTokens) == "▓", "last line \(last)")
            #expect(masked("pem: " + line + " done", .keysAndTokens) == "pem: ▓ done", "last line \(last)")
        }
    }

    @Test func wordsBeforeAnEndMarkerOnTheLineAreMaskedWithTheKey() {
        let line = Fake.privateKeyBegin("EC") + " one two three " + Fake.privateKeyEnd("EC") + " after"
        #expect(masked(line, .keysAndTokens) == "▓ after")
    }

    @Test func aKeyWithoutAnEndMarkerStopsAtTheFirstWordThatIsNotAKeyLine() {
        let lines = (0..<2).map { Fake.privateKeyBody(64, line: $0) }.joined(separator: " ")
        #expect(masked(Fake.privateKeyBegin("RSA") + " " + lines + " end of the dump", .keysAndTokens) == "▓ end of the dump")
    }

    @Test func anEndMarkerAfterAQuoteIsNotThisKeysEnd() {
        let line = "\"a\": \"" + Fake.privateKeyBegin("RSA") + " short\", \"b\": \"" + Fake.privateKeyEnd("RSA") + "\""
        // The header is masked, and what follows it up to the quote is a word that is not a key line: it is left alone.
        #expect(masked(line, .keysAndTokens) == "\"a\": \"▓ short\", \"b\": \"" + Fake.privateKeyEnd("RSA") + "\"")
    }

    // MARK: Leading spaces don't count towards the line-start prefix

    @Test func aLabelAfterManyLeadingSpacesStillStartsItsLine() {
        let spaces = String(repeating: " ", count: 70)
        #expect(masked(spaces + "password: correct horse battery") == spaces + "password: ▓")
        let tabs = String(repeating: "\t", count: 70)
        #expect(masked(tabs + "password: correct horse battery") == tabs + "password: ▓")
    }

    /// Only the marks count towards the cap, not the spaces among them (a comment aligned far to the right).
    @Test func spacesAmongTheMarksBeforeALabelDoNotCount() {
        let line = "#" + String(repeating: " ", count: 70) + "password: correct horse battery"
        #expect(masked(line) == line.replacingOccurrences(of: "correct horse battery", with: "▓"))
        let quoted = "  >" + String(repeating: " ", count: 40) + ">" + String(repeating: " ", count: 40) + "password: correct horse battery"
        #expect(masked(quoted) == quoted.replacingOccurrences(of: "correct horse battery", with: "▓"))
    }

    // MARK: Markdown bold around a label

    @Test(arguments: [
        Case("**Password:** hunter2secret", "hunter2secret"),
        Case("**Password:** correct horse battery", "correct horse battery"),
        Case("- **API key:** sk_abc123def456", "sk_abc123def456"),
        Case("**Password**: x7Yq2pLm", "x7Yq2pLm"),
        Case("__Password:__ value", "value"),
        Case("__Password__: value", "value"),
        Case("***Password:*** hunter2secret", "hunter2secret"),
        Case("*Password:* hunter2secret", "hunter2secret"),
        Case("Log in with **Password:** hunter2secret today", "hunter2secret"),
        Case("Log in with **Password**: hunter2secret today", "hunter2secret"),
    ])
    func boldMarksAroundALabelBelongToTheLabel(example: Case) {
        #expect(masked(example.line) == example.line.replacingOccurrences(of: example.secret, with: "▓"))
    }

    /// Marks glued to the value, with no space after them, are the value's.
    @Test func marksGluedToAValueArePartOfIt() {
        #expect(masked("set password=__init__x now") == "set password=▓ now")
        #expect(masked("set password:**secret** now") == "set password:▓ now")
        #expect(found("password: ********") == [])
    }

    // MARK: A short first word in the middle of a line

    @Test(arguments: [
        Case("Username: admin   Password: my secret pass"),
        Case("user: bob\tpassword:\tmy secret pass"),
        Case("Login as admin, password: ab cd ef", "ab cd ef"),
        Case("the password: a, b and c", "a, b and c"),
    ])
    func aShortFirstWordInTheMiddleOfALineTakesTheRestOfTheLine(example: Case) {
        #expect(masked(example.line) == example.line.replacingOccurrences(of: example.secret, with: "▓"))
    }

    @Test func aShortFirstWordInTheMiddleOfALineRunsToTheNextLabel() {
        #expect(masked("set pwd: ab cd token: xyz12345 ok") == "set pwd: ▓ token: ▓ ok")
    }

    @Test func aFirstWordOfThreeCharactersOrMoreInTheMiddleOfALineIsTheValue() {
        #expect(masked("Username: admin   Password: abc secret pass") == "Username: admin   Password: ▓ secret pass")
        #expect(found("x password: •• Show") == [])
        // In a query string a value ends at the next field, however short.
        #expect(found("https://example.com/r?pwd=ab&next=/home") == [])
    }

    // MARK: Labels with digits and longer names

    @Test(arguments: [
        "password1: hunter2secret", "admin_password2=hunter2secret", "PASSWORD_FOR_DB_PROD_1=hunter2secret",
        "set password1: hunter2secret now", "set admin_password2=hunter2secret now", "DB_PASSWORD_2: hunter2secret",
        "token2=hunter2secret", "api_key_v2_prod_eu_west=hunter2secret",
    ])
    func aLabelWithDigitsOrALongNameIsALabel(line: String) {
        #expect(found(line).map(\.text) == ["hunter2secret"])
        #expect(readable("hunter2secret", in: line) == "")
    }

    @Test(arguments: ["password1 is wrong", "the password2 field", "passwords 12345678", "my passwords are great", "tokenizer2: fast", "secretary1: Jane"])
    func aWordWithDigitsAndNoSeparatorIsNotALabel(line: String) {
        #expect(found(line, .keysAndTokens) == [])
    }

    // MARK: A quote inside a value

    @Test func aQuotedValueWithMoreGluedAfterItsClosingQuoteRunsToTheNextSpace() {
        #expect(masked("set password: \"hun\"ter2 ok") == "set password: \"▓ ok")
        #expect(masked("password: 'abc'def") == "password: '▓")
        #expect(masked("set password: \"hun\"ter2. ok") == "set password: \"▓. ok")
    }

    @Test func punctuationAfterAClosingQuoteIsNotPartOfTheValue() {
        #expect(masked("{\"password\": \"abc\", \"user\": \"bob\"}") == "{\"password\": \"▓\", \"user\": \"bob\"}")
        #expect(masked("[{\"password\": \"a b\"}, {\"x\": 1}]") == "[{\"password\": \"▓\"}, {\"x\": 1}]")
        #expect(masked("set password: \"abc\". ok") == "set password: \"▓\". ok")
        // Compact JSON glues the next field to the closing quote: masked with the value, more than the secret.
        #expect(readable("abc", in: "{\"password\":\"abc\",\"user\":\"bob\"}") == "")
    }

    @Test(arguments: [false, true])
    func aLineOfHeadersIsReadInLinearTime(withAnEndMarkerAtTheEnd: Bool) {
        let line = String(repeating: Fake.privateKeyBegin("RSA") + " one two ", count: 600) + (withAnEndMarkerAtTheEnd ? Fake.privateKeyEnd("RSA") : "")
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = SensitiveDetector.findings(in: line, kinds: .all) }
        #expect(elapsed < .seconds(1), "took \(elapsed)")
    }
}
