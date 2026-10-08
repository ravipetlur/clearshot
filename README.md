# ClearShot

[![CI](https://github.com/ravipetlur/clearshot/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ravipetlur/clearshot/actions/workflows/ci.yml)

A screenshot and screen recording app for macOS that lives in the menu bar. It was inspired by popular macOS screenshot tools, and it works entirely on your Mac: nothing is uploaded, and there is no account or cloud service.

## Features

- **Screenshots:** Capture Area, Capture Window (with or without its shadow and wallpaper), Capture Fullscreen, Capture Previous Area and a Self-Timer, plus All-In-One, one overlay for every kind of capture.
- **Quick Access Overlay:** each capture appears as a thumbnail you can drag into any app, copy, save, annotate, pin or delete.
- **Annotate:** an editor with shapes, lines and arrows, text, redaction (blur and pixelate), spotlight, counters, pen and highlighter, crop and resize, images, and a background tool (gradients, wallpapers, padding, shadow and rounded corners). Projects save as editable `.clearshot` documents.
- **Capture Text:** reads the text (and QR codes) in an area or a window and copies it.
- **Scrolling Capture:** stitches a page longer than the screen, scrolling by hand or by itself.
- **Screen Recording:** an area, a window or a whole display, as MP4 or GIF, with the microphone and system audio, highlighted clicks, a Video Editor to trim and compress, and recovery after a crash.
- **Pins:** screenshots that float above every window.
- **Capture History:** every capture kept for a set time, to restore, reopen or drag out.
- **Hide Desktop Icons,** global hotkeys for every action, and `clearshot://` URL commands for scripts, Shortcuts and launchers.

## Install

Download `ClearShot-<version>.dmg` from the [latest release](https://github.com/ravipetlur/clearshot/releases/latest), open it and drag ClearShot to Applications. ClearShot needs macOS 27 on Apple Silicon.

Each release's notes say whether it is signed. A build signed with a Developer ID and notarized by Apple opens like any other app. An unsigned build (signed ad hoc, without a Developer ID) needs one more step the first time:

1. Open ClearShot from Applications. macOS says it can't be opened; click Done.
2. Open System Settings › Privacy & Security, scroll down to Security, click **Open Anyway** beside the message about ClearShot, and confirm with your password or Touch ID. ClearShot opens, and from then on opens normally.

As an option, you can remove the quarantine flag in Terminal instead: `xattr -dr com.apple.quarantine /Applications/ClearShot.app`. Either way skips Gatekeeper's check for that copy, so [verify the download](#verifying-a-download) first.

### Updating an unsigned build

macOS keeps the Screen Recording, Microphone and Accessibility permissions for an app's code signature. An ad hoc signature is different in every build, so to macOS each new version of an unsigned build is a different app: after updating, it asks for the permissions again, and System Settings › Privacy & Security may list ClearShot twice (remove the old entry). A build signed with a Developer ID keeps them across updates, as does a build of your own signed with your certificate (see [Signing](#signing)).

### Verifying a download

Each release has the DMG's SHA-256 checksum beside it, and an attestation of where the DMG was built. In the folder you downloaded both files to:

    shasum -a 256 -c ClearShot-<version>.dmg.sha256
    gh attestation verify ClearShot-<version>.dmg --repo ravipetlur/clearshot

The first checks the DMG against the published checksum (it prints `OK`). The second, with the [GitHub CLI](https://cli.github.com), checks that this repository's release workflow built that exact file, and shows the commit it was built from.

## Requirements for building

- macOS 27 on Apple Silicon
- Xcode 27
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

Swift Package Manager fetches the two dependencies, [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) and [libwebp](https://github.com/SDWebImage/libwebp-Xcode). GIFs come from ClearShot's own encoder, so nothing else is needed.

## Building

    cp Config/Local.example.xcconfig Config/Local.xcconfig   # optional; see "Signing" below
    make build      # build the Debug app into build/DerivedData
    make run        # build the Debug app and launch it
    make install    # build the Release app, copy it to /Applications and launch it
    make dmg        # build the Release app and pack it into build/ClearShot-<version>.dmg (VERSION=1.2.0 to choose)
    make test       # run ClearShotKit's unit tests

The Xcode project is generated from `project.yml` (`make generate`), so edit `project.yml` rather than `ClearShot.xcodeproj`. Most of the logic lives in the `ClearShotKit` Swift package, which builds and tests on its own (`swift test --package-path ClearShotKit`).

### Signing

`Config/Defaults.xcconfig` builds ClearShot as `com.example.clearshot`, signed to run locally (an ad hoc signature, no team). That works out of the box, but an ad hoc signature changes with every build, so macOS asks for Screen Recording and the other permissions again after each rebuild.

To keep them, copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` (it's git-ignored) and set your own bundle identifier, `CODE_SIGN_IDENTITY = Apple Development` and your `DEVELOPMENT_TEAM`. macOS keys ClearShot's permissions, preferences and keychain item to the bundle identifier, so keep it once chosen.

Every build has the hardened runtime on, with one entitlement, `com.apple.security.device.audio-input` (the microphone), and no `get-task-allow` (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`). So no other process can attach to ClearShot, or inject code into it and borrow its Screen Recording permission. Xcode's debugger can't attach either: set `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` to `YES` locally to debug, and don't commit it. Check an installed copy with `codesign -dvv --entitlements - /Applications/ClearShot.app` (`flags=0x10000(runtime)`, audio-input only).

## Permissions

- **Screen Recording** is needed from the start, for every capture.
- **Accessibility** is asked for the first time Scrolling Capture's Auto-Scroll needs it.
- **Microphone** access is asked once a microphone has been chosen and nothing is recording (after that recording, or as Ready closes), so the prompt never ends up in a video.
- **The Desktop folder:** dropping files on the desktop while its icons are hidden may ask for access to it once.

ClearShot also keeps one item in your login keychain: the answer to the URL commands' consent prompt (see [URL commands](#url-commands)).

## Self-test

Debug builds have **Run Capture Self-Test** in the menu bar menu. It captures every display, an area, a window and the wallpaper, encodes all four formats, reads a line of text, checks that Scrolling Capture's region stream has the right size and leaves out ClearShot's windows (a red square flashes for about a second), records 3 s of an area without audio (a red square shows for about 4.5 s: kept in one recording, left out of another), and writes `~/Library/Logs/ClearShot/selftest.txt`. Run it after granting Screen Recording. The self-test is compiled into Debug builds only (`make run`), not into `make install`.

## Shortcuts

Settings › Shortcuts lists every action that can have a global hotkey, in groups (General, Screenshots, Screen Recording, Scrolling Capture, Text Recognition, Quick Access Overlay, Pin), with a search field that also finds keywords ("pixelate", "marker", "window"). Only ⇧⌘3 (Fullscreen), ⇧⌘4 (Capture Area) and ⇧⌘5 (All-In-One) have defaults. macOS's own screenshot shortcuts use the same keys, so turn those off in System Settings › Keyboard › Keyboard Shortcuts › Screenshots (onboarding offers the link).

- **Reset:** the small arrow button beside a shortcut, or Reset to default in the row's right-click menu, puts its default back; it is dimmed at the default. Restore Defaults resets every shortcut and the Annotate tool letters.
- **Conflicts:** a shortcut another action already has says "Shortcut is used for another action" ("⇧⌘4 is assigned to “Capture Area”."), and the action keeps its old shortcut; "Use old shortcut" closes the alert. Shortcuts macOS reserves are refused too.
- **Annotate tools,** the last section, lists the editor's tool letters, the same ones as Settings › Annotate › Tool shortcuts, each with its reset button. Annotate's menu commands (Copy, Duplicate, Save and the rest) follow System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts.
- **Record Window** (Screen Recording; no default key, and not in the menu bar menu) opens the recorder picking a window: hover highlights one, a click gives Ready on it, and Space switches to areas.
- **Shortcuts another app holds** can't be registered, and don't work: at launch, a HUD says "Another app is using some of ClearShot's shortcuts", and the log names them. Choose others, or quit that app and restart ClearShot.

## All-In-One

⇧⌘5 (or menu bar › All-In-One) opens one overlay for every kind of capture. Drag a selection: it stays, with handles, and a toolbar appears under it.

- **Keys:** A or Return captures the area, ⌘C captures it to the clipboard (as Capture Area & Copy), F the whole display without the cursor (every display with "Fullscreen captures every display" on), Space or W switches to window mode and back, T runs the self-timer, O is Capture Text, S is Scrolling Capture. Esc or a right-click cancels. R switches to Record Screen's Ready on the selection (Select without one). A, Return, T, O and S need a selection. The letters are fixed; they follow the keyboard layout, so a non-Latin input source can't type them (the buttons still work).
- **Adjusting:** drag a handle (⇧ keeps the aspect, ⌥ resizes from the centre), drag inside to move, arrows move 1 pt (⌘ for 10 pt), ⇧-arrows resize. A click outside keeps the selection; a new drag, on any display, replaces it.
- **The toolbar:** the seven modes (hover for the name and key), W × H in points (Return applies, Esc reverts), an aspect ratio list (Freeform, 1:1, 4:3, 3:2, 16:10, 16:9, 5:4, 9:16, 3:4, 2:3, 4:5, Custom and Swap; the choice is kept) and Toggle fullscreen. It sits under the selection, above it when there's no room, or inside a full-display selection.
- **Modifiers:** ⇧ held as the selection's drag began skips the background preset when that area is captured (A, Return, ⌘C, T or S); so does ⇧ on A, Return or the Area button. ⌃ on those three adds Copy.
- **Remember last selection** (Settings › Advanced › All-In-One, on by default) reopens All-In-One on the area you last captured from it. Its area captures (A, Return, ⌘C, T) also become Capture Previous Area's area.

## Capture Text

Capture Text (menu bar, or its hotkey) copies the text in an area you select, or in a window (Space). Capture Text With Line Breaks and Without Line Breaks have their own hotkeys; plain Capture Text follows Keep line breaks. Without line breaks, lines join with spaces, hyphenated words are rejoined ("infor-" + "mation"), and Chinese and Japanese join without a space.

- A QR code in the area is decoded, and its contents are the result, one per line.
- When the whole result is a single web link, ClearShot asks "Do you want to open this link?" (Open Link in Browser, Copy to Clipboard, Never open links). Never open links turns off Detect links. With a dialog open it doesn't ask: the text is copied and "Close the open dialog first" shows.
- The HUD says "Text has been copied" or "No text detected"; with Play sounds on, copied text plays a sound. No history item is made and no after-capture action runs.
- **Extract Text**, in a thumbnail's or a pin's right-click menu, reads that screenshot with its annotations.
- Settings › Advanced › Text recognition: Keep line breaks, Automatically detect language or a Primary language, Detect links.
- Big captures are read in tiles and show "Recognizing text…" first. The first recognition after a new build can take about 30 s; ClearShot warms Vision up 5 s after launch. While Capture Text (or All-In-One's O) reads, and while its link question is open, other captures say "A capture is already in progress".
- **Known limits:** on tiled captures, text in columns is read column by column (a table too), right-to-left lines crossing a tile seam join in the wrong order, and a QR code cut by a seam can be missed.

## Scrolling Capture

Scrolling Capture (menu bar, its hotkey, or S in All-In-One) captures a page longer than the screen, down or to the right.

1. **Select:** drag the part that scrolls ("Drag over the part of the screen that scrolls.") and adjust it as in All-In-One. The tips open the first time, and from the toolbar's Tips button.
2. **Ready:** Start Capture (Return), Auto-Scroll Down, Auto-Scroll Right, Cancel (Esc), Tips.
3. **Capturing:** the screen outside the region dims, a frame marks it, and a preview grows beside it. Scroll the page by hand; the first movement sets the direction, and scrolling up first is ignored. The control bar has Done (Return), Cancel (Esc) and the size so far. "Please slow down…" with "Scroll back up a little to continue" ("left" across) means a frame couldn't be matched: scroll back past where the preview ends, then go on slowly, and it clears with no gap or repeat. "Move the pointer here, then scroll" shows while the pointer is outside the region.

- **Auto-Scroll** scrolls for you and needs Accessibility. Without it, an alert offers Scroll by Hand or Open System Settings (which ends the capture). It moves the pointer into the region and puts it back afterwards; move the pointer out to pause it and reach Done. It finishes after five steps without movement. If it loses track it shows "Auto-Scroll stopped; scroll by hand" and the capture goes on by hand.
- **Start/Stop Capturing** (no default hotkey; set one in Settings › Shortcuts) starts from Ready and is Done while capturing.
- **Size cap:** 16 383 pixels along the direction in the saved image (32 766 Retina pixels with "Scale Retina screenshots to 1x" on). "Screenshot is very large" shows from about 85%, and at the cap the capture finishes by itself.
- The result goes through the after-capture actions like an area capture (thumbnail, copy, save, background preset, 1 px border). Pins, thumbnails and every other ClearShot window are left out of it.
- Changing a display during the capture ends it, keeping what was stitched.
- The control bar takes the keyboard, so click into the page before scrolling with keys.
- **What stitches:** sticky headers and footers (kept once), sticky sidebars and tables of contents up to about 30% of the region's width, floating buttons and chat bubbles (drawn once, at the end, with the page under them intact), images that load as they scroll in (if it warns, scroll back a little and go on), and a page you scrolled back on.
- **Known limits:** wider sticky sidebars, fixed elements taller than about 80 pt, a scroll bar thumb inside the region and pages of identical repeating content warn instead of stitching. A floating button over text, or a flat one-colour panel, can leave a sliver of itself in the page. A sidebar stuck along the whole height repeats its slice in each strip. Animations or videos in the region, and crooked scrolling, can stop the stitching.
- **A capture that keeps warning:** in Terminal, before capturing, run `log stream --level debug --style compact --predicate 'subsystem == "com.example.clearshot" AND category == "capture"' | tee ~/scrolling-capture.log` (with your own bundle identifier, if you set one), then capture until it sticks, scroll back past where the preview ends, scroll down slowly again and click Done. Each frame's verdict is logged ("by pieces", "stitched N lines, band B", "followed, nothing new"); the start, each run of unmatched frames and a summary also go to `clearshot.log` as "Scrolling capture:" lines.

## Screen Recording

Record Screen (menu bar, its hotkey, or R in All-In-One) records an area, a window or a whole display as an MP4.

1. **Select:** drag an area ("Drag to record a part of the screen. Press Space to select a window.") and adjust it as in All-In-One, or press Space and click a window: its frame becomes the selection (a window moved later isn't followed). Record Window starts with the window picker. Return with no selection records the whole display under the pointer. Esc cancels. With "Remember last selection" on, it opens in Ready on the last area.
2. **Ready:** the toolbar has Record Video, Record GIF, the microphone, System Audio, Highlight Clicks, W × H, the aspect ratio, Toggle fullscreen and Recording Settings (the gear), then a message: a warning, or the size and frame rate when the encoder caps it ("6720 × 3780 · 25 fps"). Return records the mode you used last, whose button is the prominent one.
3. **Countdown:** 3 s ("Show countdown"). The Record hotkey skips it; Stop or Delete on the bar cancels it.
4. **Recording:** the rest of the recorded display dims ("Dim screen while recording"), a 1 pt accent line marks an area, and the control bar sits under the area (inside a whole display; or at the top or bottom of the screen, Settings › Screen Recording › Controls position). It has Stop, the time, Pause/Resume, Restart and Delete. The bar never takes the keyboard, so Return and Esc stay with the app you're recording.

- **The menu bar icon** becomes a Stop button, with the time (`m:ss`) when "Display recording time in menu bar" is on; a click stops. It shows even when the icon is hidden, and its menu comes back when the recording ends. The first time, "Press to stop recording" points at it. While paused, a second item, Resume, sits beside it.
- **Pause** leaves no gap in the file (the region dims too while paused). **Restart** asks "Discard this recording and start a new one?" and starts a new take without a countdown. **Delete** asks "Are you sure you want to delete this recording?" and leaves nothing. Both have "Don't ask again"; Advanced › Reset All Warning Dialogs brings them back.
- **Hotkeys** (no defaults; set them in Settings › Shortcuts › Screen Recording): Record Screen / Stop Recording (opens the recorder, starts from Ready, skips the countdown, stops), Record Window (opens the recorder picking a window), Pause/Resume Recording and Restart Recording. While a recording is still saving they say "Still saving the recording", while a GIF is converting "Still creating a GIF".
- **The file** goes through the recording column of General › After capture (Quick Access, Copy and Save by default): it is moved into Capture History, never re-encoded; Save copies it under the name template as `.mp4`; Copy puts the file on the clipboard. With Play sounds on, start, pause and stop have sounds.
- **Frame rate and codec:** H.264 up to 4096 px a side and 85% of 450 Mpx/s; HEVC above that, with the frame rate capped at 85% of 760 Mpx/s (the hardware encoder's throughput, measured on Apple Silicon). A 6K display records natively at 25 fps, or at 60 with "Scale Retina videos to 1x" on (the default). Settings › Screen Recording › Video: Frame rate (60, 50, 30, 25, 24, 15 fps), Maximum resolution, Scale Retina videos to 1x, Hardware encoding.
- **What's in the video:** the pins on screen when it starts, and the click rings. Not the frame, the bar, its notices, the countdown, HUDs, thumbnails or any other ClearShot window, nor Notification Center's banners and widgets; desktop icons are hidden with Hide Desktop Icons on. "Show cursor" turns the cursor off.
- **Endings:** sleep stops the recording and keeps the file; a display change stops it (deletes it during the countdown); the menu bar's screen-sharing Stop keeps what was recorded ("Recording stopped"). ⌘Q while recording saves it, then quits.
- **During a recording,** other captures say "A capture is already in progress", and questions from thumbnails, pins, hotkeys or the menu bar that can't be undone say "Finish the recording first" (Close All, Mute Audio…, Save As…, Open…, Print…). During any other capture they say "Finish the capture first", and with a dialog open "Close the open dialog first", which brings the dialog forward. An unsaved recording's thumbnail closed meanwhile closes without "Close this recording?" (Restore Last Capture brings it back), or is refused under retention Never.
- **Thumbnails** of videos and GIFs show the length, the size and a speaker for sound ("0:12 · 8.4 MB"; "GIF · …"), in Capture History too. Hovering plays the video muted and looping, or animates the GIF. The scissors button trims; the pencil, ⌘E or a double-click opens the Video Editor. Closing an unsaved one asks "Close this recording?" (with "Don't ask again"). Videos and GIFs can't be pinned, and image-only menu items are left out.
- **Known limits:** no pixel-density metadata, so with "Scale Retina videos to 1x" off a recording plays at pixel size; portrait recordings show cropped in their thumbnail's hover preview.

## Audio

- **Microphone:** Ready's microphone button lists "Do Not Record Microphone" (the default) and the devices, with a level meter beside it while one is chosen; the same choice is in Settings › Screen Recording › Audio. A MacBook's built-in microphone can't be used with the lid closed. The microphone is always mono.
- **System audio** (Ready's speaker button, or "Record system audio") records the sound of other apps, never ClearShot's own.
- **Tracks:** the microphone and system audio are separate tracks while recording. With "Single track" (the default), stopping a recording that has both asks "Merge the microphone and system audio into one track, at these volumes:" with a Microphone volume and a System audio volume (0–200%, remembered): Merge mixes them into one track ("Merging audio..."), Don't Merge keeps two. "Separate tracks" keeps them apart, for other video editors. Screenshots work while the merge runs.
- **Record audio in mono** records system audio in one channel too, and a merge gives one channel.

## Warnings

While recording, warnings show in a small panel by the control bar, never as an alert over the recording:
- "Microphone is muted" (a muted input at the start, or 5 s of silence), with Continue or Stop, once a recording.
- "Microphone Disconnected", with Continue Without Audio or Stop; the screen recording goes on.
- "Audio Recording Failed" when system audio can't start: the recording goes on without it.
- "The microphone isn't available, so this recording has no microphone audio.", with the reason: it was disconnected, ClearShot has no access (or none yet, or it came after Ready), or it couldn't be opened.
- "The built-in microphone doesn't work while the MacBook's lid is closed.", with Continue Without Audio or Stop.

Before and after:
- "Your free disk space is low." (under 2 GB, or under 10 minutes at the planned rate), before the countdown: Record Anyway or Cancel.
- Under 1 GB free, the recording stops and keeps the file: "The disk is almost full, so the recording stopped."
- "Screen recording couldn't start." (protected video playing in another app can cause it) and "Screen Recording stopped unexpectedly."

## Do Not Disturb

With '"Do Not Disturb" while recording' on (the default), ClearShot turns Focus on during the countdown and off when the recording ends, however it ends, by running two Shortcuts you make once in the Shortcuts app (macOS has no public way for an app to set Focus):

1. **ClearShot Focus On:** one action, Set Focus › Do Not Disturb › On.
2. **ClearShot Focus Off:** one action, Set Focus › Do Not Disturb › Off.

The names must match exactly. Settings › Screen Recording says "Both shortcuts are set up", or shows these steps with Open Shortcuts and Check Again. Missing shortcuts never stop a recording; ClearShot says "Do Not Disturb shortcuts are missing; see Settings › Screen Recording" once per launch. If ClearShot quits during a recording, the next launch turns Focus off.

## Highlight Clicks

Ready's Highlight Clicks button, or Settings › Screen Recording › Highlight clicks (on by default), draws a ring at every click on the recorded display, and the ring is in the video. Size (Small, Medium, Large), Color (System accent color, Red, Purple, Green, Orange, Yellow), Style (Outline, Filled) and Animate (the ring grows from half size and fades; off, it stays while the button is down) are in Settings, with a "Click here to preview" box. No permission is needed. Clicks on the control bar and its notices make no ring, and there are none during the countdown or while paused.

## GIF

Record GIF in Ready records a GIF instead of a video: a small video at the GIF's size (800 px wide by default) without audio, which ClearShot's own encoder turns into a GIF once the recording stops.

- **Converting:** a second menu bar item shows "Creating GIF… N%", and a panel at the Quick Access corner shows the first frame, the progress, the size so far and Stop. Stop (or a click on the item) asks "Stop creating the GIF?": Continue, Save as a Video or Delete. If the conversion fails, the recording is kept as a video ("Couldn't create the GIF; saved as a video"). Screenshots work meanwhile; Record Screen says "Still creating a GIF".
- **Settings › Screen Recording › GIF:** Frame rate (60 fps plays at 50, the GIF limit; 50, 30, 25, 20, 15, 10), Optimize GIFs (smaller files: colours within a small threshold aren't repainted), Quality (0–100, with Optimize on; dithering from 70) and Maximum size ("800 × auto (default)" or Original).
- Copy puts the file and its GIF data on the clipboard, so it pastes animated; Save writes a `.gif`. The GIF keeps its recording, for Trim the GIF….
- **Known limits:** gradients band without dithering; Optimize off gives much larger files.

## Video Editor

Videos and GIFs open in the Video Editor from their thumbnail (the pencil, ⌘E, a double-click, the scissors, or Open Video Editor… in its menu) and from Capture History's Open.

- **The bar:** Trim (the yellow handles), Quality (Original, High, Medium, Low), Resolution (sizes below the video's), Mute, Mono, Volume (0–200%; the player plays up to 100%), the size estimate ("About 12.3 MB"), Cancel (Esc) and Save (Return, ⌘S).
- **Save** asks "Do you want to replace the existing video?": Replace updates the thumbnail, the history copy and, if ClearShot saved it and it hasn't changed since, the saved file; Save as New Video adds a second thumbnail. A saved file in another format (an opened `.mov`) is never written over: the edit is saved beside it as `.mp4` ("Saved as …"). Edits are MP4, except a ProRes video (or another codec MP4 can't hold) whose picture isn't re-encoded, which stays `.mov`. Closing with a change asks "Your changes will be lost if you exit." (Exit or Cancel).
- **The trim prompt:** with Open Video Editor and another after-recording action, a recording asks "Do you want to trim the video?". Trim opens the editor trimming, and the other actions run on what you save (or on the original if you cancel); Don't Trim runs them now; Trim Only opens the editor and runs nothing else. Open Video Editor alone opens the editor without asking.
- **Mute Audio…** (a video thumbnail's menu, with sound) asks "Are you sure you want to remove the audio track?" ("You can't undo this action.") and removes it, from the saved file too when ClearShot saved it and it hasn't changed.
- **Trim the GIF…** (a GIF's menu, or its scissors) trims the GIF's recording and makes the GIF again with the current GIF settings. Each trim starts from the whole recording.
- **Opening videos:** Open… takes movies as well as images, Open from Clipboard takes a movie copied in Finder, and Finder's Open With › ClearShot works on movies. Each becomes a thumbnail and a history item. A file with no video track says "The source file does not contain a video track." An opened GIF opens in the editor only if ClearShot recorded it (see [Opening files and Save As](#opening-files-and-save-as)).
- With "Show Dock icon" on, ClearShot shows in the Dock while an editor (Video Editor or Annotate) is open.

## Recovery

A recording is written to `~/Library/Application Support/ClearShot/Recordings/<id>/` as it goes (a fragmented MP4, playable up to the last second written, with a journal). If ClearShot quits during a recording (a crash, a forced quit), the next launch, about a second in and once no capture is under way, finishes the file, adds it to Capture History with its thumbnail, saves it to the export location, runs the after-recording actions and says "Recording recovered" (Show in Finder). A GIF recording comes back as its video. A recording that still can't be recovered after three launches is moved to `Recordings/Not Recovered/`, and the log says so; a leftover that has no journal, or can't be read, is deleted after a day. ⌘Q during a recording saves it normally; during a GIF conversion, the next launch recovers it as a video.

## History

Every capture has a lossless copy in `~/Library/Application Support/ClearShot/History`, kept for the time set in Settings › Advanced (1 month by default). A capture is never removed while its thumbnail, editor or pin is open, even with "Never". Restore Last Capture brings back the thumbnail you closed most recently.

- **Capture History** (menu bar › Capture History…, or its hotkey): a grid with filters (All, Screenshots, Videos, GIFs), each with its source app's icon and when it was taken. ⏎ restores to Quick Access, double-click or ⌘E opens Annotate (the Video Editor for videos and GIFs), Space is Quick Look, ⌘C copies (several items copy as files), drag out to any app, right-click for Pin and Show in Finder, ⌫ deletes (asks first, with "Don't ask again"). The gear menu sets how long captures are kept and clears history. Deleting from History never touches saved files or the clipboard.
- **The thumbnail's trash** ("Delete" / "Move to Trash") throws a capture away: its saved file goes to the Trash and ClearShot's copy leaves the clipboard if nothing else was copied since.

## Opening files and Save As

- **Opening:** Finder's Open With › ClearShot, Open… (the menu bar or its hotkey), Open from Clipboard and `clearshot://add-quick-access-overlay` load images (PNG, JPEG, HEIC, WebP), videos and GIFs into the Quick Access Overlay, as thumbnails and Capture History items; ClearShot works on a copy and never changes the original. A double-click opens Annotate, or the Video Editor for a video. A `.clearshot` project opens in Annotate. A second copy of ClearShot (the Debug build, say) hands what it was given to the running one.
- **GIFs** become GIF items, told by their contents, so a PNG named `.gif` opens as an image: the thumbnail animates on hover and shows its length and size, and Save writes a `.gif`. Only a GIF recorded in ClearShot has the pencil, Trim and the Video Editor; any other says "This GIF wasn't recorded in ClearShot, so it can't be trimmed". Frames stored with no delay count as 0.1 s, as browsers play them.
- **Save As…** on a screenshot's thumbnail or pin offers PNG, JPEG, HEIC and WebP, starting on the format Save would use (PNG for a transparent capture), and writes the one you choose. A video keeps its own type (an opened `.mov` stays `.mov`), a GIF `.gif`. Annotate's Save As adds ClearShot Project.
- **Screenshot metadata:** captured screenshots are tagged as macOS screenshots (`kMDItemIsScreenCapture`, the capture type and its rect), their unsaved copies, drags and Annotate's copies included, so Finder and Spotlight treat them like native screenshots. Opened and pasted images, videos and GIFs aren't tagged.

## Pins

Pin a screenshot from its thumbnail, the Pin after-capture action, Capture Area & Pin, Annotate (File › Pin to the Screen; give it a key in System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts), Capture History, Choose and Pin an Image, or Pin Last Screenshot. Pins float above other windows (an always-on-top editor included) on every Space.

- Drag to move, arrow keys nudge (⇧ for 10 pt), pinch or ⌘+/⌘−/⌘0 to zoom, two-finger scroll for opacity, middle-click or ⌘W to close. "Drag me" drags the file out and closes the pin (hold ⌥ to keep it).
- Right-click for Close All, Lock, Lock and Hide Screenshot on Mouse Over, Copy, Save As…, zoom and opacity presets, and per-pin Shadow, Rounded Corners and Border (defaults in Settings › Advanced › Pins). A locked pin lets clicks through; hover it and click the lock badge to unlock.
- Toggle Pins Visibility and Close All Pins have hotkeys; while pins are hidden the menu bar shows "Show Hidden Pins". Pins don't come back after a relaunch.

## Desktop icons

Hide Desktop Icons (menu bar, or its hotkey) covers every display with the wallpaper from Settings › Wallpaper until you turn it off, across relaunches. When the desktop picture changes, the covers show the new one about a second later. Double-click the desktop or right-click › Show Desktop Icons to bring them back. Files dropped on the covered desktop land in `~/Desktop` (moved on the same disk, copied otherwise or with ⌥, " 2" on a clash); one that can't get there is kept in `~/Library/Application Support/ClearShot/Undelivered Drops`. Captures never show the hidden icons or widgets. Finder's desktop menu and "click wallpaper to reveal desktop" don't work while the icons are hidden.

## Annotate

Open a capture in the editor from its thumbnail (the pencil button, ⌘E or a double-click), with "Capture Area & Annotate", the "Open Annotate" after-capture action, or the "Annotate Last Screenshot" hotkey.

- **Done** (⌘↩) applies the edits to the capture: its thumbnail, its history copy and, if ClearShot saved it and nothing has changed it since, its saved file. Reopening an annotated capture shows every object still editable.
- **Save** (⌘S) also gives the capture a saved file; **Save As** (⇧⌘S) writes PNG, JPEG, HEIC, WebP or a ClearShot project. Hold ⌥ to skip the dialog.
- **Projects** are `.clearshot` packages: `document.json`, `original.png` and `images/`, with Finder previews in `QuickLook/`. Double-click one to edit it again.
- Settings › Annotate holds the editor's options (arrows, smoothing, shadows, colour names, window behaviour) and the tool letters (Tool shortcuts).
- **Crop & Resize** (`C`): aspect ratios, snapping to edges (hold ⌘ to turn it off), dragging past the picture to expand the canvas (filled Auto, Transparent or a colour), Rotate Left/Right (⌥⌘L/⌥⌘R), flips, Resize Image… (⌥⌘I; annotations scale with the picture and stay editable) and Revert to original. Flips and Revert have menu items but no shortcuts: plain letters would catch typing and the ⌘ combinations are taken.
- **Images:** Add Image › Take Screenshot, Paste from Clipboard or Choose from File…, ⌘V, or drag images in. Dropping on a drop zone at an edge combines the image beside the picture.
- **Background** (`G`, the tool strip's last button or Edit › Background Tool): a panel on the right with fills (None, 20 gradients, Desktop, Blurred desktop, Blurred screenshot, the macOS wallpapers, your own pictures via Add background…, colours), Padding, Inset (with its colour), Shadow and Corners (drag or type), Auto-balance, a 9-position alignment grid, the ratio and Remove background. The background is part of the document, so it stays editable after Done and exports always draw it fresh. Opening the panel on a capture without one applies your previous settings (window shots keep their own); with "Remember if the background tool was open" on, the next editor opens with the panel. Your own pictures are copied to `~/Library/Application Support/ClearShot/Backgrounds`; documents keep their own copy.
- **Presets** (the panel's slider button): apply, save, update, rename, delete and Apply Previous Settings. Window-shot presets are a separate list. **Settings › Screenshots › Background preset** applies one to every new capture (screenshots and window screenshots separately). Hold ⇧ as you start a selection, or as you click a window, to skip it for that shot; fullscreen and Capture Previous Area run from hotkeys, so they can't skip. ⇧ pressed after the drag has started only squares the selection.
- **Editable window shots:** a window taken "With wallpaper" is saved as a document (the transparent window plus the wallpaper behind it), so the background can be changed or removed later. These don't get the 1 px border.
- **Document format:** documents with a background are version 2; an older ClearShot build refuses them instead of dropping the background.
- **Known limits:** WebP files can't record their density; a picture pasted between documents with different rotations comes in turned; Desktop fills follow a changed desktop picture, but a dynamic one that changes within one file isn't read again until a Space change refreshes it ("Update wallpaper when switching Spaces").

## Printing

Annotate's Print… (⌘P) fits the picture on one page; Print on Several Pages… runs a tall capture down several pages and a wide one across. The thumbnail's Print… starts on one page. In the print panel, "Scale image to fit on one page" (under ClearShot) switches between the two, and the preview follows. Paper Size and Orientation are in the panel too; a picture wider than tall starts in landscape, any other in portrait. The panel's menu names ClearShot's options "Image".

## URL commands

Launchers, Shortcuts and scripts can drive ClearShot with `clearshot://` URLs:

    open -g 'clearshot://capture-area?x=100&y=120&width=200&height=150&display=1&action=copy'

`open -g` sends the URL without bringing ClearShot forward, for scripts that shouldn't take the focus. Before any command that doesn't open a ClearShot window, ClearShot also hands the activation back to the app you were in, so a window capture shows that window active.

| Command | Parameters | What it does |
|---|---|---|
| `all-in-one` | area | All-In-One, on the area if one is given (the remembered area is left alone) |
| `capture-area` | area, `action` | Capture Area; with an area, captures it at once |
| `capture-previous-area`, `capture-fullscreen`, `capture-window`, `self-timer` | `action` | As the menu items |
| `capture-area-raycast-aichat` | area | Capture Area & Send to Raycast |
| `scrolling-capture` | area, `start`, `autoscroll` | Scrolling Capture; with an area, Ready on it; `start=true` starts capturing at once, `autoscroll=true` with Auto-Scroll |
| `record-screen` | area | Record Screen; with an area, Ready on it. It never starts or stops a recording: during one it says "A capture is already in progress" |
| `capture-text` | area or `filepath`, `linebreaks` | Capture Text; with an area, reads it at once; with a file, reads that image |
| `pin` | `filepath` | Pins the image; without one, Choose and Pin an Image |
| `open-annotate` | `filepath` | Opens the image or `.clearshot` project in Annotate; without one, a file chooser |
| `open-from-clipboard` | | Images to Annotate; video and GIF files to Quick Access |
| `add-quick-access-overlay` | `filepath` (needed) | The image, video or GIF as a thumbnail |
| `open-history`, `restore-recently-closed` | | Capture History; Restore Last Capture |
| `open-settings` | `tab` | Settings, on `general`, `wallpaper`, `shortcuts`, `quickaccess`, `recording`, `screenshots`, `annotate`, `advanced` or `about` (`cloud` opens Settings) |
| `toggle-desktop-icons`, `hide-desktop-icons`, `show-desktop-icons` | | Hide Desktop Icons |
| `debug-selftest` | | The capture self-test, in Debug builds only |

- **An area** is `x`, `y`, `width` and `height`, all four, in points from the display's **bottom-left** corner, y up, with an optional `display`: 1 is the display with the menu bar, 2 and on the others in macOS's order; without it, the display under the pointer. An area partly off the display is clipped to it, and must keep at least 4 × 4 points.
- **`action`** is `copy`, `save`, `annotate` or `pin`, instead of General › After capture, on the five screenshot commands only. `upload` says "ClearShot doesn't upload".
- **`start`, `autoscroll` and `linebreaks`** take `true` or `false` (also `1`/`0`, `yes`/`no`). `autoscroll=true` implies `start`. Without `linebreaks`, Capture Text follows Keep line breaks.
- **`filepath`** is a full path (`~` works), percent-encoded: an image, a video too for `add-quick-access-overlay`, or a project for `open-annotate`. ClearShot reads it (up to 1 GiB) and never writes to it; `add-quick-access-overlay` copies it into Capture History.
- Unknown parameters are ignored, and the first of a repeated one wins. A command that can't run shows one HUD line ("There's no display 2", "x.png isn't a file"), and the log names the command and the app that sent it.

**The consent prompt.** The first command from another app asks "Another app wants to control ClearShot", naming the app and the command. **Allow lets any app on this Mac run ClearShot commands, capture your screen and open the image and video files a command points to**, not only the app that asked.
- Don't Allow is the default: Return and Esc choose it. Allow takes a click, and only once the prompt has been in front and uncovered for 1.5 s, so a stray key or click, or a window drawn over the prompt, can't allow.
- The app is named only when its code signature verifies (Developer ID, Mac App Store or Apple), always with its signed identifier: "Raycast (com.raycast.macos, team …)". Otherwise it is "an unverified app", or "an external app" when it has already quit (`open`, shell scripts) or nothing is known.
- Up to 8 commands that arrive while the prompt is up wait for the answer. During a capture or a recording, or with a dialog open, the prompt isn't shown: the command is dropped with "Finish the capture first", "Finish the recording first" or "Close the open dialog first" (once per app every 10 s), and the next command asks again.
- The answer is kept in the login keychain (service `<bundle identifier>.url-consent`), not in ClearShot's preferences, so `defaults write` can't turn it on.

**The setting.** Settings › Advanced › URL scheme API › "Allow URL scheme API" shows what the next command meets: on, with "Asks the first time an app sends a command." under it, until you allow; on once allowed; off while commands are ignored (the first each launch shows "URL commands are off (Settings › Advanced)"). Turning it on allows without the prompt; turning it off removes the keychain item. Reset All Warning Dialogs leaves it alone.

**The capture notice.** A command that captures with no choice on screen (an area with capture-area, capture-area-raycast-aichat or capture-text; capture-previous-area; capture-fullscreen; scrolling-capture with `start`) shows "⟨app⟩ is capturing your screen with ClearShot", which isn't in the picture.

**The remaining risk:** the prompt keeps sandboxed apps and web pages out until you allow them, but a program you run yourself outside the sandbox can plant the keychain item and then run commands, screen captures included, without asking.

## Logs

`~/Library/Logs/ClearShot/clearshot.log`, or Console.app with the app's bundle identifier as the subsystem (`com.example.clearshot` by default). URL commands log under the `api` category, with the app that sent each one.

## Releasing

For maintainers: tag a commit on main with its version, and push the tag.

    git tag v1.2.0
    git push origin v1.2.0

The Release workflow (`.github/workflows/release.yml`) then runs the CI build and tests, waits for approval in the `release` environment, builds the Release app as 1.2.0 with the workflow's run number as its build number, and packs `ClearShot-1.2.0.dmg` (what `make dmg VERSION=1.2.0` does locally). With the Developer ID secrets in the `release` environment, it signs, notarizes and staples the app, then the DMG, and checks that Gatekeeper accepts both; without them the build is signed ad hoc and its notes say it's unsigned. It writes the DMG's checksum, attests where it was built, and publishes a GitHub Release with generated notes, the install steps, the DMG and the checksum. A tag such as `v1.2.0-beta.1` publishes a pre-release.

Actions › Release › Run workflow, with a version, is a dry run: the DMG and its checksum come back as a workflow artifact, and nothing is published. The secrets and the `RELEASE_BUNDLE_ID` variable are described at the top of the workflow.

## License

ClearShot is licensed under the [Apache License 2.0](LICENSE). Copyright © The ClearShot Authors.

ClearShot includes two open-source components, KeyboardShortcuts and libwebp, under their own licenses: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which also ships inside the app and in the DMG.
