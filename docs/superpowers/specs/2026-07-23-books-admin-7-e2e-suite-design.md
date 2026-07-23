# Books admin — increment 7: Playwright suite (targeted parity)

**Status:** design approved 2026-07-23, pending plan.
**Parent design:** `docs/superpowers/specs/2026-07-13-books-admin-ui-design.md` (umbrella; increment 7,
"Playwright suite mirroring games' nine specs"). This is the **final** increment of the books admin.
**Predecessors:** 1–6 all merged; the shared-mutation write-gating PR (#177) merged.

## Goal

Bring the books admin end-to-end suite up to games-level **high-value** coverage. Each increment already
shipped a per-entity smoke spec (index + create + one interaction, ~20 tests across 9 files); this
increment adds the missing lifecycle depth and the sidebar-nav spec games has and books lacks.

**No application code changes — Playwright specs only.** Low blast radius.

## Scope

**In (all in `web-app/e2e/tests/books/admin/`, direct-Playwright, `books-admin` project + stored session,
mirroring the existing books-spec conventions):**
- **New `sidebar-nav.spec.ts`** — assert every sidebar link navigates + lands on the right heading, via
  `page.getByTestId('admin-sidebar')`: **Books, Authors, Series, Categories, Lists, Rankings** (domain
  items) + **Penalties, Users** (the global section). Directly guards the "dead sidebar link" landmine
  that bit multiple prior increments.
- **Deepen the entity specs** to the full high-value lifecycle — **show-page navigation** (row → show),
  **edit/update**, **delete** — for: `books`, `authors`, `series`, `categories`, `editions` (nested under
  a created book), `lists`, `ranking-configurations`.
- **Lists** — add penalty **attach/detach** via the modal (relevant now the write-gating landed).
- **Ranking-configurations** — add show-details, update, delete, and an action-buttons-present check.

**Out / deferred (per owner's "targeted parity" scope choice):**
- Exhaustive validation-error specs and search/sort/filter/status-filter specs (games has these; the
  books admin already has thorough Minitest controller coverage of that behavior — low marginal e2e value).
- Adopting games' Page Object Model / auth fixtures — books keeps its simpler direct-Playwright style
  (mirroring coverage, not structure; a POM refactor of the 9 existing specs is not worth it).
- `dashboard.spec.ts` is left as-is (branding + counts already covered); optional light extension only.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| 7-1 | **Every edit/update/delete test creates its own `Date.now()`-named record first, then mutates *that*** — never edits/deletes a seeded book/author/list/etc. | **The books dev data cannot be rebuilt** ([[dev-db-is-not-disposable]]). Create-then-mutate touches zero real data (only adds test-named cruft, exactly like the existing create specs). This is the games pattern (`categories-crud` "delete"/"edit" both create-first). |
| 7-2 | Keep **direct Playwright** (raw `page`, stored `books-admin` session), not games' POM/fixtures. | Mirror games' *coverage*, not its *structure*; a POM rewrite of the 9 existing books specs is a large refactor for little value. |
| 7-3 | Targeted parity: add sidebar-nav + edit/delete/show-nav + lists-penalty + RC depth; **skip** validation-error and search/sort/filter. | Owner's scope choice — the high-value UI-integration surfaces (forms, turbo frames, modals, sidebar) that unit tests miss, without brittle low-value churn over strong existing Minitest coverage. |
| 7-4 | One PR. | Final increment, e2e-only, no app code — low risk. |
| 7-5 | Deletes accept the `turbo_confirm` dialog: `page.on('dialog', d => d.accept())`. | Books delete buttons use `turbo_confirm`; matches the games delete pattern. |

## The specs

Roughly ~30 new tests, added to the existing 9 files + one new file. Per entity, the added lifecycle:

- **`sidebar-nav.spec.ts`** (new) — 8 link-navigation tests (6 domain + Penalties + Users), each asserting
  the URL and the destination heading (e.g. Lists → `/admin/lists`, heading "Book Lists"; Series →
  `/admin/series`, "Series"; Rankings → `/admin/ranking_configurations`).
- **`books.spec.ts`** — add: create a book → edit its title → delete it.
- **`authors.spec.ts`** — add: create → edit → delete.
- **`series.spec.ts`** — add: create → edit → delete.
- **`categories.spec.ts`** — add: create → edit → delete (soft-delete; accept dialog).
- **`editions.spec.ts`** — add: from a freshly created book, create an edition → edit it → delete it.
- **`lists.spec.ts`** — add: create → edit → delete; and attach a penalty via the modal → detach it.
- **`ranking-configurations.spec.ts`** — add: create → navigate to show (assert details/action buttons) →
  update → delete.

Each mutation test is self-contained (creates its own record). Selectors follow the shipped views (verify
exact heading text and button labels against the components, as the existing specs do — e.g. "Create Book
List" / "Update …" / "Delete").

## Testing / verification

- Run the `books-admin` project against the live dev server:
  `yarn test:e2e e2e/tests/books/admin/` — all green.
- Needs `bin/dev` up and a valid books-admin session; if admin specs redirect to the public homepage, the
  e2e user lost its role — `bin/rails e2e:admin` ([[e2e-admin-user-dies-on-reseed]]).
- No `bin/rails test` / `standardrb` impact (no Ruby changed), but run them once to confirm the tree is
  otherwise clean.

## Risks

| Risk | Mitigation |
|---|---|
| An edit/delete test mutates real books data | 7-1: create-then-mutate own record; never target seeded data. Reviewer verifies each mutation test creates its own record first. |
| Brittle selectors drift from the shipped views | Verify each heading/label against the actual component (the existing specs already do this); prefer role/name/testid over CSS. |
| The suite is slow / flaky against the live server | Keep tests self-contained and independent; accept dialogs explicitly; use `waitForURL`/`toBeVisible` (auto-retrying) not fixed sleeps. |
