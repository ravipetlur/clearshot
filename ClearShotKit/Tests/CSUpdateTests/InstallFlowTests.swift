import Foundation
import Testing
import CSUpdate

struct InstallFlowTests {
    typealias Event = InstallFlow.Event
    typealias State = InstallFlow.State

    /// Feeds the flow an event it must accept. (`#expect` can't wrap a mutating call, so the result is read first.)
    func accept(_ event: Event, on flow: inout InstallFlow, sourceLocation: SourceLocation = #_sourceLocation) {
        let accepted = flow.handle(event)
        #expect(accepted, "\(event) should be accepted", sourceLocation: sourceLocation)
    }

    /// Feeds the flow an event it must reject, and checks the flow is as it was.
    func reject(_ event: Event, on flow: inout InstallFlow, sourceLocation: SourceLocation = #_sourceLocation) {
        let before = flow
        let accepted = flow.handle(event)
        #expect(!accepted, "\(event) should be rejected", sourceLocation: sourceLocation)
        #expect(flow == before, "\(event) must leave the flow unchanged", sourceLocation: sourceLocation)
    }

    static let release = ReleaseInfo(
        version: VersionNumber("1.2.0")!,
        notes: "Notes.",
        pageURL: URL(string: "https://example.com/app/releases/tag/v1.2.0")!,
        dmg: .init(name: "ClearShot-1.2.0.dmg", size: 1000, url: URL(string: "https://example.com/d/ClearShot-1.2.0.dmg")!),
        checksum: .init(name: "ClearShot-1.2.0.dmg.sha256", size: 86, url: URL(string: "https://example.com/d/ClearShot-1.2.0.dmg.sha256")!))
    let release = Self.release

    static let newer = ReleaseInfo(
        version: VersionNumber("1.3.0")!,
        notes: "Newer notes.",
        pageURL: URL(string: "https://example.com/app/releases/tag/v1.3.0")!,
        dmg: .init(name: "ClearShot-1.3.0.dmg", size: 2000, url: URL(string: "https://example.com/d/ClearShot-1.3.0.dmg")!),
        checksum: .init(name: "ClearShot-1.3.0.dmg.sha256", size: 86, url: URL(string: "https://example.com/d/ClearShot-1.3.0.dmg.sha256")!))

    /// A flow brought to a state by feeding it events, each of which must be accepted.
    func after(_ events: Event...) -> InstallFlow {
        var flow = InstallFlow()
        for event in events {
            accept(event, on: &flow)
        }
        return flow
    }

    /// Events that walk a flow from nothing to the given verify step.
    func eventsToVerify(_ step: VerifyStep) -> [Event] {
        var events: [Event] = [.checkStarted, .updateFound(release), .downloadStarted, .downloadFinished]
        var at = VerifyStep.checksum
        while at != step {
            events.append(.stepPassed(at))
            at = at.next!
        }
        return events
    }

    func verifying(_ step: VerifyStep) -> InstallFlow {
        var flow = InstallFlow()
        for event in eventsToVerify(step) { accept(event, on: &flow) }
        return flow
    }

    var installingFlow: InstallFlow { verifying(.gatekeeperApp).applying(.installStarted) }

    // MARK: Starting out

    @Test func startsIdle() {
        let flow = InstallFlow()
        #expect(flow.state == .idle)
        #expect(flow.release == nil)
        #expect(!flow.canCancel)
    }

    // MARK: Every legal transition

    @Test func checkingFromEveryQuietState() {
        let quiet: [InstallFlow] = [
            InstallFlow(),
            after(.checkStarted, .noUpdateFound),
            after(.checkStarted, .updateFound(release)),
            after(.checkStarted, .failure(.network)),
            after(.checkStarted, .updateFound(release), .downloadStarted, .cancel),
        ]
        #expect(quiet.map(\.state) == [.idle, .upToDate, .available(release), .failed(.network), .cancelled])
        for var start in quiet {
            accept(.checkStarted, on: &start)
            #expect(start.state == .checking)
        }
    }

    @Test func aCheckThatFindsAnUpdate() {
        var flow = after(.checkStarted)
        accept(.updateFound(release), on: &flow)
        #expect(flow.state == .available(release))
        #expect(flow.release == release)
        #expect(!flow.canCancel)
    }

    @Test func aCheckThatFindsNothing() {
        var flow = after(.checkStarted)
        accept(.noUpdateFound, on: &flow)
        #expect(flow.state == .upToDate)
        #expect(flow.release == nil)
    }

    @Test func aCheckThatFails() {
        var flow = after(.checkStarted)
        accept(.failure(.rateLimited), on: &flow)
        #expect(flow.state == .failed(.rateLimited))
        #expect(flow.release == nil)
    }

    @Test func installingStartsTheDownloadAtZero() {
        var flow = after(.checkStarted, .updateFound(release))
        accept(.downloadStarted, on: &flow)
        #expect(flow.state == .downloading(progress: 0))
        #expect(flow.release == release)
        #expect(flow.canCancel)
    }

    @Test func progressMovesTheBar() {
        var flow = after(.checkStarted, .updateFound(release), .downloadStarted)
        accept(.downloadProgress(0.25), on: &flow)
        #expect(flow.state == .downloading(progress: 0.25))
        accept(.downloadProgress(0.5), on: &flow)
        #expect(flow.state == .downloading(progress: 0.5))
        accept(.downloadProgress(1), on: &flow)
        #expect(flow.state == .downloading(progress: 1))
    }

    @Test func progressNeverGoesBackwards() {
        var flow = after(.checkStarted, .updateFound(release), .downloadStarted, .downloadProgress(0.6))
        accept(.downloadProgress(0.4), on: &flow)
        #expect(flow.state == .downloading(progress: 0.6))
    }

    @Test func progressStaysBetweenZeroAndOne() {
        var flow = after(.checkStarted, .updateFound(release), .downloadStarted)
        accept(.downloadProgress(-3), on: &flow)
        #expect(flow.state == .downloading(progress: 0))
        accept(.downloadProgress(7), on: &flow)
        #expect(flow.state == .downloading(progress: 1))
        accept(.downloadProgress(.infinity), on: &flow)
        #expect(flow.state == .downloading(progress: 1))
    }

    @Test func progressThatIsNotANumberIsRejected() {
        var flow = after(.checkStarted, .updateFound(release), .downloadStarted, .downloadProgress(0.3))
        reject(.downloadProgress(.nan), on: &flow)
        #expect(flow.state == .downloading(progress: 0.3))
    }

    @Test func aFinishedDownloadStartsVerifyingWithTheChecksum() {
        var flow = after(.checkStarted, .updateFound(release), .downloadStarted, .downloadProgress(1))
        accept(.downloadFinished, on: &flow)
        #expect(flow.state == .verifying(step: .checksum))
        #expect(flow.canCancel)
    }

    @Test func verifyingWalksTheSixStepsInOrder() {
        var flow = after(.checkStarted, .updateFound(release), .downloadStarted, .downloadFinished)
        let order: [VerifyStep] = [.checksum, .gatekeeperImage, .mount, .appIdentity, .appSignature, .gatekeeperApp]
        for (index, step) in order.enumerated() {
            #expect(flow.state == .verifying(step: step))
            #expect(flow.canCancel)
            if index < order.count - 1 { accept(.stepPassed(step), on: &flow) }
        }
        accept(.installStarted, on: &flow)
        #expect(flow.state == .installing)
        #expect(!flow.canCancel)
    }

    @Test func theStepsRunInTheOrderTheDesignGives() {
        #expect(VerifyStep.allCases == [.checksum, .gatekeeperImage, .mount, .appIdentity, .appSignature, .gatekeeperApp])
        #expect(VerifyStep.checksum.next == .gatekeeperImage)
        #expect(VerifyStep.gatekeeperImage.next == .mount)
        #expect(VerifyStep.mount.next == .appIdentity)
        #expect(VerifyStep.appIdentity.next == .appSignature)
        #expect(VerifyStep.appSignature.next == .gatekeeperApp)
        #expect(VerifyStep.gatekeeperApp.next == nil)
    }

    @Test func aFailureFromEveryBusyState() {
        let busy: [InstallFlow] = [
            after(.checkStarted),
            after(.checkStarted, .updateFound(release), .downloadStarted),
            verifying(.checksum), verifying(.gatekeeperImage), verifying(.mount),
            verifying(.appIdentity), verifying(.appSignature), verifying(.gatekeeperApp),
            installingFlow,
        ]
        for var start in busy {
            accept(.failure(.installFailed), on: &start)
            #expect(start.state == .failed(.installFailed))
        }
    }

    @Test func cancelFromDownloading() {
        var flow = after(.checkStarted, .updateFound(release), .downloadStarted, .downloadProgress(0.4))
        #expect(flow.canCancel)
        accept(.cancel, on: &flow)
        #expect(flow.state == .cancelled)
        #expect(!flow.canCancel)
        #expect(flow.release == release)
    }

    @Test func cancelFromEveryVerifyStep() {
        for step in VerifyStep.allCases {
            var flow = verifying(step)
            #expect(flow.canCancel)
            accept(.cancel, on: &flow)
            #expect(flow.state == .cancelled)
        }
    }

    @Test func failedReturnsToAvailableOnRetry() {
        var flow = after(.checkStarted, .updateFound(release), .downloadStarted, .failure(.downloadFailed))
        #expect(flow.state == .failed(.downloadFailed))
        accept(.retry, on: &flow)
        #expect(flow.state == .available(release))
        #expect(flow.release == release)
    }

    @Test func cancelledReturnsToAvailableOnRetry() {
        var flow = after(.checkStarted, .updateFound(release), .downloadStarted, .cancel)
        accept(.retry, on: &flow)
        #expect(flow.state == .available(release))
    }

    @Test func retryWorksFromEveryStageAFailureCanHappenIn() {
        let failed: [InstallFlow] = [
            after(.checkStarted, .updateFound(release), .downloadStarted, .failure(.downloadFailed)),
            verifying(.checksum).applying(.failure(.checksumMismatch)),
            verifying(.gatekeeperApp).applying(.failure(.appRejected)),
            installingFlow.applying(.failure(.installFailed)),
            // A check that failed while an update was already on offer keeps that offer.
            after(.checkStarted, .updateFound(release), .checkStarted, .failure(.network)),
        ]
        for var start in failed {
            accept(.retry, on: &start)
            #expect(start.state == .available(release))
        }
    }

    @Test func retryIsRepeatable() {
        var flow = after(.checkStarted, .updateFound(release))
        for _ in 0..<3 {
            accept(.downloadStarted, on: &flow)
            accept(.failure(.downloadFailed), on: &flow)
            accept(.retry, on: &flow)
            #expect(flow.state == .available(release))
        }
    }

    @Test func aFailedCheckWithNothingOnOfferHasNothingToRetry() {
        var flow = after(.checkStarted, .failure(.network))
        reject(.retry, on: &flow)
        #expect(flow.state == .failed(.network))
        // The way out is a new check.
        accept(.checkStarted, on: &flow)
        #expect(flow.state == .checking)
    }

    @Test func dismissingFromTheEndStatesGoesIdle() {
        let endings: [InstallFlow] = [
            after(.checkStarted, .noUpdateFound),
            after(.checkStarted, .updateFound(release)),
            after(.checkStarted, .failure(.network)),
            after(.checkStarted, .updateFound(release), .downloadStarted, .failure(.downloadFailed)),
            after(.checkStarted, .updateFound(release), .downloadStarted, .cancel),
        ]
        for var start in endings {
            accept(.dismiss, on: &start)
            #expect(start.state == .idle)
            #expect(start.release == nil)
        }
    }

    // MARK: A newer release

    @Test func aRecheckThatFindsANewerReleaseReplacesTheOffer() {
        var flow = after(.checkStarted, .updateFound(release), .checkStarted)
        #expect(flow.state == .checking)
        accept(.updateFound(Self.newer), on: &flow)
        #expect(flow.state == .available(Self.newer))
        #expect(flow.release == Self.newer)
    }

    @Test func aRecheckThatFindsNothingClearsTheOffer() {
        var flow = after(.checkStarted, .updateFound(release), .checkStarted)
        accept(.noUpdateFound, on: &flow)
        #expect(flow.state == .upToDate)
        #expect(flow.release == nil)
    }

    @Test func aRetryAfterAFailedRecheckOffersTheOldReleaseAgain() {
        var flow = after(.checkStarted, .updateFound(release), .checkStarted, .failure(.serverError))
        #expect(flow.release == release)
        accept(.retry, on: &flow)
        #expect(flow.state == .available(release))
    }

    // MARK: Cancel is allowed only while downloading and verifying

    @Test func canCancelOnlyWhileDownloadingOrVerifying() {
        #expect(!InstallFlow().canCancel)
        #expect(!after(.checkStarted).canCancel)
        #expect(!after(.checkStarted, .noUpdateFound).canCancel)
        #expect(!after(.checkStarted, .updateFound(release)).canCancel)
        #expect(after(.checkStarted, .updateFound(release), .downloadStarted).canCancel)
        for step in VerifyStep.allCases { #expect(verifying(step).canCancel) }
        #expect(!installingFlow.canCancel)
        #expect(!installingFlow.applying(.failure(.installFailed)).canCancel)
        #expect(!after(.checkStarted, .updateFound(release), .downloadStarted, .cancel).canCancel)
        #expect(!after(.checkStarted, .failure(.network)).canCancel)
    }

    @Test func cancelIsRejectedEverywhereElse() {
        let notCancellable: [InstallFlow] = [
            InstallFlow(),
            after(.checkStarted),
            after(.checkStarted, .noUpdateFound),
            after(.checkStarted, .updateFound(release)),
            installingFlow,
            after(.checkStarted, .failure(.network)),
            after(.checkStarted, .updateFound(release), .downloadStarted, .cancel),
        ]
        for var start in notCancellable {
            let before = start
            reject(.cancel, on: &start)
            #expect(start == before)
        }
    }

    @Test func installingCannotBeCancelledOrGoBackToDownloading() {
        var flow = installingFlow
        let before = flow
        reject(.cancel, on: &flow)
        reject(.downloadStarted, on: &flow)
        reject(.downloadProgress(0.5), on: &flow)
        reject(.downloadFinished, on: &flow)
        reject(.stepPassed(.checksum), on: &flow)
        reject(.retry, on: &flow)
        reject(.dismiss, on: &flow)
        reject(.checkStarted, on: &flow)
        #expect(flow == before)
    }

    // MARK: Late events after a cancel or a failure are ignored

    @Test func aFailureArrivingAfterACancelIsRejected() {
        var flow = after(.checkStarted, .updateFound(release), .downloadStarted, .cancel)
        reject(.failure(.downloadFailed), on: &flow)
        #expect(flow.state == .cancelled)
    }

    @Test func progressOrCompletionArrivingAfterACancelIsRejected() {
        var flow = after(.checkStarted, .updateFound(release), .downloadStarted, .cancel)
        reject(.downloadProgress(0.9), on: &flow)
        reject(.downloadFinished, on: &flow)
        #expect(flow.state == .cancelled)
        var cancelledMidway = verifying(.mount).applying(.cancel)
        reject(.stepPassed(.mount), on: &cancelledMidway)
        reject(.installStarted, on: &cancelledMidway)
        #expect(cancelledMidway.state == .cancelled)
    }

    @Test func aSecondFailureIsRejected() {
        var flow = after(.checkStarted, .updateFound(release), .downloadStarted, .failure(.downloadFailed))
        reject(.failure(.checksumMismatch), on: &flow)
        #expect(flow.state == .failed(.downloadFailed))
    }

    // MARK: Illegal transitions

    @Test func stepsCannotBeSkippedRepeatedOrReordered() {
        var flow = verifying(.gatekeeperImage)
        let before = flow
        reject(.stepPassed(.checksum), on: &flow)        // an earlier step again
        reject(.stepPassed(.mount), on: &flow)           // a later step
        reject(.stepPassed(.gatekeeperApp), on: &flow)   // the last, skipping ahead
        reject(.installStarted, on: &flow)               // installing before the last step
        reject(.downloadFinished, on: &flow)
        #expect(flow == before)
    }

    @Test func theLastStepEndsWithInstallingNotAStepPassed() {
        var flow = verifying(.gatekeeperApp)
        let before = flow
        reject(.stepPassed(.gatekeeperApp), on: &flow)
        #expect(flow == before)
        accept(.installStarted, on: &flow)
        #expect(flow.state == .installing)
    }

    @Test func installingCannotStartBeforeTheLastStep() {
        for step in VerifyStep.allCases where step != .gatekeeperApp {
            var flow = verifying(step)
            reject(.installStarted, on: &flow)
            #expect(flow.state == .verifying(step: step))
        }
    }

    @Test func downloadingCannotBeSkippedOrRestarted() {
        var offered = after(.checkStarted, .updateFound(release))
        reject(.downloadFinished, on: &offered)
        reject(.downloadProgress(0.5), on: &offered)
        reject(.installStarted, on: &offered)
        reject(.stepPassed(.checksum), on: &offered)
        #expect(offered.state == .available(release))
        var downloading = after(.checkStarted, .updateFound(release), .downloadStarted)
        reject(.downloadStarted, on: &downloading)
        reject(.installStarted, on: &downloading)
        reject(.stepPassed(.checksum), on: &downloading)
        reject(.retry, on: &downloading)
        reject(.dismiss, on: &downloading)
        reject(.checkStarted, on: &downloading)
        #expect(downloading.state == .downloading(progress: 0))
    }

    @Test func verifyingCannotGoBackToDownloading() {
        var flow = verifying(.mount)
        reject(.downloadStarted, on: &flow)
        reject(.downloadProgress(0.2), on: &flow)
        reject(.retry, on: &flow)
        reject(.dismiss, on: &flow)
        reject(.checkStarted, on: &flow)
        #expect(flow.state == .verifying(step: .mount))
    }

    @Test func aCheckHasNoOtherWayOut() {
        var flow = after(.checkStarted)
        reject(.checkStarted, on: &flow)
        reject(.downloadStarted, on: &flow)
        reject(.downloadFinished, on: &flow)
        reject(.installStarted, on: &flow)
        reject(.cancel, on: &flow)
        reject(.retry, on: &flow)
        reject(.dismiss, on: &flow)
        #expect(flow.state == .checking)
    }

    @Test func nothingHappensToAnIdleFlowExceptACheck() {
        var flow = InstallFlow()
        let nonsense: [Event] = [
            .updateFound(release), .noUpdateFound, .downloadStarted, .downloadProgress(0.5), .downloadFinished,
            .stepPassed(.checksum), .installStarted, .failure(.network), .cancel, .retry, .dismiss,
        ]
        for event in nonsense { reject(event, on: &flow) }
        #expect(flow == InstallFlow())
    }

    // MARK: The whole table

    /// Every (state, event) pair outside this list must be rejected, leaving the flow as it was. Each row is a legal
    /// transition: the flow is brought to `from` by events, then the event gives `to`.
    @Test func everythingOutsideTheTableIsRejected() {
        let offered = after(.checkStarted, .updateFound(release))
        let downloading = after(.checkStarted, .updateFound(release), .downloadStarted)
        let installing = installingFlow
        let failedOffer = after(.checkStarted, .updateFound(release), .downloadStarted, .failure(.downloadFailed))
        let failedCheck = after(.checkStarted, .failure(.network))
        let cancelled = after(.checkStarted, .updateFound(release), .downloadStarted, .cancel)
        let upToDate = after(.checkStarted, .noUpdateFound)
        let handedOff = verifying(.gatekeeperApp).applying(.handOff)
        var starts: [(name: String, flow: InstallFlow)] = [
            ("idle", InstallFlow()), ("checking", after(.checkStarted)), ("available", offered),
            ("downloading", downloading), ("installing", installing), ("failedOffer", failedOffer),
            ("failedCheck", failedCheck), ("cancelled", cancelled), ("upToDate", upToDate),
            ("handedOff", handedOff),
        ]
        for step in VerifyStep.allCases { starts.append(("verifying \(step)", verifying(step))) }

        let events: [Event] = [
            .checkStarted, .updateFound(release), .noUpdateFound, .downloadStarted, .downloadProgress(0.5), .downloadFinished,
            .stepPassed(.checksum), .stepPassed(.gatekeeperImage), .stepPassed(.mount), .stepPassed(.appIdentity),
            .stepPassed(.appSignature), .stepPassed(.gatekeeperApp), .installStarted, .handOff, .failure(.network),
            .cancel, .retry, .dismiss,
        ]

        // (state name, event) pairs that are legal.
        var legal: Set<String> = [
            "idle|checkStarted", "upToDate|checkStarted", "available|checkStarted", "failedOffer|checkStarted",
            "failedCheck|checkStarted", "cancelled|checkStarted",
            "checking|updateFound", "checking|noUpdateFound", "checking|failure",
            "available|downloadStarted",
            "downloading|downloadProgress", "downloading|downloadFinished", "downloading|cancel", "downloading|failure",
            "installing|failure",
            "failedOffer|retry", "cancelled|retry",
            "available|dismiss", "upToDate|dismiss", "failedOffer|dismiss", "failedCheck|dismiss", "cancelled|dismiss",
            "verifying gatekeeperApp|installStarted", "verifying gatekeeperApp|handOff", "handedOff|dismiss",
        ]
        for step in VerifyStep.allCases {
            legal.insert("verifying \(step)|cancel")
            legal.insert("verifying \(step)|failure")
            if step != .gatekeeperApp { legal.insert("verifying \(step)|stepPassed:\(step)") }
        }

        func label(_ event: Event) -> String {
            switch event {
            case .checkStarted: "checkStarted"
            case .updateFound: "updateFound"
            case .noUpdateFound: "noUpdateFound"
            case .downloadStarted: "downloadStarted"
            case .downloadProgress: "downloadProgress"
            case .downloadFinished: "downloadFinished"
            case .stepPassed(let step): "stepPassed:\(step)"
            case .installStarted: "installStarted"
            case .handOff: "handOff"
            case .failure: "failure"
            case .cancel: "cancel"
            case .retry: "retry"
            case .dismiss: "dismiss"
            }
        }

        var accepted = 0
        for (name, start) in starts {
            for event in events {
                var trial = start
                let result = trial.handle(event)
                let expected = legal.contains("\(name)|\(label(event))")
                #expect(result == expected, "\(name) + \(label(event)): accepted \(result), expected \(expected)")
                if !result { #expect(trial == start, "\(name) + \(label(event)) must leave the flow unchanged") }
                if result { accepted += 1 }
            }
        }
        // The table is complete: every row of it was exercised (checking+updateFound etc. each count once).
        #expect(accepted == legal.count)
    }

    // MARK: The wait before the relaunch

    /// What the window says while the installed app waits for a capture or recording to end before it restarts: a plain
    /// sentence like the failures', and one that doesn't claim the install is still running or that anything can be done.
    @Test func theRestartWaitIsOneCalmSentence() {
        let text = InstallFlow.restartWaitingText
        #expect(text == "Restarts when the capture or recording ends.")
        #expect(text.first?.isUppercase == true && text.last == "." && !text.contains("\n"))
        for word in ["Error", "error:", "!", "Oops", "Sorry", "failed"] { #expect(!text.contains(word), "mentions \(word)") }
    }

    // MARK: The failures' words

    @Test func everyFailureHasAPlainMessage() {
        #expect(UpdateFailure.allCases.count == 19)
        for failure in UpdateFailure.allCases {
            let message = failure.message
            #expect(!message.isEmpty, "\(failure)")
            #expect(message.last == ".", "\(failure): \(message)")
            #expect(message.first?.isUppercase == true, "\(failure): \(message)")
            #expect(!message.contains("  "), "\(failure): \(message)")
            #expect(!message.contains("\n"), "\(failure): \(message)")
            #expect(message.count < 140, "\(failure): \(message)")
        }
    }

    @Test func everyMessageIsDifferent() {
        let messages = UpdateFailure.allCases.map(\.message)
        #expect(Set(messages).count == messages.count)
    }

    @Test func messagesAreCalmAndPlain() {
        let banned = ["Error", "error:", "!", "Oops", "Sorry", "failed:"]
        for failure in UpdateFailure.allCases {
            for word in banned { #expect(!failure.message.contains(word), "\(failure) mentions \(word)") }
        }
    }

    @Test func messagesForFailedVerificationSayNothingWasChanged() {
        let checks: [UpdateFailure] = [
            .downloadFailed, .sizeMismatch, .checksumFileInvalid, .checksumMismatch, .imageRejected, .mountFailed,
            .appMissing, .appIdentifierMismatch, .appVersionMismatch, .signatureInvalid, .signerMismatch, .appRejected,
        ]
        for failure in checks {
            #expect(failure.message.contains("nothing was changed"), "\(failure): \(failure.message)")
        }
    }

    /// The sentence the checksum failure is worded as.
    @Test func theChecksumMessageIsTheDesignsExample() {
        #expect(UpdateFailure.checksumMismatch.message == "The download didn't match its published checksum, so nothing was changed.")
    }

    /// `installFailed` is for what goes wrong before the swap, when the current version is, in fact, still installed.
    @Test func installFailuresSayTheCurrentVersionIsStillThere() {
        #expect(UpdateFailure.installFailed.message.contains("current version"))
    }

    /// After the swap the new version is in place, so a failure then must not say the old one is still installed.
    @Test func aFailureAfterTheSwapSaysTheAppWasUpdated() {
        for failure in [UpdateFailure.relaunchFailed, .quitPending] {
            let message = failure.message
            #expect(message.hasPrefix("ClearShot was updated."), "\(failure)")
            #expect(!message.contains("current version"), "\(failure)")
            #expect(!message.contains("nothing was changed"), "\(failure)")
        }
    }

    /// The relaunch couldn't be started: the old app is still running, so it has to be quit before the new version is
    /// the one in use, and then opened again, wherever it lives.
    @Test func aRelaunchThatCouldNotStartSaysToQuitAndOpenTheAppAgain() {
        #expect(UpdateFailure.relaunchFailed.message == "ClearShot was updated. Quit ClearShot and open it again to use the new version.")
        #expect(!UpdateFailure.relaunchFailed.message.contains("Applications"))
    }

    /// The relaunch was asked for but the app hasn't quit (a quit that something held up): quitting finishes it, and the
    /// relaunch helper opens the app again on its own.
    @Test func aQuitThatIsStillPendingSaysToQuit() {
        #expect(UpdateFailure.quitPending.message == "ClearShot was updated. Quit ClearShot to finish; it opens again on its own.")
    }

    /// The swap stopped partway and the old copy couldn't be put back: not "the current version is still installed", and
    /// not "nothing was changed".
    @Test func anAppThatCouldNotBePutBackSaysSo() {
        let message = UpdateFailure.appNotRestored.message
        #expect(message.contains("missing"))
        #expect(!message.contains("current version"))
        #expect(!message.contains("nothing was changed"))
    }

    @Test func onlyTheFailuresAfterTheSwapLeaveTheNewVersionInstalled() {
        for failure in UpdateFailure.allCases {
            let expected = failure == .relaunchFailed || failure == .quitPending
            #expect(failure.newVersionIsInstalled == expected, "\(failure)")
        }
    }

    /// Trying again would install what is already installed, or can't work with the app missing from its folder.
    @Test func noTryAgainAfterTheSwapOrAnAppThatCouldNotBePutBack() {
        for failure in UpdateFailure.allCases {
            let expected = failure == .relaunchFailed || failure == .quitPending || failure == .appNotRestored
            #expect(failure.canTryAgain == !expected, "\(failure)")
        }
    }
}

private extension InstallFlow {
    /// This flow after one more event, which must be accepted.
    func applying(_ event: InstallFlow.Event) -> InstallFlow {
        var copy = self
        let accepted = copy.handle(event)
        #expect(accepted, "\(event) should be accepted")
        return copy
    }
}
