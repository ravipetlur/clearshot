import CSTestSupport
import Foundation
import Synchronization
import Testing
@testable import CSCore

/// A registrar that registers nothing: it records every call, answers as a scripted result says, and otherwise follows
/// Carbon's rule that one process can't hold the same keys twice (the second registration is refused). `press` plays
/// the system's part, handing an ID to the handler the registry installed.
@MainActor
private final class FakeRegistrar: HotkeyRegistrar {
    enum Call: Equatable {
        case installHandler
        case register(UInt32, ShortcutSpec)
        case unregister(UInt32)
    }

    private(set) var calls: [Call] = []
    /// What `register` answers for an ID; an ID not here registers normally.
    var scripted: [UInt32: HotkeyRegistrationResult] = [:]
    /// The registrations the system would hold now.
    private(set) var held: [UInt32: ShortcutSpec] = [:]
    private var onPress: (@MainActor (UInt32) -> Void)?

    func installPressHandler(_ onPress: @escaping @MainActor (UInt32) -> Void) {
        calls.append(.installHandler)
        self.onPress = onPress
    }

    func register(id: UInt32, shortcut: ShortcutSpec) -> HotkeyRegistrationResult {
        calls.append(.register(id, shortcut))
        if let result = scripted[id] {
            if result == .registered { held[id] = shortcut }
            return result
        }
        if held.values.contains(shortcut) { return .refused }
        held[id] = shortcut
        return .registered
    }

    func unregister(id: UInt32) {
        calls.append(.unregister(id))
        held[id] = nil
    }

    func press(_ id: UInt32) {
        onPress?(id)
    }

    /// Forgets the calls so far, so a test reads only what the step under test did.
    func forgetCalls() {
        calls = []
    }

    var registrations: [Call] { calls.filter { if case .register = $0 { true } else { false } } }
    var unregistrations: [Call] { calls.filter { if case .unregister = $0 { true } else { false } } }
}

/// What `onAction` was given, in order.
@MainActor
private final class Fired {
    var actions: [ClearShotAction] = []
}

@MainActor
final class HotkeyRegistryTests {
    let throwaway = ThrowawayDefaults("hotkey-registry")
    let defaults: UserDefaults
    /// The store posts on this center. The registry listens on another unless a test joins them, so a test that calls
    /// `storeDidChange(action:)` by hand is not also driven by the store's own posts.
    let storeCenter = NotificationCenter()
    let store: ShortcutStore
    private let registrar = FakeRegistrar()
    private let fired = Fired()
    private let log = TemporaryLog()

    let fullscreen = ShortcutSpec.commandShift(KeyCode.digit3)
    let area = ShortcutSpec.commandShift(KeyCode.digit4)
    let allInOne = ShortcutSpec.commandShift(KeyCode.digit5)
    let record = ShortcutSpec(carbonKeyCode: 15, carbonModifiers: ShortcutSpec.control | ShortcutSpec.option)
    let moved = ShortcutSpec.commandShift(KeyCode.digit6)

    init() {
        defaults = throwaway.defaults
        store = ShortcutStore(defaults: defaults, notificationCenter: storeCenter, logger: silentLogger)
    }

    /// A registry on the fake registrar. `center` is where it listens for the store's posts: by default one nothing
    /// posts to; `storeCenter` makes it follow the store.
    private func makeRegistry(center: NotificationCenter = NotificationCenter(), store: ShortcutStore? = nil,
                              logger: AppLogger = silentLogger) -> HotkeyRegistry {
        let fired = fired
        return HotkeyRegistry(registrar: registrar, store: store ?? self.store, notificationCenter: center,
                              logger: logger) { fired.actions.append($0) }
    }

    /// An action's hot-key ID by the registry's rule: its index in `allCases`, plus one.
    private func id(_ action: ClearShotAction) -> UInt32 {
        UInt32(ClearShotAction.allCases.firstIndex(of: action)! + 1)
    }

    // MARK: Starting

    @Test func startRegistersExactlyTheActionsThatHaveShortcuts() {
        store.set(record, for: .recordScreen)
        store.set(nil, for: .captureArea) // a cleared default has none
        let registry = makeRegistry()
        registry.start()

        // allInOne is the first action (ID 1) and captureFullscreen the fourth (ID 4); calls follow `allCases`.
        #expect(registrar.calls == [
            .installHandler,
            .register(1, allInOne),
            .register(4, fullscreen),
            .register(id(.recordScreen), record),
        ])
        #expect(registrar.held.count == 3)
        #expect(registry.unregisteredActions.isEmpty)
    }

    @Test func startWithNothingStoredRegistersTheThreeDefaults() {
        let registry = makeRegistry()
        registry.start()
        #expect(registrar.registrations == [
            .register(id(.allInOne), allInOne),
            .register(id(.captureArea), area),
            .register(id(.captureFullscreen), fullscreen),
        ])
        #expect(registry.unregisteredActions.isEmpty)
    }

    @Test func everyActionGetsItsIndexPlusOneAsItsID() {
        for (index, action) in ClearShotAction.allCases.enumerated() {
            store.set(ShortcutSpec(carbonKeyCode: index, carbonModifiers: ShortcutSpec.command), for: action)
        }
        let registry = makeRegistry()
        registry.start()

        let expected = ClearShotAction.allCases.enumerated().map { index, _ in
            FakeRegistrar.Call.register(UInt32(index + 1), ShortcutSpec(carbonKeyCode: index, carbonModifiers: ShortcutSpec.command))
        }
        #expect(registrar.registrations == expected)
        #expect(registrar.registrations.count == ClearShotAction.allCases.count)
        #expect(Set(registrar.held.keys).count == ClearShotAction.allCases.count)
    }

    @Test func startInstallsTheHandlerFirstAndOnlyOnce() {
        let registry = makeRegistry()
        registry.start()
        registry.start()
        #expect(registrar.calls.first == .installHandler)
        #expect(registrar.calls.filter { $0 == .installHandler }.count == 1)
        // The second start did not register anything again.
        #expect(registrar.registrations.count == 3)
        #expect(registrar.unregistrations.isEmpty)
    }

    @Test func nothingIsRegisteredBeforeStart() {
        let registry = makeRegistry()
        store.set(record, for: .recordScreen)
        registry.storeDidChange(action: .recordScreen)
        registry.storeDidChange(action: nil)
        #expect(registrar.calls.isEmpty)
        #expect(registry.unregisteredActions.isEmpty)
    }

    // MARK: Results

    @Test func aRefusedActionIsUnregisteredAndAFailedOneToo() {
        registrar.scripted[id(.captureArea)] = .refused
        registrar.scripted[id(.allInOne)] = .failed(-50)
        let registry = makeRegistry()
        registry.start()

        // captureFullscreen registered, so it is not listed; the list follows `allCases`, not the order of the results.
        #expect(registry.unregisteredActions == [.allInOne, .captureArea])
        #expect(registrar.held.keys.sorted() == [id(.captureFullscreen)])
    }

    @Test func aRefusedOrFailedActionIsNotInTheListAfterItsShortcutIsCleared() {
        registrar.scripted[id(.captureArea)] = .refused
        registrar.scripted[id(.recordScreen)] = .failed(-9870)
        store.set(record, for: .recordScreen)
        let registry = makeRegistry()
        registry.start()
        #expect(registry.unregisteredActions == [.captureArea, .recordScreen])
        registrar.forgetCalls()

        store.set(nil, for: .captureArea)
        registry.storeDidChange(action: .captureArea)
        #expect(registry.unregisteredActions == [.recordScreen])
        store.set(nil, for: .recordScreen)
        registry.storeDidChange(action: .recordScreen)
        #expect(registry.unregisteredActions.isEmpty)
        // Neither held a registration, so there is nothing to unregister. (The failed one was tried again by the first
        // change, as every refused or failed action is, and failed again.)
        #expect(registrar.unregistrations.isEmpty)
    }

    @Test func aClearedActionNeverAppears() {
        store.set(nil, for: .captureArea)
        store.set(nil, for: .allInOne)
        store.set(nil, for: .captureFullscreen)
        registrar.scripted[id(.captureArea)] = .refused // would refuse, if it were ever asked
        let registry = makeRegistry()
        registry.start()
        #expect(registrar.registrations.isEmpty)
        #expect(registry.unregisteredActions.isEmpty)
    }

    @Test func aRefusedActionRegistersOnceItsShortcutChangesToAFreeOne() {
        registrar.scripted[id(.captureArea)] = .refused
        let registry = makeRegistry()
        registry.start()
        #expect(registry.unregisteredActions == [.captureArea])

        registrar.scripted[id(.captureArea)] = nil
        store.set(moved, for: .captureArea)
        registry.storeDidChange(action: .captureArea)
        #expect(registry.unregisteredActions.isEmpty)
        #expect(registrar.held[id(.captureArea)] == moved)
    }

    @Test func aRegisteredActionWhoseNewShortcutIsRefusedLosesItsOldRegistration() {
        let registry = makeRegistry()
        registry.start()
        registrar.scripted[id(.captureArea)] = .refused
        registrar.forgetCalls()

        store.set(moved, for: .captureArea)
        registry.storeDidChange(action: .captureArea)
        #expect(registrar.calls == [.unregister(id(.captureArea)), .register(id(.captureArea), moved)])
        #expect(registrar.held[id(.captureArea)] == nil)
        #expect(registry.unregisteredActions == [.captureArea])
    }

    @Test func aFailedResultLogsItsStatus() {
        registrar.scripted[id(.captureArea)] = .failed(-50)
        store.set(record, for: .recordScreen)
        let registry = makeRegistry(logger: log.logger)
        registry.start()

        let failures = log.lines.filter { $0.contains("[ERROR] [hotkeys]") }
        #expect(failures.count == 1)
        #expect(failures.first?.contains("captureArea") == true)
        #expect(failures.first?.contains("-50") == true)
    }

    @Test func aRefusedResultIsLoggedToo() {
        registrar.scripted[id(.captureArea)] = .refused
        let registry = makeRegistry(logger: log.logger)
        registry.start()
        let warnings = log.lines.filter { $0.contains("[WARN] [hotkeys]") }
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("captureArea") == true)
    }

    @Test func registeringLogsNothing() {
        let registry = makeRegistry(logger: log.logger)
        registry.start()
        #expect(log.lines.isEmpty)
    }

    // MARK: Presses

    @Test func aPressWithAKnownIDPerformsItsActionAndIsLogged() {
        let registry = makeRegistry(logger: log.logger)
        registry.start()
        registrar.press(id(.captureArea))
        #expect(fired.actions == [.captureArea])
        #expect(log.lines.count == 1)
        #expect(log.lines.first?.hasSuffix("[INFO] [hotkeys] Hotkey: captureArea") == true)

        registrar.press(id(.allInOne))
        registrar.press(id(.captureArea))
        #expect(fired.actions == [.captureArea, .allInOne, .captureArea])
    }

    @Test func aPressWithAnUnknownIDDoesNothing() {
        let registry = makeRegistry(logger: log.logger)
        registry.start()
        for unknown in [0, UInt32(ClearShotAction.allCases.count + 1), 999, UInt32.max] {
            registrar.press(unknown)
        }
        #expect(fired.actions.isEmpty)
        #expect(log.lines.isEmpty)
    }

    @Test func aPressForAnActionThatIsNotRegisteredDoesNothing() {
        // recordScreen has no shortcut, so its ID is known but nothing is registered under it.
        let registry = makeRegistry()
        registry.start()
        registrar.press(id(.recordScreen))
        #expect(fired.actions.isEmpty)

        // A press already on its way when the shortcut was cleared is dropped, too.
        store.set(nil, for: .captureArea)
        registry.storeDidChange(action: .captureArea)
        registrar.press(id(.captureArea))
        #expect(fired.actions.isEmpty)
        registrar.press(id(.allInOne))
        #expect(fired.actions == [.allInOne])
    }

    // MARK: Changes

    @Test func aChangedShortcutIsUnregisteredThenRegisteredAgain() {
        let registry = makeRegistry()
        registry.start()
        registrar.forgetCalls()

        store.set(moved, for: .captureArea)
        registry.storeDidChange(action: .captureArea)
        #expect(registrar.calls == [.unregister(id(.captureArea)), .register(id(.captureArea), moved)])
        #expect(registrar.held[id(.captureArea)] == moved)
        // The others were left alone.
        #expect(registrar.held[id(.allInOne)] == allInOne)
        #expect(registrar.held[id(.captureFullscreen)] == fullscreen)
    }

    @Test func aClearedShortcutIsOnlyUnregistered() {
        let registry = makeRegistry()
        registry.start()
        registrar.forgetCalls()

        store.set(nil, for: .captureArea)
        registry.storeDidChange(action: .captureArea)
        #expect(registrar.calls == [.unregister(id(.captureArea))])
        #expect(registrar.held[id(.captureArea)] == nil)
        #expect(registry.unregisteredActions.isEmpty)
    }

    @Test func aShortcutSetOnAnActionWithNoneIsOnlyRegistered() {
        let registry = makeRegistry()
        registry.start()
        registrar.forgetCalls()

        store.set(record, for: .recordScreen)
        registry.storeDidChange(action: .recordScreen)
        #expect(registrar.calls == [.register(id(.recordScreen), record)])
    }

    @Test func aChangeForAllUnregistersEverythingBeforeItRegistersAgain() {
        store.set(record, for: .recordScreen)
        let registry = makeRegistry()
        registry.start()
        registrar.forgetCalls()

        // The record shortcut goes away with a reset; the three defaults come back as they were.
        store.resetAll()
        registry.storeDidChange(action: nil)
        #expect(registrar.calls == [
            .unregister(id(.allInOne)), .unregister(id(.captureArea)), .unregister(id(.captureFullscreen)),
            .unregister(id(.recordScreen)),
            .register(id(.allInOne), allInOne), .register(id(.captureArea), area),
            .register(id(.captureFullscreen), fullscreen),
        ])
        #expect(registry.unregisteredActions.isEmpty)
    }

    @Test func actionsThatSwapShortcutsAreNotRefusedByEachOther() {
        // captureArea and allInOne hold each other's defaults; a reset swaps them back. Registered one after the other
        // (unregister, register, unregister, register), the first would meet the second's old keys and be refused.
        store.set(allInOne, for: .captureArea)
        store.set(area, for: .allInOne)
        store.set(nil, for: .captureFullscreen)
        let registry = makeRegistry()
        registry.start()
        #expect(registry.unregisteredActions.isEmpty)

        store.resetAll()
        registry.storeDidChange(action: nil)
        #expect(registry.unregisteredActions.isEmpty)
        #expect(registrar.held[id(.captureArea)] == area)
        #expect(registrar.held[id(.allInOne)] == allInOne)
        #expect(registrar.held[id(.captureFullscreen)] == fullscreen)
    }

    // MARK: Pausing

    @Test func pauseUnregistersEverything() {
        store.set(record, for: .recordScreen)
        let registry = makeRegistry()
        registry.start()
        registrar.forgetCalls()

        registry.pause()
        #expect(registrar.calls == [
            .unregister(id(.allInOne)), .unregister(id(.captureArea)), .unregister(id(.captureFullscreen)),
            .unregister(id(.recordScreen)),
        ])
        #expect(registrar.held.isEmpty)
    }

    @Test func pausesNestByCount() {
        let registry = makeRegistry()
        registry.start()
        registry.pause()
        registry.pause()
        registrar.forgetCalls()

        registry.resume()
        #expect(registrar.calls.isEmpty)
        #expect(registrar.held.isEmpty)

        registry.resume()
        #expect(registrar.registrations == [
            .register(id(.allInOne), allInOne),
            .register(id(.captureArea), area),
            .register(id(.captureFullscreen), fullscreen),
        ])
        #expect(registrar.held.count == 3)
    }

    @Test func theSecondPauseOfANestUnregistersNothingMore() {
        let registry = makeRegistry()
        registry.start()
        registry.pause()
        registrar.forgetCalls()
        registry.pause()
        #expect(registrar.calls.isEmpty)
    }

    @Test func aChangeDuringAPauseIsRegisteredWithTheNewShortcutOnTheLastResume() {
        let registry = makeRegistry()
        registry.start()
        registry.pause()
        registrar.forgetCalls()

        store.set(moved, for: .captureArea)
        registry.storeDidChange(action: .captureArea)
        store.set(record, for: .recordScreen)
        registry.storeDidChange(action: .recordScreen)
        store.set(nil, for: .allInOne)
        registry.storeDidChange(action: .allInOne)
        // Nothing is registered while paused, and nothing is touched.
        #expect(registrar.calls.isEmpty)
        #expect(registrar.held.isEmpty)

        registry.resume()
        #expect(registrar.registrations == [
            .register(id(.captureArea), moved),
            .register(id(.captureFullscreen), fullscreen),
            .register(id(.recordScreen), record),
        ])
        #expect(registrar.held[id(.captureArea)] == moved)
        #expect(registrar.held[id(.allInOne)] == nil)
        #expect(registry.unregisteredActions.isEmpty)
    }

    @Test func anExtraResumeIsANoOp() {
        let registry = makeRegistry()
        registry.start()
        registry.pause()
        registry.resume()
        let held = registrar.held
        registrar.forgetCalls()

        registry.resume()
        registry.resume()
        #expect(registrar.calls.isEmpty)
        #expect(registrar.held == held)

        // The count did not go negative: one pause still stops everything, and one resume starts it again.
        registry.pause()
        #expect(registrar.held.isEmpty)
        registrar.forgetCalls()
        registry.resume()
        #expect(registrar.registrations.count == 3)
        #expect(registrar.held == held)
    }

    @Test func aResumeWithNoPauseDoesNothing() {
        let registry = makeRegistry()
        registry.start()
        registrar.forgetCalls()
        registry.resume()
        #expect(registrar.calls.isEmpty)
    }

    @Test func aPauseBeforeStartKeepsStartFromRegistering() {
        let registry = makeRegistry()
        registry.pause()
        registry.start()
        #expect(registrar.calls == [.installHandler])
        #expect(registrar.held.isEmpty)

        registry.resume()
        #expect(registrar.registrations.count == 3)
        #expect(registrar.held.count == 3)
    }

    @Test func nothingFiresWhilePausedEvenForAPressAlreadyOnItsWay() {
        let registry = makeRegistry()
        registry.start()
        registry.pause()
        registrar.press(id(.captureArea))
        #expect(fired.actions.isEmpty)

        registry.resume()
        registrar.press(id(.captureArea))
        #expect(fired.actions == [.captureArea])
    }

    @Test func aPauseKeepsTheRefusedListAndTheResumeFindsThemAgain() {
        registrar.scripted[id(.captureArea)] = .refused
        let registry = makeRegistry()
        registry.start()
        #expect(registry.unregisteredActions == [.captureArea])

        // Onboarding's notice keeps showing while a shortcut is recorded: the last results stand until the resume.
        registry.pause()
        #expect(registry.unregisteredActions == [.captureArea])
        registry.pause()
        #expect(registry.unregisteredActions == [.captureArea])
        registry.resume()
        #expect(registry.unregisteredActions == [.captureArea])
        registry.resume()
        #expect(registry.unregisteredActions == [.captureArea])
    }

    @Test func theLastResumeReplacesTheResultsThatWereKeptWhilePaused() {
        registrar.scripted[id(.captureArea)] = .refused
        store.set(record, for: .recordScreen)
        let registry = makeRegistry()
        registry.start()
        registry.pause()
        #expect(registry.unregisteredActions == [.captureArea])

        // The recorder stores its shortcut before it resumes: the refused action gets a free one, another is cleared.
        registrar.scripted[id(.captureArea)] = nil
        store.set(moved, for: .captureArea)
        registry.storeDidChange(action: .captureArea)
        #expect(registry.unregisteredActions == [.captureArea]) // nothing is registered, so nothing is known yet
        registry.resume()
        #expect(registry.unregisteredActions.isEmpty)
        #expect(registrar.held[id(.captureArea)] == moved)
    }

    @Test func aShortcutClearedWhilePausedIsNotListedAfterTheResume() {
        registrar.scripted[id(.captureArea)] = .refused
        let registry = makeRegistry()
        registry.start()
        registry.pause()
        store.set(nil, for: .captureArea)
        registry.resume()
        #expect(registry.unregisteredActions.isEmpty)
    }

    @Test func aPauseBeforeStartListsNothing() {
        registrar.scripted[id(.captureArea)] = .refused
        let registry = makeRegistry()
        registry.pause()
        registry.start()
        #expect(registry.unregisteredActions.isEmpty)
        registry.resume()
        #expect(registry.unregisteredActions == [.captureArea])
    }

    // MARK: Retrying

    @Test func anActionRefusedForKeysAnotherActionHeldRegistersOnceThoseKeysAreFree() {
        // captureArea wants the keys allInOne holds, and allInOne comes first, so captureArea is refused.
        store.set(allInOne, for: .captureArea)
        let registry = makeRegistry()
        registry.start()
        #expect(registry.unregisteredActions == [.captureArea])
        #expect(registrar.held[id(.allInOne)] == allInOne)

        // allInOne moves away; the refused captureArea is tried again without its own shortcut changing.
        store.set(moved, for: .allInOne)
        registry.storeDidChange(action: .allInOne)
        #expect(registry.unregisteredActions.isEmpty)
        #expect(registrar.held[id(.allInOne)] == moved)
        #expect(registrar.held[id(.captureArea)] == allInOne)
    }

    @Test func aFailedActionIsTriedAgainWhenAnotherActionChanges() {
        registrar.scripted[id(.captureArea)] = .failed(-50)
        let registry = makeRegistry()
        registry.start()
        #expect(registry.unregisteredActions == [.captureArea])

        registrar.scripted[id(.captureArea)] = nil
        store.set(record, for: .recordScreen)
        registry.storeDidChange(action: .recordScreen)
        #expect(registry.unregisteredActions.isEmpty)
        #expect(registrar.held[id(.captureArea)] == area)
        #expect(registrar.held[id(.recordScreen)] == record)
    }

    @Test func aRetryThatIsRefusedAgainKeepsTheActionListed() {
        registrar.scripted[id(.captureArea)] = .refused
        let registry = makeRegistry()
        registry.start()
        registrar.forgetCalls()

        store.set(record, for: .recordScreen)
        registry.storeDidChange(action: .recordScreen)
        // The changed action and the refused one are tried, the registered ones left alone.
        #expect(registrar.calls == [.register(id(.captureArea), area), .register(id(.recordScreen), record)])
        #expect(registry.unregisteredActions == [.captureArea])
        #expect(registrar.held.keys.sorted() == [id(.allInOne), id(.captureFullscreen), id(.recordScreen)])
    }

    @Test func theChangedActionLetsGoOfItsKeysBeforeTheRefusedOneIsTriedAgain() {
        store.set(allInOne, for: .captureArea)
        let registry = makeRegistry()
        registry.start()
        registrar.forgetCalls()

        store.set(moved, for: .allInOne)
        registry.storeDidChange(action: .allInOne)
        #expect(registrar.calls == [
            .unregister(id(.allInOne)),
            .register(id(.allInOne), moved),
            .register(id(.captureArea), allInOne),
        ])
    }

    @Test func aClearedShortcutIsNotTriedAgain() {
        registrar.scripted[id(.captureArea)] = .refused
        let registry = makeRegistry()
        registry.start()
        store.set(nil, for: .captureArea)
        registry.storeDidChange(action: .captureArea)
        registrar.forgetCalls()

        store.set(record, for: .recordScreen)
        registry.storeDidChange(action: .recordScreen)
        #expect(registrar.calls == [.register(id(.recordScreen), record)])
        #expect(registry.unregisteredActions.isEmpty)
    }

    @Test func aRefusedActionIsTriedAgainByTheStoresOwnPosts() {
        store.set(allInOne, for: .captureArea)
        let registry = makeRegistry(center: storeCenter)
        registry.start()
        #expect(registry.unregisteredActions == [.captureArea])

        store.set(moved, for: .allInOne)
        #expect(registry.unregisteredActions.isEmpty)
        #expect(registrar.held[id(.captureArea)] == allInOne)
    }

    // MARK: Logging

    private var warnings: [String] { log.lines.filter { $0.contains("[WARN] [hotkeys]") } }
    private var errors: [String] { log.lines.filter { $0.contains("[ERROR] [hotkeys]") } }

    @Test func aRefusalThatPersistsIsLoggedOnce() {
        registrar.scripted[id(.captureArea)] = .refused
        let registry = makeRegistry(logger: log.logger)
        registry.start()
        #expect(warnings.count == 1)

        // Every kind of re-registering that meets the same refusal again: pauses, other actions' changes, a reset of all.
        registry.pause()
        registry.resume()
        registry.pause()
        registry.pause()
        registry.resume()
        registry.resume()
        store.set(record, for: .recordScreen)
        registry.storeDidChange(action: .recordScreen)
        store.set(nil, for: .recordScreen)
        registry.storeDidChange(action: .recordScreen)
        store.resetAll()
        registry.storeDidChange(action: nil)
        #expect(registry.unregisteredActions == [.captureArea])
        #expect(warnings.count == 1)
        #expect(errors.isEmpty)
    }

    @Test func aFailurePersistsAsOneLine() {
        registrar.scripted[id(.captureArea)] = .failed(-50)
        let registry = makeRegistry(logger: log.logger)
        registry.start()
        registry.pause()
        registry.resume()
        store.set(record, for: .recordScreen)
        registry.storeDidChange(action: .recordScreen)
        #expect(errors.count == 1)
        #expect(errors.first?.contains("-50") == true)
        #expect(warnings.isEmpty)
    }

    @Test func aResultThatChangesIsLoggedAgain() {
        registrar.scripted[id(.captureArea)] = .refused
        let registry = makeRegistry(logger: log.logger)
        registry.start()
        #expect(warnings.count == 1)

        // Refused, then a different status: a new line.
        registrar.scripted[id(.captureArea)] = .failed(-9870)
        registry.pause()
        registry.resume()
        #expect(warnings.count == 1)
        #expect(errors.count == 1)
        #expect(errors.last?.contains("-9870") == true)

        // A different status is a change too.
        registrar.scripted[id(.captureArea)] = .failed(-50)
        registry.pause()
        registry.resume()
        #expect(errors.count == 2)
        #expect(errors.last?.contains("-50") == true)

        // Recovering, then being refused again, is new.
        registrar.scripted[id(.captureArea)] = nil
        registry.pause()
        registry.resume()
        #expect(registry.unregisteredActions.isEmpty)
        registrar.scripted[id(.captureArea)] = .refused
        registry.pause()
        registry.resume()
        #expect(warnings.count == 2)
    }

    @Test func aNewShortcutThatIsRefusedToIsLoggedBecauseItNamesOtherKeys() {
        registrar.scripted[id(.captureArea)] = .refused
        let registry = makeRegistry(logger: log.logger)
        registry.start()
        #expect(warnings.count == 1)

        store.set(moved, for: .captureArea)
        registry.storeDidChange(action: .captureArea)
        #expect(warnings.count == 2)
        #expect(registry.unregisteredActions == [.captureArea])
    }

    @Test func anActionThatIsClearedAndSetAgainToTheSameRefusedKeysIsLoggedAgain() {
        registrar.scripted[id(.captureArea)] = .refused
        let registry = makeRegistry(logger: log.logger)
        registry.start()
        store.set(nil, for: .captureArea)
        registry.storeDidChange(action: .captureArea)
        store.reset(.captureArea)
        registry.storeDidChange(action: .captureArea)
        #expect(warnings.count == 2)
    }

    @Test func differentActionsAreLoggedEachOnce() {
        registrar.scripted[id(.captureArea)] = .refused
        registrar.scripted[id(.captureFullscreen)] = .refused
        let registry = makeRegistry(logger: log.logger)
        registry.start()
        registry.pause()
        registry.resume()
        #expect(warnings.count == 2)
        #expect(warnings.contains { $0.contains("captureArea") })
        #expect(warnings.contains { $0.contains("captureFullscreen") })
    }

    // MARK: With the real store's notifications

    @Test func theChangedActionComesFromThePost() {
        let seen = Mutex<[ClearShotAction?]>([])
        let token = storeCenter.addObserver(forName: ShortcutStore.didChange, object: nil, queue: nil) { note in
            seen.withLock { $0.append(ShortcutStore.changedAction(in: note)) }
        }
        defer { storeCenter.removeObserver(token) }
        store.set(moved, for: .recordWindow)
        store.reset(.captureArea)
        store.resetAll()

        #expect(seen.withLock { $0 } == [.recordWindow, .captureArea, nil])
        // A post that names something that is no action means "all", as if it named none.
        let odd = Notification(name: ShortcutStore.didChange, object: nil, userInfo: ["action": "noSuchAction"])
        #expect(ShortcutStore.changedAction(in: odd) == nil)
    }

    @Test func theStoresPostsDriveReRegistration() {
        let registry = makeRegistry(center: storeCenter)
        registry.start()
        registrar.forgetCalls()

        store.set(moved, for: .captureArea)
        #expect(registrar.calls == [.unregister(id(.captureArea)), .register(id(.captureArea), moved)])
        registrar.forgetCalls()

        store.set(nil, for: .captureArea)
        #expect(registrar.calls == [.unregister(id(.captureArea))])
        registrar.forgetCalls()

        store.set(record, for: .recordScreen)
        #expect(registrar.calls == [.register(id(.recordScreen), record)])
        registrar.forgetCalls()

        store.reset(.captureArea)
        #expect(registrar.calls == [.register(id(.captureArea), area)])
        #expect(registrar.held[id(.captureArea)] == area)
    }

    @Test func aResetOfAllReRegistersEveryAction() throws {
        store.set(moved, for: .captureArea)
        store.set(record, for: .recordScreen)
        let registry = makeRegistry(center: storeCenter)
        registry.start()
        registrar.forgetCalls()

        store.resetAll()
        #expect(registrar.held == [
            id(.allInOne): allInOne, id(.captureArea): area, id(.captureFullscreen): fullscreen,
        ])
        // All of them were unregistered before any was registered again.
        let firstRegistration = try #require(registrar.calls.firstIndex { if case .register = $0 { true } else { false } })
        let lastUnregistration = try #require(registrar.calls.lastIndex { if case .unregister = $0 { true } else { false } })
        #expect(lastUnregistration < firstRegistration)
    }

    @Test func aChangeMadeThroughTheStoreWhilePausedAppliesOnTheLastResume() {
        let registry = makeRegistry(center: storeCenter)
        registry.start()
        registry.pause()
        registrar.forgetCalls()

        store.set(moved, for: .captureArea)
        #expect(registrar.calls.isEmpty)
        registry.resume()
        #expect(registrar.held[id(.captureArea)] == moved)
        #expect(registrar.registrations.contains(.register(id(.captureArea), moved)))
        #expect(!registrar.registrations.contains(.register(id(.captureArea), area)))
    }

    @Test func anotherStoresChangesAreIgnored() {
        let other = ThrowawayDefaults("hotkey-registry-other")
        let otherStore = ShortcutStore(defaults: other.defaults, notificationCenter: storeCenter, logger: silentLogger)
        let registry = makeRegistry(center: storeCenter)
        registry.start()
        registrar.forgetCalls()

        otherStore.set(moved, for: .captureArea)
        otherStore.resetAll()
        #expect(registrar.calls.isEmpty)
    }

    @Test func aRegistryThatIsGoneLetsGoOfItsHotKeysAndStopsListening() {
        var registry: HotkeyRegistry? = makeRegistry(center: storeCenter)
        registry?.start()
        #expect(registrar.held.count == 3)
        registry = nil
        #expect(registrar.held.isEmpty)
        registrar.forgetCalls()

        store.set(moved, for: .captureArea)
        #expect(registrar.calls.isEmpty)
    }
}
