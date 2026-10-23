# AUTOPILOT.md

Project-wide direction for the unattended agent working on TokenCat. This guide sets priorities and taste. The repository's own rules files (README, contributor notes, any CLAUDE.md or AGENTS.md, CI config) win over this guide wherever they disagree.

## Goals and roadmap

TokenCat is a free, open-source menu bar app: a pixel cat that shows what coding agents (Claude, Codex, omp and similar) are doing right now, including sessions, running sub-agents and usage limits. It ships on macOS 13+ (Swift, AppKit, SwiftUI) and has a Windows counterpart that mirrors the macOS behavior. Data stays local; privacy is a core promise.

Direction, inferred from recent history:
- Make the live status trustworthy: correct account attribution, accurate limit windows, honest timestamps and live/stale state.
- Keep the session dashboard readable as the number of projects and sessions grows.
- Keep macOS and Windows behavior in step; a change to one side's behavior should be reflected on the other, or the gap noted.
- Keep builds fast and the app light on CPU, memory and battery.

No fixed roadmap file exists in the facts given. If the repo contains one, follow it over this section.

## Area priorities

1. **Bugs (highest):** wrong or stale agent/limit data undermines the whole product. Fix correctness first, and add a regression check with the fix.
2. **Tests:** the project grows by writing a failing check first, then fixing. Keep doing that. Extend the checks for any behavior you touch, including the Windows App checks when the mirror changes.
3. **Performance:** a menu bar app must stay near-idle. Avoid polling creep, redundant file reads and slow-to-compile expressions.
4. **Design/UI:** matters, but as polish on a small surface (menu bar item, dashboard, Settings). Keep sample screens and README images consistent with real UI changes.
5. **Features:** welcome when they serve "what are my agents doing right now." Prefer small, local, privacy-preserving additions.
6. **Refactoring:** only when it unblocks a fix or a measurable speed or clarity gain. No sweeping rewrites.
7. **Docs:** keep README and the Korean README (README.ko.md) in sync with user-visible changes. Keep it brief.

## Do not touch

- `LICENSE`, and release or signing credentials of any kind.
- Release artifacts and published download names that the README links to (for example the macOS and Windows zip names).
- Anything that sends user data off the machine: no new network calls, telemetry or uploads. Local-only is a product promise.
- Reading or modifying agents' credential or token contents beyond what existing code already does to attribute sessions. Never log secrets.
- Version bumps and release publishing unless a rules file explicitly tells you to.
- Generated files and binary assets (images, icons) except when a change genuinely requires regenerating them.
- Deleting or weakening existing checks to make them pass.

## Done means

Use the repository's own build and check commands; discover them from the README, scripts and CI config rather than guessing. All of them must pass before a commit:
- The project build succeeds (macOS; Windows too if you touched the Windows side).
- The existing check suites pass, including any App checks for the platform you changed.
- New or changed behavior has a check that fails without the change.

Commit style, matching history: one focused change per commit, short subject line stating what changed and why. Existing subjects are mostly Korean, with a prefix such as a version number, `검사:`, `빌드:` or `fix:`. Follow the language and prefix convention of the most recent commits. Do not mix refactors into bug-fix commits.

## Taste

- Small, readable diffs; match the surrounding Swift style and naming.
- The UI is calm and compact: a pixel-cat identity, restrained color, short labels. Group by project rather than repeating names.
- Prefer native platform controls and behavior (AppKit/SwiftUI on macOS, native patterns on Windows) over custom widgets.
- Accessibility counts: the Windows narrator support exists on purpose, so keep labels meaningful.
- Comments explain why, not what. No dead code, no speculative abstractions.
- User-facing strings should respect the existing localization setup (English and Korean).

## Long-lived ideas

- Support for more coding agents and their usage-limit models, behind one consistent status model.
- Clearer history and older-session browsing without cluttering the default view.
- Tighter macOS/Windows parity via shared check scenarios or sample-screen fixtures.
- Faster incremental builds and a lighter idle footprint.
- Better surfacing of which account or credential a session and its limits belong to.

## Release

Releases: yes
Drafted by OMPdesk from the repository's files; the rules files win where they differ.

### Procedure
1. Version: read the commits since the last release: a `feat` since the last release makes it minor, only `fix`/`perf` makes it patch, a `!` or `BREAKING CHANGE` makes it major; bump the version in `build.sh`.
2. Changelog: add `## X.Y.Z` on top of `CHANGELOG.md`, covering every user-visible change since the last release.
3. Before releasing: the project's tests and build pass on the commit being released.
4. Commit: one release commit that touches only `build.sh` and `CHANGELOG.md`, message `chore: X.Y.Z` like the last release.
5. Publish: push the release commit with `git push origin HEAD:main` (fast-forward only) (it runs only when the push changes `build.sh`); `.github/workflows/release.yml` publishes (GitHub release).
6. Watch: follow the run it starts to the end (`gh run watch`). A failed run is reported in the cycle and fixed in the next one; never forced, never published by hand.

### Cadence
- 29 releases in the last 90 days, about every 1 day; when this guide was written the latest was v0.24.3 on 2026-10-20.
- Release when three user-visible changes have gathered, at once for an urgent fix, or when one has waited a day; never because of the time since the last release. Docs-only or internal changes wait for the next release.
