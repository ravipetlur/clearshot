# Test consolidation: cut list

Goal: a smaller, faster suite with the same coverage. Four read-only audits, one per group of test targets, proposed what to remove, what to merge into parameterized tests, and how to make the slowest tests cheaper. Nothing here is applied yet.

## Totals (test functions)

| Group | Now | After | Removed | Merged away | Lines saved |
|---|---|---|---|---|---|
| CSAnnotation | 1,107 | ~985 | 19 | ~103 | ~1,000 |
| CSCore, CSUpdate, CSAPI | 916 | ~680 | 73 | ~164 | ~1,400 |
| CSSensitive, CSOCR, CSHistory | 708 | ~572 | 28 | ~108 | ~600 |
| CSCapture, CSWebP, CSRecording, CSScrolling | ~769 | ~703 | 14 | ~52 | ~500 |
| **All** | **~3,500** | **~2,940** | **134** | **~427** | **~3,500** |

Merging keeps every case: a case becomes an `arguments:` row or one more expectation.

## Never removed (parameterized at most)

- Redaction safety: RedactionLeakTests, RedactionEdgeTests, TextOnlyRedactionTests, the magnifier and Erase "never shows what a redaction hides" tests, secrets-mask placement.
- File-format compatibility: DocumentVersionTests and every "written before X still decodes" test.
- Update security: signature, checksum, Gatekeeper, downgrade, rollback, feed and endpoint checks, verification order.
- Sensitive-info detection, including every false-positive case and the linear-time guards.
- WebP and image input guards, file-safety and data-loss tests, history privacy, stored preference keys.
- Every test tied to a past bug or review round.
- CSAPI input validation and consent text.

## 1. Remove (134)

Tests that restate a constant or default, test Swift or Foundation rather than our code, test a trivial forwarder, or are fully covered by a named test.

- **CSAnnotation (19):**
  - **Restated constants and defaults:**
    - ModelTests: defaultColorIsRed, defaultsAreTheDecidedOnes, saveFormatsHaveTitlesAndExtensions.
    - BackgroundModelTests: theDefaultsAreTheDecidedOnes, theCatalogHasTwentyGradients with its 20-row table, theColorSwatchesAreTheDecidedOnes, newPrefsHaveTheirDefaults.
    - SizeUnitTests: unitsHaveTitlesAndAbbreviations.
    - CanvasGeometryTests: theMenuListsTheRatiosInOrder.
    - EraseModelTests: eraseIsARedactStyleWithATitle.
  - **Covered by another test:**
    - MagnifierTests: magnifierLetterIsFreeByDefault (ToolKeysTests covers it).
    - MaskObjectTests: aMaskSurvivesTheDocumentBeingWrittenAndRead, aCopyOfARedactionThePersonDrewIsTheSameRedactionWithANewID.
    - RedactionChangesTests: aNewRedactionAddsCoverage.
    - RendererTests: blackOutIsSolidBlack.
  - **Trivial or not our code:**
    - EditorGuidesTests: theChoiceOfAPCAIsRemembered (plain get/set).
    - MaskObjectTests: aCopyCanTakeAGivenID (pass-through), theMarkerKeyIsReadWhenPresentAndAnUnknownKeyIsIgnored (JSONDecoder behaviour).
  - **Misnamed:** EditorPixelsTests undoMakesTheEarlierPictureAgain never calls undo. Fix it to undo, or remove it.
- **CSCore, CSUpdate (73):**
  - Restated defaults in CapturePrefs, Preferences, QuickAccessPrefs, UpdatePrefs.
  - Pure round-trips already in PreferencesTests.
  - Shortcut and hotkey tests each fully covered by a named broader test: 8 in HotkeyRegistryTests, 11 in ShortcutRecorderRulesTests, 5 in ShortcutTextTests.
  - InstallFlow rejection tests covered by its full rejection table.
  - InstallSteps call-order duplicates of the exact call-list test.
  - CheckAnswer summaries covered by its per-cell tests.
  - Synthesized Hashable and plain getters in VersionNumberTests.
  - A test of Swift's throw/catch.
- **CSSensitive, CSOCR, CSHistory (28):**
  - Empty theModuleLoads.
  - Restated UI strings in SensitiveKindTests and MaskCommandTextTests.
  - Forwarder repeats in SensitiveButtonTextTests.
  - BadgeState cases already in its "events that change nothing" table.
  - Default-argument tests in MaskGeometry, OCRMark and SavedFileNotice.
  - TextRecognizer languagesComeFromVision (covered by RecognitionLanguageTests).
  - HistoryFilter titles.
- **CSCapture, CSWebP, CSRecording, CSScrolling (14):**
  - **Restated constants:**
    - SelectionRatioTests: presetsAreTheDecidedOnes.
    - AllInOneController: command-title and button-label constants (move the symbols check first).
    - EncoderPlanTests: theMeasuredCeilingsAndPicksAreTheDecidedOnes.
    - RecordingPrefsTests: frame rates, warning dialogs, resolution titles.
    - ClickRippleStyleTests: two size and opacity constant tests.
    - PreviewPlacementTests: theSizesAreTheDecidedOnes.
  - **Covered by another test:**
    - ImageEncoderTests: losslessWebPKeepsTransparency.
    - EncoderRoundTripTests: aFullyTransparentImageKeepsItsAlpha.
    - FixtureTests: theFixturesAreDeterministic (the golden digests cover it).
    - DistanceCodesTests: theMapMatchesTheRFCsWorkedWords.

## 2. Merge into parameterized tests (~427 functions fold away)

Typical patterns: one test per enum case or per input with copy-pasted bodies; several tests asserting rows of one decision table.

- **CSAnnotation:**
  - AutoApplyTests 11→1, PixelSelection geometry 15→5, zoom fitting 6→1.
  - HitTest 7→1, TextLayout 4→1.
  - Hex colours 5→1, CounterLabel 3→1, DocumentTransform 3→1.
  - RedactionChanges 20→2 (every case kept), nudge coalescing 4→1.
  - Rendered-base and mask mapping 25→5.
  - EditorMasks 4→2, Storage rejections 3→1, ToolKeys rejections 3→1.
  - Smaller folds of 2→1.
- **CSCore, CSUpdate, CSAPI:**
  - DesktopDrop 21→3, clipboard ownership 7→1.
  - Shortcut recorder and session-key groups 11→3, MenuKeyEquivalent 4→1, legacy shortcut migration 10→1.
  - CheckAnswer 8→1, StatusIconAnchor 8→1.
  - ChecksumFile good and malformed lines into their tables (security: cases kept).
  - ReleaseFeed asset, draft and garbage groups ~17→4.
  - UpdateDecision offers 10→1, ReplaceRecovery plan 8→1 exact 32-row table.
  - UpdateSchedule 12→2, InstallFlow and InstallSteps groups ~20→6.
- **CSSensitive, CSOCR, CSHistory:**
  - Key-and-token positives 10→1, look-alikes 9→1, JWT 4→1.
  - Card not-a-card 8→1, kinds-off 4→1.
  - SecretRedaction ampersand 4→1, merge rules 5→1.
  - BadgeState transitions 6→1, SensitiveButtonState phases 7→1.
  - MaskCommandText count wording 12→4, TextOutput links 5→1, TileReadingReplay 4→1, TextAssembler 6→2.
  - History tolerance, time, delete-rule and notice tables 3→1 each.
- **CSCapture, CSWebP, CSRecording, CSScrolling:**
  - AfterCapturePlan 12→2, ClipboardWriter 4→1.
  - SelectionController edge modifiers 4→1, rejected rects 7→2.
  - BitWriter 6→1, palette packing 4→1.
  - EncoderPlan 4→1, RecordingStopTime 5→1, RecoveryNotice 4→1.
  - PreviewPlacement 5→1, smaller 2→1 and 3→1 folds.

## 3. Make slow tests cheaper (same coverage)

- **WebP:**
  - Speed tests encode two 2560×1440 pictures (up to 30 s each in a full run): use 1280×720 with a scaled ceiling, or move them behind a performance tag.
  - The three 1001×999 fixtures exist only to be above the 262,144-pixel sample limit with odd sides. 521×519 keeps both and costs about 3.7× less across ~30 passes.
  - Size tests encode an extra time just to round-trip: decode the file already made. Cache the shared UI-screenshot fixture.
- **Recording:**
  - Seven exporter tests each build the same 6 s 640×360 source, in serialized suites: build it once.
  - GIF cancel test: 2 s 320×180 instead of 6 s 640×360.
  - Thousand-frame buffer test: compare frame 10 with frame 200.
  - About 3 s of real sleeps in the writer tests.
- **Annotation:**
  - The 6K Erase speed test (85 MB bitmap, 5 runs): performance tag, or 2048×1152 with a scaled ceiling.
  - A 6000×4000 desktop picture that only needs 600×400.
  - A fixed 400 ms sleep in the contrast test: poll instead.
- **Sensitive:**
  - The phone-number window sweeps run ~3,500 system-detector calls: thin the positions and paddings to the boundary cases.
  - Cut repeated Vision scans that recorded-fixture tests already cover.
- **Update and core:**
  - Checksum tests write files up to 5 MB: the 64 KiB and 1 MiB boundaries cover chunking.
  - A 200 ms real sleep.
  - `.timeLimit` on two tests that would hang on a regression.
  - Gather failures in two loops of ~34k and ~550 cases, instead of one expectation each.

## How it would be applied

One branch from main and one pull request, done in four parallel parts (one per group above). Each part:
- keeps every protected test;
- runs its targets' tests before and after;
- for each slow-test change, shows that the cheaper test still fails when the code it guards is broken.

Then the full suite, `make build` warning-free, and a CI time comparison in the PR description.
