# Punchlist expert review, 2026-11-03

## Summary after verification

| Severity | Count | IDs |
| --- | --- | --- |
| Critical | 0 | |
| High | 0 | |
| Medium | 7 | P1, C1, P3, P2, A1, UI1, T1 |
| Low | 12 | C3, P4, P5, UI2, UI3, C2, C4, A2, A3, A4, T2, T3 |
| Dropped | 0 | |

All 19 raw findings held up as real defects or gaps. None was dropped. Eight were downgraded in severity or confidence, mostly because the visible failure depends on runtime behaviour that can't be confirmed from the source alone. Two findings had parts of their failure scenarios corrected (P2, A3). One finding (P3) was strengthened by a failure path the original reviewer missed.

---

## 1. Scope and method

- **Commit:** `5b34c29694640abdd70140fca55dff368b08f7bd` ("Drop the rectangle behind the focused new issue field (#5)").
- **What was reviewed:** the single SwiftPM `executableTarget` `Punchlist`: 10 Swift files, about 1,900 lines in `Sources/Punchlist/`, plus `Package.swift`, `README.md`, `bundle.sh` and `release.sh`. There is no test target. The review covered five areas: Concurrency, SwiftUI, Persistence and sync (the `gh`-backed GitHub sync, the in-memory cache and the single `@AppStorage` key), Accessibility, and Test quality.
- **Build settings that matter:** macOS 27 only. Swift tools 6.4, Swift 6 language mode, so complete strict concurrency checking. There are no `swiftSettings`, which means no `defaultIsolation(MainActor.self)` and no `NonisolatedNonsendingByDefault`. `IssuesStore` is explicitly `@MainActor`. `GH`'s `static async` functions are nonisolated and run on the global (cooperative) executor.
- **Documented decisions checked:** there is no CLAUDE.md, CONTEXT.md, AGENTS.md or ADR, and `docs/` held only screenshots before this review. The README documents two deliberate choices: the 1,000-item search cap and that all GitHub access goes through `gh`. The code comments document a third: prefetching the other tab. No finding was dropped for contradicting them. P4's fix was narrowed so that it respects them.
- **Method:**
  1. A first reviewer did a static, read-only review and recorded the raw findings.
  2. An independent adversarial verifier (this pass) opened every cited file and line and re-read the callers, callees and isolation context. The verifier then checked each finding against the documented decisions, and confirmed, downgraded or dropped it, recording the reason under each finding.
  3. Line references were re-checked against HEAD. One reference was off by one: UI2's `@State title` is at `NewIssueRow.swift:8`, not `:9`.
- **Lint and build:** both skipped. The review ran on Linux, where `swift` isn't installed, so nothing was compiled, linted, run or tested.
- **What a Mac is needed for:** building the app, running tests (none exist yet), Thread Sanitizer, Instruments (Swift Concurrency, SwiftUI, Time Profiler), VoiceOver and Full Keyboard Access, Accessibility Inspector contrast checks, Reduce Motion behaviour, and anything that depends on real `gh` and GitHub responses (rate limits, SSO-protected orgs, error shapes). Section 5 lists the specific check for each finding.

---

## 2. Headline findings

1. **P1** (medium): A failed Refresh is invisible once the list has rows, and `lastUpdated` is never shown, so stale data looks current. `IssuesStore.swift:181-184`, `ContentView.swift:168-169`
2. **C1** (medium): `gh` subprocesses can't be cancelled, and each one blocks a cooperative-pool thread until it exits. `GH.swift:33-56`
3. **P3** (medium): One failing owner, or any failure at launch, empties the repository list for the session, and Return in the new-issue field then does nothing. `GH.swift:83-91`, `IssuesStore.swift:238-240`, `NewIssueRow.swift:103`
4. **P2** (medium): A failed comments load leaves "Loading comments…" spinning with no error or retry. `IssuesStore.swift:229`, `IssueDetail.swift:81-86`
5. **A1** (medium): In the compact layout, rows open only with a pointer click. They don't respond to the keyboard and have no button trait for VoiceOver. `ContentView.swift:139`, `:172-178`
6. **UI1** (medium): ⌘N does nothing while the new-issue row is scrolled out of the list, and it steals focus later. `NewIssueRow.swift:59-63`
7. **T1** (medium): There is no test target, and the overlay and idempotency logic that decides what users see after every change is untested. `IssuesStore.swift:262-360`
8. **C3** (low): Toggling Include Organizations quickly lets a stale repository list overwrite a fresh one. `IssuesStore.swift:233-241`

---

## 3. Findings by area

### 3.1 Concurrency

#### C1. `gh` subprocesses can't be cancelled and each one blocks a cooperative-pool thread
- **Severity:** medium · **Confidence:** high (defect) / medium (size of the visible stall)
- **File:** `Sources/Punchlist/GH.swift:33-56`. Callers: `IssueDetail.swift:58` (`.task(id: issue)`) and `IssuesStore.swift:206-219` (the shared, unstructured `search` task).
- **Code:**
  ```swift
  return try await Task.detached {
      ...
      try process.run()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      let errData = err.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
  ```
- **Why it matters:** `Task.detached` doesn't inherit the caller's cancellation, and awaiting `.value` doesn't propagate it. Nothing calls `process.terminate()`. The closure runs on the global concurrent executor and blocks its thread on `readDataToEndOfFile` and `waitUntilExit`. That pool is sized to the core count and doesn't overcommit. `loadComments` also refetches on every selection, even when comments are already cached.
- **Failure scenario:** In the wide layout the user holds ↓. Every selection change restarts `IssueDetail`'s `.task(id: issue)`, and each restart spawns a `gh api …/comments --paginate --slurp` that can't be cancelled. Once there are more of these in flight than cores, other global-executor work queues behind them: the next `GH.run` for Refresh, `JSONDecoder` work in `GH.search`, and image loads. The UI thread itself stays responsive, but loads stall, and API quota is spent on discarded results. Fast status-filter changes do the same, because `IssuesStore.search` tasks are never cancelled.
- **Suggested fix:** Replace the blocking body with a `terminationHandler` and pipe draining (`readabilityHandler`, or `FileHandle.bytes`), and resume a continuation inside `withTaskCancellationHandler { … } onCancel: { process.terminate() }`. If the code must keep blocking, run it on a dedicated thread or `DispatchQueue`, not the cooperative pool. Skip `loadComments` when `comments[issue.id]` is already set and the `updatedAt` is unchanged.
- **Verification:** downgraded (confidence only). The code path is exactly as described, and it is the root cause of C2, C3 and part of P4. How long the app actually stalls depends on core count and `gh` latency, so that part needs Instruments.

#### C3. `loadRepositories` writes back stale results after the "Include Organizations" toggle changes
- **Severity:** low · **Confidence:** high
- **File:** `Sources/Punchlist/IssuesStore.swift:233-241`, driven by `ContentView.swift:25`
- **Code:**
  ```swift
  guard let owners = try? await GH.owners(includeOrgs: query.includeOrgs),
        let repos = try? await GH.repositories(owners: owners) else { return }
  allRepositories = repos
  ```
- **Why it matters:** `.task(id: store.query.includeOrgs)` cancels the previous run, but `GH.run` ignores cancellation (C1), and this method neither checks `Task.isCancelled` nor re-compares the setting before assigning. `load()` has exactly that guard (`query == self.query`, line 176), so the two methods are inconsistent.
- **Failure scenario:** The user turns orgs on and then quickly off. The "on" run lists each org one after another and finishes last, so the repo filter and the new-issue menu end up listing org repos while orgs are excluded. The reverse order hides org repos.
- **Suggested fix:** Capture `let includeOrgs = query.includeOrgs`, and after the awaits add `guard !Task.isCancelled, includeOrgs == query.includeOrgs else { return }`.
- **Verification:** confirmed. Both calls run on the main actor, and the last write wins.

#### C2. Reading stdout to EOF before stderr can deadlock
- **Severity:** low · **Confidence:** low
- **File:** `Sources/Punchlist/GH.swift:47-49`
- **Code:**
  ```swift
  let data = out.fileHandleForReading.readDataToEndOfFile()
  let errData = err.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  ```
- **Why it matters:** Nothing drains stderr until stdout reaches EOF. If the child writes more to stderr than the pipe buffer holds while it is still running, both processes wait on each other forever, and a pool thread stays pinned (C1).
- **Failure scenario:** `gh` emits more than about 64 KB on stderr before exiting. The spinner never stops and Refresh stays disabled.
- **Suggested fix:** Drain both pipes concurrently. This comes for free with the C1 rewrite.
- **Verification:** downgraded (confidence medium → low). The mechanism is real, but `gh` writes short, single-line errors, prints no update notices when it isn't on a TTY, and exits on the first page error under `--paginate`. Nothing seen in the code makes 64 KB of stderr plausible. Fix it with C1 rather than on its own.

#### C4. The login-shell `gh` lookup has no timeout and trusts all shell output
- **Severity:** low · **Confidence:** medium (output parsing) / low (hang)
- **File:** `Sources/Punchlist/GH.swift:12-27`
- **Code:**
  ```swift
  shell.arguments = ["-lc", "command -v gh"]
  ...
  let data = out.fileHandleForReading.readDataToEndOfFile()
  shell.waitUntilExit()
  let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  ```
- **Why it matters:** This is a lazily initialized `static let`, so every `GH.run` waits on the first initialization. Anything a login file prints to stdout ends up in `path`.
- **Failure scenario:** `gh` is installed outside the three hard-coded paths (for example with mise, nix or in `~/.local/bin`), and `.zprofile` echoes a line. `path` becomes `"banner\n/…/gh"`, and every call then fails with an opaque launch error instead of the friendly "Couldn't find the gh CLI" message.
- **Suggested fix:** Take the last non-empty line that passes `FileManager.isExecutableFile(atPath:)`, terminate the shell after about 3 s, and fall back to `nil`.
- **Verification:** downgraded (confidence on the hang). A GUI app's child inherits `/dev/null` as stdin, so a `read` in `.zprofile` returns immediately, which makes an indefinite hang unlikely. The output-parsing defect is confirmed by reading. Impact is limited because the README installs `gh` through Homebrew, and `/opt/homebrew/bin/gh` is checked first.

### 3.2 SwiftUI

#### UI1. ⌘N / File > New Issue does nothing when the new-issue row is scrolled out of the List
- **Severity:** medium · **Confidence:** medium
- **File:** `Sources/Punchlist/NewIssueRow.swift:59-63`, `Sources/Punchlist/ContentView.swift:164-166`, `Sources/Punchlist/IssuesStore.swift:143-147`
- **Code:**
  ```swift
  .task(id: store.wantsNewIssueFocus) {
      guard store.wantsNewIssueFocus else { return }
      isFocused = true
      store.wantsNewIssueFocus = false
  }
  ```
- **Why it matters:** The only consumer of this one-shot flag is a modifier on the first List row. macOS `List` rows are realized lazily, so when that row is off screen nothing consumes the request and nothing scrolls to it. ⌘N is a documented shortcut in the README.
- **Failure scenario:** The user scrolls down a long list and presses ⌘N, and nothing happens. Later, when they scroll back up, the row appears, its task fires and it takes focus from wherever they are typing, for example the search field.
- **Suggested fix:** Wrap the List in a `ScrollViewReader`, give the row `.id("newIssue")`, and consume the flag in `Sidebar` (which is always alive): scroll to the row, then focus it. Alternatively, move the field into the `safeAreaBar` header.
- **Verification:** confirmed. The confidence was already medium because it depends on List row realization, a framework internal. Severity stays medium because a documented shortcut silently fails and then steals focus.

#### UI2. Crossing the 640 pt breakpoint discards the typed new-issue title and other view state
- **Severity:** low · **Confidence:** high
- **File:** `Sources/Punchlist/ContentView.swift:16-18`, with the state at `Sources/Punchlist/NewIssueRow.swift:8`
- **Code:**
  ```swift
  Group {
      if isCompact { compactLayout } else { wideLayout }
  }
  ```
  ```swift
  @State private var title = ""
  ```
- **Why it matters:** The two branches have different structural identities, so crossing the threshold destroys `Sidebar`, its `List` and `NewIssueRow`, including their `@State`, `@FocusState` and scroll position.
- **Failure scenario:** The user is typing a title and narrows the window, or tiles it to half of a small display. The draft is lost.
- **Suggested fix:** Move the draft into `IssuesStore`, or into `@SceneStorage`. Optionally, keep a single `Sidebar` and vary only its container.
- **Verification:** confirmed. The quoted `title` line is 8, not 9. The selection lives in the store and survives, but the draft and scroll position don't.

#### UI3. The filtered list is recomputed three times on every search keystroke
- **Severity:** low · **Confidence:** low
- **File:** `Sources/Punchlist/ContentView.swift:122`, `:168`, `:172`/`:180`, and `Sources/Punchlist/IssuesStore.swift:127-138`
- **Code:**
  ```swift
  let shown = store.filteredIssues.count            // ContentView.subtitle
  if store.filteredIssues.isEmpty {                 // Sidebar.rows
  ForEach(store.filteredIssues) { issue in          // Sidebar.rows
  ```
- **Why it matters:** `filteredIssues` is computed. Each read builds an interpolated haystack string and runs `localizedCaseInsensitiveContains` on it for up to 1,000 items.
- **Failure scenario:** With 1,000 items loaded, every keystroke does about 3,000 locale-aware string searches on the main actor.
- **Suggested fix:** Read it once per body and pass it down, or cache it in the store and invalidate it when `issues`, `searchText`, `repoFilter` or `labelFilter` changes.
- **Verification:** downgraded (confidence medium → low). The triple evaluation is real, but macOS 27 runs only on Apple Silicon, where 3,000 short string searches cost a few milliseconds. List diffing of 1,000 rows probably dominates. The fresh `onOpen` closure doesn't change anything, because `Sidebar` reads `searchText`-dependent state and re-evaluates anyway. Measure before optimizing.

### 3.3 Persistence and sync (GitHub via `gh`, in-memory cache, UserDefaults)

#### P1. Refresh failures are invisible once the list has rows, and staleness is never shown
- **Severity:** medium · **Confidence:** high
- **File:** `Sources/Punchlist/IssuesStore.swift:181-184`, `Sources/Punchlist/ContentView.swift:168-169`, `:193-200`, `Sources/Punchlist/IssuesStore.swift:38`
- **Code:**
  ```swift
  } catch {
      guard !Task.isCancelled, query == self.query else { return }
      errorMessage = error.localizedDescription
  }
  ```
  ```swift
  if store.filteredIssues.isEmpty {
      placeholder          // the only place errorMessage is rendered
  ```
  ```swift
  private(set) var lastUpdated: Date?   // written at :167 and :179, never read
  ```
- **Why it matters:** `load()` first puts the cached rows in `issues`, so after a failure the list is non-empty and the error, which only the empty-list placeholder renders, never appears. `lastUpdated` has no reader. A failed Refresh looks exactly like a successful one.
- **Failure scenario:** The `gh` token expires, the Mac goes offline, or search is rate-limited (P4). Every Refresh, and every load triggered by switching back to a cached tab after its 120 s freshness window, fails silently. The app is a to-do list, and it keeps showing a stale list as if it were current.
- **Suggested fix:** When `errorMessage != nil` and rows exist, show a non-blocking indicator: a warning on the Refresh item with the message in `.help`, a `safeAreaBar` banner, or the subtitle ("Couldn't refresh · updated 5 min ago"). Show `lastUpdated` in the subtitle.
- **Verification:** confirmed. One correction: there is no periodic reload. The "two-minute freshness reload" happens only on a query or tab change, which doesn't affect the finding.

#### P3. One inaccessible owner, or any failure at launch, empties the repository list and silently disables issue creation
- **Severity:** medium · **Confidence:** high (silent no-op after any failed repo load) / medium (SSO-org trigger)
- **File:** `Sources/Punchlist/GH.swift:83-91`, `Sources/Punchlist/IssuesStore.swift:238-240`, `Sources/Punchlist/NewIssueRow.swift:67-71`, `:103`
- **Code:**
  ```swift
  for owner in owners {
      let data = try await run(["repo", "list", owner, "--no-archived", "--limit", "1000", ...])
      repos += try decoder.decode([RepositoryInfo].self, from: data)
  }
  ```
  ```swift
  guard let owners = try? await GH.owners(includeOrgs: query.includeOrgs),
        let repos = try? await GH.repositories(owners: owners) else { return }
  ```
  ```swift
  guard !title.isEmpty, let repository else { return }
  ```
- **Why it matters:** `repositories(owners:)` is all-or-nothing, and its error is discarded. **Verifier extension:** `loadRepositories` runs only from `.task(id: store.query.includeOrgs)`, so it runs at launch and on an orgs toggle. Refresh doesn't retry it. Any failure at launch, such as being offline, a transient `gh` error or one SSO-protected org, leaves `allRepositories` empty for the whole session.
- **Failure scenario:** On a first launch with no saved `newIssueRepository`, and either offline or with an SSO-protected org included, the new-issue row shows "in …" with an empty menu. Typing a title and pressing Return does nothing at all: no error, and the text stays in the field. Repos with no loaded items also disappear from the repo filter.
- **Suggested fix:** Collect results per owner and keep the owners that succeed (a task group that records an error per owner). Retry `loadRepositories` on Refresh, or whenever the list is empty. Surface the error. In `create()`, give visible feedback when `repository == nil`.
- **Verification:** confirmed and strengthened. Whether `gh repo list <org>` fails for a SAML-protected org depends on GitHub, which keeps that trigger at medium confidence. The launch-failure path makes the silent no-op reachable without any org.

#### P2. A failed comments load leaves "Loading comments…" spinning forever
- **Severity:** medium · **Confidence:** high (spinner with no error state) / low (null-user decode trigger)
- **File:** `Sources/Punchlist/IssuesStore.swift:224-231`, `Sources/Punchlist/IssueDetail.swift:81-86`, `Sources/Punchlist/Models.swift:160-167`
- **Code:**
  ```swift
  guard let loaded = try? await GH.comments(for: issue) else { return }
  comments[issue.id] = loaded
  ```
  ```swift
  } else if issue.commentsCount > 0 {
      HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Loading comments…").foregroundStyle(.secondary)
  ```
- **Why it matters:** Errors are swallowed and the view treats `nil` as "still loading". There is no failed state and no Try Again. Decoding is all-or-nothing across every page, and `Comment.user` isn't optional.
- **Failure scenario:** The user opens an issue while offline or during a secondary rate limit. The spinner never stops, and the conversation never appears until the user selects a different item and comes back, or a Refresh changes `updatedAt`.
- **Suggested fix:** Keep a per-issue load state (`.loading`, `.loaded`, `.failed(String)`) and render failures with Try Again. Make `Comment.user` optional, or decode it leniently.
- **Verification:** downgraded (confidence on part of the scenario). The original claim that "reselecting the same issue doesn't help" is only half right. Clicking the same row again does nothing, but selecting another item and returning changes the `.task(id: issue)` key and retries. The core defect, an endless spinner with no error, is confirmed. GitHub returns a `ghost` user for deleted accounts, so `"user": null` is rare in practice, and confidence in that trigger is low.

#### P4. Each query change can spend two 1,000-item searches against the 30-requests-per-minute search API
- **Severity:** low · **Confidence:** medium
- **File:** `Sources/Punchlist/ContentView.swift:21-24`, `Sources/Punchlist/IssuesStore.swift:195-201`, `:204-219`, `Sources/Punchlist/GH.swift:74-79`
- **Code:**
  ```swift
  .task(id: store.query) {
      await store.load()
      await store.prefetchOtherTab()
  }
  ```
  ```swift
  let owners = try await GH.owners(includeOrgs: query.includeOrgs)   // re-fetched on every search
  ```
- **Why it matters:** `--limit 1000` pages 100 results at a time, so a broad query costs up to 10 search-API requests. Each query change searches both tabs, and superseded searches are never cancelled (C1).
- **Failure scenario:** An account with close to 1,000 or more matching items in both tabs switches to Closed and then All within a minute. That is up to 40 search requests against a limit of 30 per minute. The next search fails, and with rows on screen the failure is silent (P1).
- **Suggested fix:** Keep the documented 1,000-item cap and the deliberate prefetch, but cache `owners` for the session (it is fetched on every search), and prefetch only when the other tab's cache is missing, not merely stale. Cancel superseded searches once C1 lands.
- **Verification:** downgraded (severity medium → low). The trigger needs at least 900 results per query in both tabs, which most personal accounts won't reach. The 120 s cache already absorbs back-and-forth switching. The original fix ("a smaller `--limit` for Closed/All") conflicts with the 1,000-item cap documented in the README, so it was narrowed.

#### P5. The remembered `newIssueRepository` and the repo filter aren't checked against repos that accept issues
- **Severity:** low · **Confidence:** high
- **File:** `Sources/Punchlist/NewIssueRow.swift:7`, `:67-71`, `:97`
- **Code:**
  ```swift
  @AppStorage("newIssueRepository") private var lastRepository = ""
  ...
  store.repoFilter
      ?? (lastRepository.isEmpty ? nil : lastRepository)
      ?? store.issueRepositories.first
  ```
- **Why it matters:** Neither candidate is checked against `issueRepositories`, the repos with `hasIssuesEnabled`. While a repo filter is active, the menu is disabled (`:97`), so the user can't override it.
- **Failure scenario:** The user filters to a repo with issues disabled and submits. The pending row fails with GitHub's error, and choosing another repo requires clearing the filter. A remembered repo that was later archived fails the same way until the user picks again.
- **Suggested fix:** Use a candidate only if `store.issueRepositories.contains(candidate)`. Let the menu override the filter, or label the filter repo as unavailable.
- **Verification:** confirmed. The failure is visible, because the pending row shows Retry and Discard, so low is the right severity.

### 3.4 Accessibility

#### A1. In the compact layout, rows can be opened only by a pointer click
- **Severity:** medium · **Confidence:** high (keyboard) / medium (VoiceOver activation)
- **File:** `Sources/Punchlist/ContentView.swift:139`, `:172-178`, with `IssueRow` at `:346`
- **Code:**
  ```swift
  List { rows(onOpen: onOpen).listRowSeparator(.hidden) }
  ...
  IssueRow(issue: issue, ...)
      .contentShape(.rect)
      .onTapGesture { onOpen(issue) }
  ```
- **Why it matters:** The compact `List` has no selection binding, so the arrow keys and Return can't move to or open a row. Opening is an `onTapGesture` on a `.combine`d element with no `.isButton` trait and no explicit action. The row's context menu offers Open in Browser but not the in-app detail. The menu bar's Issue menu needs `selectedIssue`, which only opening a row sets.
- **Failure scenario:** A keyboard-only or Full Keyboard Access user with a window narrower than 640 pt can't open an issue's detail. VoiceOver announces rows without a button affordance.
- **Suggested fix:** Make each row `Button { onOpen(issue) } label: { IssueRow(…) }.buttonStyle(.plain)`. Alternatively, bind selection and open on `primaryAction`. At a minimum, add `.accessibilityAddTraits(.isButton)` and `.accessibilityAction { onOpen(issue) }`.
- **Verification:** confirmed. The SwiftUI accessibility guidance agrees: avoid `onTapGesture` for activation, or add `.isButton`. Whether VO-Space triggers the gesture needs VoiceOver to check, so that part stays at medium confidence.

#### A2. Comment header controls have no meaningful VoiceOver labels
- **Severity:** low · **Confidence:** medium
- **File:** `Sources/Punchlist/IssueDetail.swift:98-104`, `:117-120`
- **Code:**
  ```swift
  AsyncImage(url: comment.user.avatarUrl) { image in image.resizable() } placeholder: { ... }
  ...
  Link(destination: comment.htmlUrl) {
      Image(systemName: "arrow.up.right.square")
  }
  .help("Open comment on GitHub")
  ```
- **Why it matters:** `.help` supplies a tooltip and hint, not a label. The icon-only link depends on whatever label the symbol provides, and the decorative avatar isn't hidden.
- **Failure scenario:** VoiceOver doesn't say what the link does in each comment header, and it may announce an extra unlabeled image.
- **Suggested fix:** Use `Label("Open comment on GitHub", systemImage: "arrow.up.right.square").labelStyle(.iconOnly)`, and add `.accessibilityHidden(true)` to the avatar.
- **Verification:** downgraded (confidence high → medium). The missing labels are certain from reading. What VoiceOver actually says depends on the symbol's built-in label and how `AsyncImage` is exposed, which needs a Mac to check.

#### A3. The detail's state badge is low-contrast white text on system colours
- **Severity:** low · **Confidence:** medium
- **File:** `Sources/Punchlist/IssueDetail.swift:18-23`, with the colours from `Sources/Punchlist/Models.swift:149-154`
- **Code:**
  ```swift
  Label(badge.title, systemImage: badge.symbol)
      .font(.caption.weight(.semibold))
      ...
      .background(badge.color, in: .capsule)
      .foregroundStyle(.white)
  ```
- **Why it matters:** Caption-size white text on light-mode system green (about 2:1), gray, red or purple falls under the 4.5:1 that small text needs.
- **Failure scenario:** Low-vision users struggle to read "Open" or "Draft", and the badge is the only text in the detail that states the item's state.
- **Suggested fix:** Use darker fills, or a tinted fill with coloured text. Check the result in both appearances.
- **Verification:** confirmed, with one correction. The finding said nothing adapts to Increase Contrast, but system colours do have high-contrast variants, so drop that part. The default-contrast ratio is still too low. The exact ratios on macOS 27 need Accessibility Inspector.

#### A4. The compact detail slides in and out regardless of Reduce Motion
- **Severity:** low · **Confidence:** high
- **File:** `Sources/Punchlist/ContentView.swift:94`, `:100`, `:108-116`, `Sources/Punchlist/PunchlistApp.swift:44`
- **Code:**
  ```swift
  .offset(x: store.selectedIssue == nil ? 0 : -width / 4)
  ...
  .transition(.move(edge: .trailing))
  ...
  withAnimation(.smooth(duration: 0.3)) { store.selection = issue.id }
  ```
- **Why it matters:** A full-width slide plus parallax is exactly the motion Reduce Motion asks apps to replace. Nothing in the project reads `accessibilityReduceMotion` (checked with grep).
- **Failure scenario:** A user with vestibular sensitivity gets the full slide every time they push or pop the detail.
- **Suggested fix:** Read `@Environment(\.accessibilityReduceMotion)`, and when it is on use `.opacity`, no offset, and a short or `nil` animation. Do the same for the menu-bar Back command.
- **Verification:** confirmed. SwiftUI doesn't swap custom `.move` transitions for you.

### 3.5 Test quality

Package.swift has no test target, so there are no tests that can't fail, timing-based waits or hangs to judge. These findings name the riskiest untested logic.

#### T1. The overlay that keeps local changes over lagging search results, and save idempotency, are untested
- **Severity:** medium · **Confidence:** high
- **File:** `Sources/Punchlist/IssuesStore.swift:324-346` (`applyRecentChanges`), `:350-360` (`updateState`), `:262-290` (`save`)
- **Code:**
  ```swift
  if fromSearch { createdIssues.removeAll { found.contains($0.issue.id) } }
  ...
  if items[index].state != confirmed.state {
      items[index].state = confirmed.state
  } else if fromSearch {
      confirmedStates[items[index].id] = nil
  }
  ```
  ```swift
  if let created = pending.url { url = created } else {
      url = try await GH.createIssue(...)
  ```
- **Why it matters:** This logic decides what the user sees after every close, reopen, merge and create, and whether a retry creates a duplicate issue on GitHub. It has many branches: `fromSearch`, `includeOrgs`, the `login` prefix, the closed-state exclusion, expiry, and the `.distantPast` invalidation.
- **Failure scenario:** A refactor drops a confirmation, or loses `pending.url`. A closed issue reappears as open, or Retry creates a duplicate issue on GitHub, and nothing catches it.
- **Suggested fix:** Add a `PunchlistTests` target, put `GH` behind a `GitHubClient` protocol injected into `IssuesStore`, and write `@MainActor` Swift Testing tests against a fake (see the plan in section 4).
- **Verification:** confirmed. No test target exists, and the logic is pure in-memory data that can be tested once `GH` is injectable.

#### T2. Decoding of the JSON that `gh` returns is untested
- **Severity:** low · **Confidence:** high
- **File:** `Sources/Punchlist/GH.swift:74-79`, `:102-124`, `:169-175`, `:177-181`, and `Sources/Punchlist/Models.swift:160-167`
- **Code:**
  ```swift
  decoder.dateDecodingStrategy = .iso8601
  ...
  decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode([[Comment]].self, from: data).flatMap(\.self)
  ```
- **Why it matters:** Every decode is all-or-nothing. `.iso8601` rejects fractional seconds, `--slurp` produces nested arrays, and the snake-case mapping has to line up with property names.
- **Failure scenario:** A change in the app, such as a renamed field, a different key strategy or a dropped `--slurp`, breaks the list or the comment threads, and only users notice.
- **Suggested fix:** Add fixture tests with `@Test(arguments:)` over recorded `gh` outputs, including a null user, an empty body, absent `isDraft`, multi-page slurp, and `createIssue`'s multi-line URL parsing.
- **Verification:** downgraded (severity medium → low). The test gap is real. However, the original failure scenario, a `gh` upgrade changing its output, is not something recorded fixtures would catch. They guard only against the app's own regressions, which are less likely here because the decoders are simple.

#### T3. Time-dependent cache logic uses the wall clock directly, so it can't be tested deterministically
- **Severity:** low · **Confidence:** medium
- **File:** `Sources/Punchlist/IssuesStore.swift:166`, `:199`, `:325`, `:337` (also `:179`, `:217`, `:279`, `:311`)
- **Code:**
  ```swift
  if !force, let cached, cached.at.timeIntervalSinceNow > -Self.freshness {
  ...
  createdIssues = createdIssues.filter { $0.at.timeIntervalSinceNow > -Self.searchLag }
  ```
- **Why it matters:** The boundaries of the 120 s freshness window and the 300 s search-lag window can be tested only with real sleeps.
- **Failure scenario:** A regression at a boundary goes unnoticed. A manual clock change also stretches or collapses both windows.
- **Suggested fix:** Inject a clock (`any Clock<Duration>`, or `now: () -> Date`), and store `ContinuousClock.Instant`. Test 119/121 s and 299/301 s with a manual clock. Don't use `Task.sleep` in tests.
- **Verification:** confirmed, with a correction. Sleep and wake don't make the wall clock jump relative to elapsed real time, so only manual changes and large NTP corrections apply. The main value of this change is testability.

---

## 4. Plan of action

Land these in order. PR 1 adds the seam that the tests in the later PRs depend on.

| # | PR | Size | Findings | Tests to add with it |
| --- | --- | --- | --- | --- |
| 1 | **Add `PunchlistTests` and a `GitHubClient` seam.** Put `GH` behind a protocol injected into `IssuesStore`, and inject a clock. | L | T1, T2, T3 | `IssuesStoreOverlayTests` (`@MainActor`, fake client): create, then a search without the issue, then a search with it. Close, then a lagging search, then a caught-up search. Create succeeds and read-back fails, then Retry calls `createIssue` exactly once. An org-repo create with `includeOrgs == false` is not injected. A closed-tab query never gets created issues. `CacheClockTests`: freshness at 119/121 s and lag at 299/301 s, using a manual clock. `GHDecodingTests` with `@Test(arguments:)` over fixtures: search issues and PRs, `issue view`, comments slurp with several pages, `"user": null`, fractional-second dates (expected to fail until fixed), and `createIssue` URL parsing. |
| 2 | **Cancellable, non-blocking `gh` runner.** Use `terminationHandler`, drain both pipes, terminate on cancel, and harden the login-shell lookup. Add the cancellation and setting guard to `loadRepositories`. Skip comment reloads that aren't needed. | M | C1, C2, C4, C3 | `ProcessRunnerTests` (run real `/bin/sh` scripts, no `gh`): `sleep 30`, then cancelling returns within 1 s and the child is gone. A script writing 200 KB to stderr before stdout completes. A non-zero exit carries stderr as the message. `ExecutableLookupTests`: banner text plus a path on the last line resolves to the path, and garbage resolves to `nil`. `RepositoriesRaceTests`: toggle orgs on and off, with the fake making "on" slower, and assert that `allRepositories` matches the final setting. |
| 3 | **Surface sync failures.** Show a refresh-failure indicator and `lastUpdated`, add a comments load state with Try Again, collect repos per owner and retry them on Refresh, give `create()` feedback, and validate the new-issue repository. | M | P1, P2, P3, P5 | Store tests with the fake client: a successful load followed by a failed one keeps the rows and exposes the error. A comments failure produces `.failed`, and retrying produces `.loaded`. One failing owner keeps the other owners' repos. A failure at launch followed by Refresh fills the repos. Repository resolution skips a filter or remembered repo that isn't in `issueRepositories`. |
| 4 | **Search request budget.** Cache `owners` for the session, prefetch only when the other tab's cache is missing, and cancel superseded searches (needs PR 2). | S | P4 | A counting fake: N status changes make a single `owners` call. Prefetch doesn't re-search a cached tab. A superseded search's task is cancelled. |
| 5 | **Compact layout: keyboard, motion and focus.** Make rows Buttons or selection-driven, honour Reduce Motion, scroll to and focus the new-issue row through `ScrollViewReader`, and keep the draft in the store. | M | A1, A4, UI1, UI2 | Unit: `requestNewIssue()` sets a scroll target, and the draft survives a `isCompact` toggle (store-level). Manual on a Mac: the Full Keyboard Access, VoiceOver and Reduce Motion checks in section 5. |
| 6 | **Detail accessibility polish.** Label the comment link, hide the avatar, and use higher-contrast badge colours. | S | A2, A3 | No unit tests. Run an Accessibility Inspector audit and contrast check, both listed in section 5. |
| 7 | **Single evaluation of `filteredIssues`.** Do this only if PR 5's profiling shows a cost. | S | UI3 | Before refactoring, add `FilterTests` with `@Test(arguments:)` covering repo, labels, text, number and author matching and their combinations, so the cached version is proven equivalent. |

---

## 5. Needs a Mac to confirm

| Finding | Check that would settle it |
| --- | --- |
| Baseline | `swift build -c release` and `swift build -Xswiftc -warnings-as-errors` (Swift 6 mode already means `-strict-concurrency=complete`). Run `swift build -Xswiftc -enable-upcoming-feature -Xswiftc NonisolatedNonsendingByDefault` once to see whether `GH.run`'s executor assumptions change. |
| C1 | Instruments **Swift Concurrency** template plus **System Trace**. In the wide layout, hold ↓ through about 30 rows, then press ⌘R. Look for blocked cooperative threads and Refresh latency, and run `pgrep -fl "gh api"` during the run to count orphaned processes. After PR 2: `swift test --filter PunchlistTests.ProcessRunnerTests`. |
| C2 | `swift test --filter PunchlistTests.ProcessRunnerTests/largeStderrDoesNotDeadlock` (a script writing 200 KB to stderr), against both the current and the fixed runner. |
| C3 | `swift test --filter PunchlistTests.RepositoriesRaceTests`. Manually, toggle Include Organizations twice quickly on an account with orgs and compare the repo filter with `gh repo list <login>`. |
| C4 | Temporarily move `gh` to `~/.local/bin`, add `echo hi` to `~/.zprofile`, and launch the app from Finder. Expect the launch error described in the finding. |
| UI1 | Manually: in demo mode (`--demo`), scroll the issues list to the bottom and press ⌘N, then scroll back up while the search field is focused. To confirm the cause, check whether the row's `.task` ran using the **SwiftUI** Instruments template (view body and lifecycle events). |
| UI2 | Manually: type a title, then drag the window below 640 pt and back. |
| UI3 | Instruments **SwiftUI** and **Time Profiler** with 1,000 items loaded (status All). Type in search and measure `filteredIssues` and the body cost per keystroke. Fix it only if it exceeds a frame. |
| P1 | Manually: load the list, turn Wi-Fi off, and press ⌘R. Expect no visible error. After PR 3: `swift test --filter PunchlistTests.IssuesStoreSyncTests`. |
| P2 | Manually: open an issue with comments while offline. Run `swift test --filter PunchlistTests.GHDecodingTests` with a fixture where `"user": null`. |
| P3 | Launch offline with the `newIssueRepository` default removed (`defaults delete <bundle-id> newIssueRepository`), go back online, and try to create an issue. If one is available, also try with an org whose SAML SSO isn't authorized for the `gh` token, and run `gh repo list <org>` directly to see whether it fails. |
| P4 | `gh api rate_limit -q .resources.search` before and after switching Closed, then All, on a large account. |
| A1 | Turn on **Full Keyboard Access** (System Settings > Accessibility > Keyboard), narrow the window below 640 pt, and try to open a row. With **VoiceOver**, VO-Space on a row. Use **Accessibility Inspector** to check the row's traits and actions. |
| A2 | Accessibility Inspector: inspect the comment header link's label and the avatar element. Listen to the actual output with VoiceOver. |
| A3 | Accessibility Inspector's **Color Contrast Calculator** on the Open, Draft, Closed and Merged badges, in light and dark mode, with Increase Contrast on and off. |
| A4 | Turn on **Reduce Motion** (System Settings > Accessibility > Display) and push and pop the detail in the compact layout with a click and with ⌘[. |
| All tests | After PR 1: `swift test --sanitize=thread` to catch data races in the `@MainActor` store and the process runner. In Xcode: `xcodebuild test -scheme Punchlist -destination 'platform=macOS' -only-testing:PunchlistTests/IssuesStoreOverlayTests`. |

---

## Appendix: Dropped findings

| ID | Title | Reason dropped |
| --- | --- | --- |
| None | | No raw finding was disproved. Each was traced to code at HEAD, and none contradicts a documented decision. Overstated items were downgraded rather than dropped (see the Verification notes on C1, C2, C4, UI3, P2, P4, A2 and T2). |
