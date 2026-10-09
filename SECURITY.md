# Security

## Reporting a vulnerability

Please report security problems privately, through GitHub's private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability** (or go straight to <https://github.com/ravipetlur/clearshot/security/advisories/new>). Please don't open a public issue, pull request or discussion for one.

Include what you found, the ClearShot version (Settings › About) and macOS version, and the steps or a proof of concept that shows it. ClearShot is maintained in spare time, so replies come on a best-effort basis; you'll hear back once the report has been looked at, and you're welcome to be credited in the advisory and the release that fixes it.

Only the latest release gets security fixes.

## In scope

- **The `clearshot://` URL commands and their consent prompt.** The first command from another app asks "Another app wants to control ClearShot"; Don't Allow is the default, and Allow takes a click on a prompt that has been in front and uncovered for 1.5 s. Allowing lets any app on the Mac run commands, which can capture the screen and open the files a command names. The answer is kept in the login keychain, not in ClearShot's preferences, so `defaults write` can't grant it. A way for a sandboxed app, a web page or another user to run commands without that answer, or to get it without a person's click, is in scope.
- **Code injection and borrowed permissions.** ClearShot runs with the hardened runtime, one entitlement (the microphone) and no `get-task-allow`, so another process shouldn't be able to inject code into it, attach to it or borrow its Screen Recording, Microphone or Accessibility permission.
- **Files ClearShot reads:** images, videos, GIFs and `.clearshot` projects opened in it or named by a URL command (a crafted file that crashes it, or makes it read or write outside what it should), and recordings recovered after a crash.
- **Data ClearShot keeps:** Capture History, recordings and logs in your Library folder, and anything in them that leaks outside it.
- **The release pipeline:** the GitHub Actions workflows in `.github/workflows`, the DMG, its published SHA-256 checksum and its build provenance attestation.

## Out of scope

- **The documented same-user limitation of the URL commands.** The consent prompt keeps sandboxed apps and web pages out until you allow them, but a program you run yourself, as your user and outside the sandbox, can plant the keychain item and then run commands, screen captures included, without asking. That program already runs with your rights; the README says so under [URL commands](README.md#url-commands).
- Attacks that need root, physical access to an unlocked Mac, or permissions you granted to another app.
- Gatekeeper's warning on an unsigned (ad hoc) build, and permissions asked again after updating one; both are expected and described in the README.
- Problems in macOS itself, or in the actions and services the workflows use, unless ClearShot's use of them makes them exploitable: report those upstream as well.
