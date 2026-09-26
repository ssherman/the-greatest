# Page fetcher: crash recovery note (delete before merge)

The machine crashed at about **11:41:40 CDT on 2026-09-26**, partway through subagent-driven
execution of `docs/superpowers/plans/2026-09-26-page-fetcher-service.md`. The owner suspects
hard-drive trouble, so this note and the branch are pushed as they stood. Delete this file before
the branch merges.

## When and where it stopped

- **Controller session:** `2bfdc339-2381-43fa-ab4c-1ee80fcbaade`, in the worktree
  `.claude/worktrees/page-fetcher`. Its last entry is at 11:35:15: "Fix round 1 for Task 2 is
  running (it includes a Docker rebuild). Waiting for the hand-back." The transcript is intact.
- **Last activity:** the Task 2 implementer subagent (`a890c8aca1a23b6f0`, sonnet) was running its
  final `docker build`. The build started at 11:40:16 and passed `install_check` (`#16 DONE`). It was
  on `#17 unpacking to docker.io/the-greatest/page-fetcher:dev` when the log stops at 11:41:37. The
  subagent's transcript was last written at 11:41:47.
- **Crash signature:** that subagent's transcript and `docker-build-5-final.log` both end in null
  bytes, which is what unflushed pages look like after a hard power-off. The machine went down
  during a multi-gigabyte image unpack. Everything else checked out: `git fsck` was clean, and no
  other text file in the worktree has null bytes.

## Where the plan stands

| Task | State |
|---|---|
| 1: fetcher package + extra | **Complete.** `c0af3fe2`, review clean |
| 2: fetcher image, install check, launch gate | **Implemented; fix round 1 committed but NOT re-reviewed.** `3c1ae757` + `8912d38d` |
| 3–12 | Not started |

Task 2 detail:

- **Gate passed:** warm launch + page median 0.94 s (runs 2–6), cold 1.25 s. Goodreads returned 200,
  "The Great Gatsby by F. Scott Fitzgerald | Goodreads", 6.15 s including launch.
- **Review found (opus `ad4f42a5bb576fcda`):** Important 1: the Camoufox pin was decorative.
  Important 2: `install_check` ignored ldd's exit code. Minor 1: the LD_LIBRARY_PATH comment named a
  false mechanism. Minor 2: the image is 3.71 GB against the spec's "roughly 1GB" (deferred to
  Task 10's feature doc).
- **Fix round 1** (both Importants + Minor 1) sat uncommitted when the machine went down. The
  recovery session committed it unchanged as `8912d38d`, after `ruff check`/`ruff format --check`
  came back clean and `pytest tests/fetcher` passed (6).

## Resume here

1. Dispatch a **fresh** opus re-review of `3c1ae757..8912d38d`. Do not resume `a890c8aca1a23b6f0`:
   its transcript ends in a corrupt line.
2. Raise this with the re-review: the new ldd non-zero-exit branch in `install_check.main()` has no
   test. The existing 6 tests cover only the pure helpers.
3. Rebuild the image before trusting it. The tagged `the-greatest/page-fetcher:dev`
   (`cef7a88a0fb0`) is the build whose unpack was cut off.
4. When Task 2 is clean, carry the 3.71 GB image-size minor into the Task 10 dispatch and start
   Task 3.

The briefs in `.superpowers/sdd/2026-09-26-page-fetcher-service/` are regenerable from the plan.
The ledger is not, and it lives in a gitignored directory, so a copy follows as it stood after the
crash was recorded. The task reports (`task-1-report.md`, `task-2-report.md`, which holds the raw
measurement output) were not copied and exist only on the local disk.

## Appendix: SDD ledger snapshot

    # SDD ledger — plan: docs/superpowers/plans/2026-09-26-page-fetcher-service.md
    
    Spec: docs/superpowers/specs/2026-09-26-page-fetcher-service-design.md (reachable; binding)
    Worktree: .claude/worktrees/page-fetcher, branch worktree-page-fetcher, fast-forwarded to page-fetcher-spec @ 88acf6a2
    Models: implementers sonnet, reviewers (task, re-review, final) opus. Never fable, never omitted.
    Gitignored files: none copied by EnterWorktree; all five copied by hand from the main checkout (node_modules symlinked).
    
    ## Pre-flight scan
    
    Evidence already in hand: before this run, every Python and Ruby block in the plan was executed verbatim in a scratch copy.
    The full data-sources suite passed, including 187 fetcher tests. The 34 page_fetcher Minitest tests passed.
    ruff, standardrb and zeitwerk were clean. Not executed: the Docker build (Task 2) and the smoke check (Task 10).
    
    ### Cross-task rows (shared file or interface)
    
    | Tasks | Producer → consumer | Finding |
    |---|---|---|
    | 1 → 2 | pyproject `fetcher` extra + `src/fetcher` package → Dockerfile `uv sync --extra fetcher`, `COPY src/` | consistent |
    | 4 → 6 | tests/fetcher/fakes.py: T4 creates `resolver`; T6 replaces the file with a superset whose `resolver` is identical | consistent (T4 tests keep passing after T6) |
    | 4 → 7 | `HostChecker.non_public_address` raises InvalidUrl/Unresolvable → guards catch both | consistent |
    | 4 → 8 | `HostChecker.check`, `Resolver`, `system_resolver` | consistent |
    | 5 → 8 | `Budget.run(aw, stage)`, `StageTimeout.stage`, `Limiter.slot(host, budget)` yields bool | consistent |
    | 6 → 7 | `DocumentResponse(url, status, redirect_chain)` | consistent |
    | 6 → 8 | Browser/BrowserSession protocols, the 5 BrowserFailure subclasses, FakeBrowser attributes | consistent |
    | 6 → 10 | T10 replaces browser.py's import block (superset) and appends classes using `_first_line`, `playwright_ms`, `translate_playwright_error`; T6's import-isolation test walks T10's code | consistent |
    | 7 → 8 | `RequestFilter.blocked_navigations`; `first_non_public_hop` → `(host, reason)` | consistent |
    | 8 → 9 | FetchRequest fields == request body fields; FetchResult fields == FetchResponseBody fields | consistent |
    | 9 → 10 | `create_app()` with no args imports `CamoufoxBrowser`, which T10 creates | transient gap between T9 and T10, see Ruling 3 |
    | 2 → 10 → 12 | docs/features/page-fetcher-service.md: T2 creates "Measured", T10 rewrites around it, T12 inserts "Rails client" before it | consistent; T10 step 8 says the marker keeps T2's section |
    | 2 → 10 | Dockerfile CMD `fetcher.api.main:factory` (T9) | consistent; T2 overrides the command for its measurement |
    | 11 → 12 | `Configuration`, `HttpError(error_code:)`, `UpstreamError`, `CircuitOpenError`, `Page.from_response` | consistent |
    | 12 → existing | `Books::OpenLibrary::CircuitBreaker(redis:)`, `Books::OpenLibrary::FakeRedis` (loaded by test_helper) | consistent (read in session) |
    
    ### Per-task self-consistency rows
    
    | Task | Tests vs code; files created vs touched | Finding |
    |---|---|---|
    | 1 | packaging test vs `fetcher.__version__`; CI edit | consistent (executed) |
    | 2 | 6 install_check tests vs module; Dockerfile unexecuted | Docker unexecuted: risk, see Ruling 1 |
    | 3 | settings tests vs Settings | consistent (executed) |
    | 4 | urlcheck tests incl. real-resolver numeric hosts | consistent (executed, glibc) |
    | 5 | budget/limiter timing tests | consistent (executed) |
    | 6 | translation, `playwright_ms`, import-walk tests | consistent (executed) |
    | 7 | guards tests | consistent (executed) |
    | 8 | 31 fetcher tests | consistent (executed) |
    | 9 | API tests | consistent (executed) |
    | 10 | 3 backend unit tests executed; compose/smoke unexecuted | the smoke check's healthy-wait needs a rule, see Ruling 2 |
    | 11 | 3 Rails test files | consistent (executed) |
    | 12 | client tests; full suite, zeitwerk | consistent (executed); the zeitwerk and MultiJson notes are already in the plan |
    
    ### Rulings
    
    - Ruling: Docker builds (Tasks 2 and 10) run in the foreground with a 600000 ms Bash timeout. If a build exceeds that, the implementer runs it in the background to a log file, STOPS and reports "launched"; the controller owns the wait and resumes it — a subagent's own monitor does not wake it (memory: subagent-monitors-do-not-wake) — cost if wrong: one extra resume round.
    - Ruling: Task 10 Step 6 waits for health with `docker compose up -d --build --wait --wait-timeout 180 fetcher` rather than a polling loop — the plan's intent (wait until healthy) with no foreground sleep, which the harness blocks — cost if wrong: none; a compose too old for `--wait` falls back to polling `docker compose ps`.
    - Ruling: between Task 9 and Task 10, `create_app()` with no argument cannot import `CamoufoxBrowser`. Accepted as plan order — nothing calls the default path until Task 10, and nothing deploys in between — cost if wrong: none.
    - Ruling: the worktree guard refuses multi-line or compound commands, so implementers may commit with `git commit -F <message file in this workspace>`. The message must keep the Co-Authored-By footer verbatim — cost if wrong: none.
    
    ## Progress
    
    Task 1: dispatched (BASE 88acf6a2, implementer a45367c9ca1cf3dbf, sonnet)
    Task 1: implementer DONE c0af3fe2; reviewer ad9056e962cb82483 (opus) dispatched on 88acf6a..c0af3fe
    Task 1: minor (deferred): data-sources/README.md:12 and AGENTS.md:54 tell people to install with a bare `uv sync --locked`, which strips the fetcher extra (uv sync is exact). The pyproject comment "Only the fetcher image and CI install it" contradicts the rule that every install uses --extra fetcher.
    Ruling: Task 10 Step 9 also rewrites README's `uv sync --locked` Commands line and AGENTS.md's "every install uses `uv sync --locked`" to include `--extra fetcher`, and rewords the pyproject comment ("the Open Library image never installs it") — the review is right and Task 10 already edits both docs — cost if wrong: a few doc lines.
    Task 1: minor (deferred): platformdirs 4.12.0 was locked on its release day, pulled in by camoufox with no version bound. Informational. `[tool.uv] exclude-newer` would add a waiting period if ever wanted.
    Task 1: ⚠️ "CI passes with --extra fetcher" resolved: the local `uv sync --locked --extra fetcher` succeeded and Playwright ships a manylinux wheel; CI itself runs at PR time.
    Task 1: complete (commits 88acf6a2..c0af3fe2, review clean)
    Task 2: dispatched (BASE c0af3fe2, implementer a890c8aca1a23b6f0, sonnet)
    Task 2: implementer DONE_WITH_CONCERNS 3c1ae757. GATE PASSED: warm launch + page median 0.94 s (runs 2-6), cold 1.25 s; Goodreads 200, "The Great Gatsby by F. Scott Fitzgerald | Goodreads", 6.15 s including launch.
    Ruling: pin official/stable/152.0.4-beta.31 instead of the plan's beta.30 — spec §4 says "the newest stable build 0.5.6 accepts on the day", and beta.31 is that; it is also the build that was measured — cost if wrong: a one-line ARG change.
    Task 2: controller-confirmed finding (plan defect, Important): `camoufox set X && camoufox fetch` does not pin. On a fresh cache, `fetch` rmtree's INSTALL_DIR because `.0.5_FLAG` is missing (__main__.py:257; the flag is only touched after an install, multiversion.py:453), and that deletes the config.json pin `set` wrote. So the build installs the newest release and only matches the pin by coincidence; the next upstream release will fail the build. Fix: `camoufox fetch "$CAMOUFOX_BROWSER"` (a 3-part spec is accepted; it installs that version and set_active's it). Joins the fix loop with the reviewer's findings.
    Task 2: reviewer ad4f42a5bb576fcda (opus) dispatched on c0af3fe..3c1ae75
    Task 2: review = Needs fixes. Important 1 (plan-mandated): the pin is decorative, as above; confirmed in the image (config.json has no `pinned` key). Important 2 (plan-mandated): install_check ignores ldd's exit code and stderr, so an ldd that fails (for example on a moved libxul.so) reads as "nothing missing". Minor 1: the LD_LIBRARY_PATH comment names a false mechanism; Firefox preloads its siblings by absolute path from dependentlibs.list. Minor 2: the image is 3.71 GB against the spec's "roughly 1GB"; the browser alone is 1.2 GB.
    Ruling: fix both plan-mandated Importants — spec §4 requires one named build and a check that fails loudly; the plan's code violated both — cost if wrong: none.
    Ruling: fold Minor 1 into this fix round — same lines, and a false comment should not ship — cost if wrong: none.
    Task 2: minor (deferred): the 3.71 GB image size goes into Task 10's feature doc (carry it in the Task 10 dispatch).
    Task 2: fix round 1 applied by implementer a890c8aca1a23b6f0 (both Importants + Minor 1). Build 4 (fix1) succeeded end to end; build 5 (comment-only reword) passed install_check.
    ⚠️ SESSION CRASHED ~11:41:40 CDT 2026-09-26: the machine died while build 5 was unpacking the image. The controller (2bfdc339) never received the hand-back. The implementer's transcript ends in null bytes. Its log docker-build-5-final.log does too.
    Task 2: recovery session (2026-09-26 13:xx) committed the uncommitted fix round unchanged as 8912d38d after re-running ruff (clean) and tests/fetcher (6 passed), then pushed the branch.
    Task 2: NEXT = dispatch a fresh opus re-review on 3c1ae757..8912d38d (do not resume a890c8a; its transcript is truncated). Then carry the 3.71 GB image-size minor into Task 10, and start Task 3.
    Task 2: open (for the re-review): the new `ldd` non-zero-exit branch in install_check.main() has no test. main() is untested throughout; the 6 tests cover the pure helpers only.
    Task 2: rebuild the image before trusting it: the tagged the-greatest/page-fetcher:dev (cef7a88a0fb0) is build 5, and its unpack was cut off.
