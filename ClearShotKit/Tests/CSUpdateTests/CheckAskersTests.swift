import Testing
import CSUpdate

/// Who a running check is for: nobody (the schedule), one surface, or both when a second person asks while it runs.
struct CheckAskersTests {
    @Test func nobodyAskedMeansTheScheduleAsked() {
        let askers = CheckAskers()
        #expect(!askers.isManual)
        #expect(askers.sources.isEmpty)
        #expect(askers.logName == "background")
    }

    @Test func oneAskerIsManualAndIsAnswered() {
        var askers = CheckAskers()
        askers.add(.statusMenu)
        #expect(askers.isManual)
        #expect(askers.sources == [.statusMenu])
        #expect(askers.logName == "status menu")

        var fromSettings = CheckAskers()
        fromSettings.add(.settings)
        #expect(fromSettings.isManual)
        #expect(fromSettings.sources == [.settings])
        #expect(fromSettings.logName == "settings")
    }

    /// A second asker while a check runs doesn't take the first one's answer: both surfaces get it.
    @Test func twoAskersAreBothAnswered() {
        var askers = CheckAskers()
        askers.add(.settings)
        askers.add(.statusMenu)
        #expect(askers.isManual)
        #expect(Set(askers.sources) == Set([CheckSource.statusMenu, CheckSource.settings]))
        #expect(askers.sources.count == 2)
    }

    /// The same order whichever asked first, so the log and the answers don't depend on it.
    @Test func theOrderDoesNotDependOnWhoAskedFirst() {
        var settingsFirst = CheckAskers()
        settingsFirst.add(.settings)
        settingsFirst.add(.statusMenu)
        var menuFirst = CheckAskers()
        menuFirst.add(.statusMenu)
        menuFirst.add(.settings)
        #expect(settingsFirst.sources == menuFirst.sources)
        #expect(settingsFirst.logName == menuFirst.logName)
        #expect(settingsFirst.logName == "status menu and settings")
        #expect(settingsFirst == menuFirst)
    }

    @Test func askingAgainChangesNothing() {
        var askers = CheckAskers()
        askers.add(.statusMenu)
        askers.add(.statusMenu)
        #expect(askers.sources == [.statusMenu])
        #expect(askers.logName == "status menu")
    }

    @Test func everySourceHasALogName() {
        for source in CheckSource.allCases {
            #expect(!source.logName.isEmpty, "\(source)")
        }
    }
}
