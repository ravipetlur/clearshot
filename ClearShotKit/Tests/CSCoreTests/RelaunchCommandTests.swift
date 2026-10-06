import Testing
@testable import CSCore

struct RelaunchCommandTests {
    /// The PID and the app's path reach the shell as positional parameters, never as part of the script, so a path with
    /// quotes or a command in it can't run anything.
    @Test func thePathAndPIDAreArgumentsNotScript() throws {
        let path = "/Applications/Clear\"; rm -rf ~ \"Shot.app"
        let arguments = RelaunchCommand.arguments(pid: 4321, appPath: path)
        #expect(arguments.count == 5)
        #expect(arguments.first == "-c")
        #expect(arguments.last == path)
        #expect(arguments[2] == "sh")
        #expect(arguments[3] == "4321")
        let script = arguments[1]
        #expect(!script.contains("4321"))
        #expect(!script.contains("rm -rf"))
        // The only expansions in the script are the two parameters.
        let expansions = script.indices.filter { script[$0] == "$" }.map { String(script[$0...].prefix(2)) }
        #expect(expansions == ["$1", "$2"])
        #expect(script == "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$2\"")
    }
}
