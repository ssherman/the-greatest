# Books Admin — Increment 7: Playwright Suite (targeted parity) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the books admin Playwright suite to games-level high-value coverage — a new `sidebar-nav` spec plus edit/delete (and lists-penalty / RC) lifecycle depth on the existing specs.

**Architecture:** Direct Playwright (raw `page`, stored `books-admin` session), extending the existing `web-app/e2e/tests/books/admin/*.spec.ts`. No application code changes.

**Tech Stack:** Playwright, the `books-admin` project (baseURL `https://dev-new.thegreatestbooks.org`, stored auth).

## Global Constraints

- Run all commands from `web-app/`. These are e2e specs — no Ruby changes; `bin/rails test`/`standardrb` are unaffected.
- **The books dev data cannot be rebuilt.** Every edit/update/delete test MUST create its own `Date.now()`-named record first and mutate *that* — never edit or delete a seeded book/author/series/list/category/edition/RC. Read-only navigation (clicking an existing row → show) is fine.
- Deletes use `turbo_confirm`: register `page.on('dialog', d => d.accept())` **before** clicking Delete.
- Prefer role/name/testid selectors over CSS; use auto-retrying assertions (`toBeVisible`, `waitForURL`) — no fixed sleeps.
- Match the existing books-spec conventions (imports, `test.describe`, `Date.now()` names). Confirmed labels: create/update submit buttons are `Create/Update Book`, `…Author`, `…Series`, `…Edition`, `…Category`, `Create/Update Book List`, `Create/Update Configuration`; every show page has an `Edit` link and a `Delete` button.
- **Running requires the live dev server** (`bin/dev` up) and a valid books-admin session (`bin/rails e2e:admin` if admin specs redirect to the public homepage). If the server is unavailable, the spec is still code-complete and must at least register via `yarn playwright test --list`; note the un-run status.
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Branch `books-admin-7-e2e` (already created off main).

---

### Task 1: `sidebar-nav.spec.ts` (new)

Assert every books sidebar link navigates and lands on the right page. Guards the "dead sidebar link" landmine.

**Files:**
- Create: `web-app/e2e/tests/books/admin/sidebar-nav.spec.ts`

- [ ] **Step 1: Write the spec**

```ts
import { test, expect } from "@playwright/test";

test.describe("Books admin — sidebar navigation", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/admin");
  });

  const sidebar = (page: import("@playwright/test").Page) => page.getByTestId("admin-sidebar");

  test("Books link navigates to the books index", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Books", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/books/);
    await expect(page.getByRole("heading", { name: "Books", exact: true, level: 1 })).toBeVisible();
  });

  test("Authors link navigates to the authors index", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Authors", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/authors/);
    await expect(page.getByRole("heading", { name: "Authors", level: 1 })).toBeVisible();
  });

  test("Series link navigates to the series index", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Series", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/series/);
    await expect(page.getByRole("heading", { name: "Series", level: 1 })).toBeVisible();
  });

  test("Categories link navigates to the categories index", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Categories", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/categories/);
    await expect(page.getByRole("heading", { name: "Categories", level: 1 })).toBeVisible();
  });

  test("Lists link navigates to the lists index", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Lists", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/lists/);
    await expect(page.getByRole("heading", { name: "Book Lists", level: 1 })).toBeVisible();
  });

  test("Rankings link navigates to the ranking-configurations index", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Rankings", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/ranking_configurations/);
    await expect(page.getByRole("heading", { level: 1 }).first()).toBeVisible();
  });

  test("Penalties link navigates to the global penalties page", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Penalties" }).click();
    await expect(page).toHaveURL(/\/admin\/penalties/);
  });

  test("Users link navigates to the global users page", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Users" }).click();
    await expect(page).toHaveURL(/\/admin\/users/);
  });
});
```

- [ ] **Step 2: Validate it registers**

Run: `yarn playwright test --list e2e/tests/books/admin/sidebar-nav.spec.ts` → 8 tests under `[books-admin]`.

- [ ] **Step 3: Run it (dev server up)**

Run: `yarn test:e2e e2e/tests/books/admin/sidebar-nav.spec.ts`
Expected: 8 passed. If a heading assertion fails on real markup, fix the selector to the actual rendered heading (do not weaken to a bare truthy check). If the dev server is unavailable, note the un-run status.

- [ ] **Step 4: Commit**

```bash
git add e2e/tests/books/admin/sidebar-nav.spec.ts
git commit -m "$(cat <<'EOF'
Add books admin sidebar-nav e2e spec (inc 7)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: CRUD depth for books, authors, series

Add row→show navigation, edit/update, and delete to each — every mutation test creates its own record.

**Files:**
- Modify: `web-app/e2e/tests/books/admin/books.spec.ts`
- Modify: `web-app/e2e/tests/books/admin/authors.spec.ts`
- Modify: `web-app/e2e/tests/books/admin/series.spec.ts`

- [ ] **Step 1: Extend `books.spec.ts`** — append inside the existing `test.describe`:

```ts
  test("clicking a book row navigates to its show page", async ({ page }) => {
    await page.goto("/admin/books");
    await page.locator("table tbody tr").first().getByRole("link").first().click();
    await expect(page.getByText("Basic Information")).toBeVisible();
  });

  test("edits a book's title", async ({ page }) => {
    const title = `E2E Edit Book ${Date.now()}`;
    await page.goto("/admin/books/new");
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Book" }).click();
    await expect(page.getByRole("heading", { name: title })).toBeVisible();

    await page.getByRole("link", { name: "Edit" }).click();
    await expect(page).toHaveURL(/\/edit/);
    const updated = `E2E Updated Book ${Date.now()}`;
    await page.locator('input[name="books_book[title]"]').fill(updated);
    await page.getByRole("button", { name: "Update Book" }).click();
    await expect(page.getByRole("heading", { name: updated })).toBeVisible();
  });

  test("deletes a book", async ({ page }) => {
    const title = `E2E Delete Book ${Date.now()}`;
    await page.goto("/admin/books/new");
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Book" }).click();
    await expect(page.getByRole("heading", { name: title })).toBeVisible();

    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    await expect(page).toHaveURL(/\/admin\/books$/);
  });
```

- [ ] **Step 2: Extend `authors.spec.ts`** — append inside the describe:

```ts
  test("clicking an author row navigates to its show page", async ({ page }) => {
    await page.goto("/admin/authors");
    await page.locator("table tbody tr").first().getByRole("link").first().click();
    await expect(page.getByText("Basic Information")).toBeVisible();
  });

  test("edits an author's name", async ({ page }) => {
    const name = `E2E Edit Author ${Date.now()}`;
    await page.goto("/admin/authors/new");
    await page.locator('input[name="books_author[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Author" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    await page.getByRole("link", { name: "Edit" }).click();
    await expect(page).toHaveURL(/\/edit/);
    const updated = `E2E Updated Author ${Date.now()}`;
    await page.locator('input[name="books_author[name]"]').fill(updated);
    await page.getByRole("button", { name: "Update Author" }).click();
    await expect(page.getByRole("heading", { name: updated, level: 1 })).toBeVisible();
  });

  test("deletes an author", async ({ page }) => {
    const name = `E2E Delete Author ${Date.now()}`;
    await page.goto("/admin/authors/new");
    await page.locator('input[name="books_author[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Author" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    await expect(page).toHaveURL(/\/admin\/authors$/);
  });
```

(`New Author`/`New Series` navigate via the index link in the existing tests; using `/admin/authors/new` directly is equivalent and simpler. If `/new` isn't a direct route for an entity, click the "New X" link from the index instead — verify with `yarn playwright test --list`/the run.)

- [ ] **Step 3: Extend `series.spec.ts`** — append inside the describe (series index heading is "Series"; note the index path helper is `/admin/series`):

```ts
  test("clicking a series row navigates to its show page", async ({ page }) => {
    await page.goto("/admin/series");
    await page.locator("table tbody tr").first().getByRole("link").first().click();
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
  });

  test("edits a series title", async ({ page }) => {
    const title = `E2E Edit Series ${Date.now()}`;
    await page.goto("/admin/series");
    await page.getByRole("link", { name: "New Series" }).click();
    await page.locator('input[name="books_series[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Series" }).click();
    await expect(page.getByRole("heading", { name: title, level: 1 })).toBeVisible();

    await page.getByRole("link", { name: "Edit" }).click();
    await expect(page).toHaveURL(/\/edit/);
    const updated = `E2E Updated Series ${Date.now()}`;
    await page.locator('input[name="books_series[title]"]').fill(updated);
    await page.getByRole("button", { name: "Update Series" }).click();
    await expect(page.getByRole("heading", { name: updated, level: 1 })).toBeVisible();
  });

  test("deletes a series", async ({ page }) => {
    const title = `E2E Delete Series ${Date.now()}`;
    await page.goto("/admin/series");
    await page.getByRole("link", { name: "New Series" }).click();
    await page.locator('input[name="books_series[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Series" }).click();
    await expect(page.getByRole("heading", { name: title, level: 1 })).toBeVisible();

    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    await expect(page).toHaveURL(/\/admin\/series$/);
  });
```

- [ ] **Step 4: Run all three**

Run: `yarn test:e2e e2e/tests/books/admin/books.spec.ts e2e/tests/books/admin/authors.spec.ts e2e/tests/books/admin/series.spec.ts`
Expected: all pass. Fix any selector that fails against real markup (e.g. the row's "View" link — if a table uses a different action label, target the row's title link instead). Do not weaken assertions to force a pass.

- [ ] **Step 5: Commit**

```bash
git add e2e/tests/books/admin/books.spec.ts e2e/tests/books/admin/authors.spec.ts e2e/tests/books/admin/series.spec.ts
git commit -m "$(cat <<'EOF'
Add edit/delete/show-nav e2e coverage for books, authors, series (inc 7)

Each mutation test creates its own record then mutates it — never touches
seeded data.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: CRUD depth for categories and editions

Categories use soft-delete (Delete redirects to the index). Editions are nested under a book — create a book, then an edition, then edit/delete the edition.

**Files:**
- Modify: `web-app/e2e/tests/books/admin/categories.spec.ts`
- Modify: `web-app/e2e/tests/books/admin/editions.spec.ts`

- [ ] **Step 1: Extend `categories.spec.ts`** — append inside the describe:

```ts
  test("edits a category name", async ({ page }) => {
    const name = `E2E Edit Genre ${Date.now()}`;
    await page.goto("/admin/categories");
    await page.getByRole("link", { name: "New Category" }).click();
    await page.locator('input[name="books_category[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Category" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    await page.getByRole("link", { name: "Edit" }).click();
    await expect(page).toHaveURL(/\/edit/);
    const updated = `E2E Updated Genre ${Date.now()}`;
    await page.locator('input[name="books_category[name]"]').fill(updated);
    await page.getByRole("button", { name: "Update Category" }).click();
    await expect(page.getByRole("heading", { name: updated, level: 1 })).toBeVisible();
  });

  test("deletes a category (soft delete)", async ({ page }) => {
    const name = `E2E Delete Genre ${Date.now()}`;
    await page.goto("/admin/categories");
    await page.getByRole("link", { name: "New Category" }).click();
    await page.locator('input[name="books_category[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Category" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    await expect(page).toHaveURL(/\/admin\/categories$/);
  });
```

- [ ] **Step 2: Extend `editions.spec.ts`** — append inside the describe (a helper that creates a book + edition, then edit/delete the edition):

```ts
  test("edits an edition", async ({ page }) => {
    await page.goto("/admin/books/new");
    const title = `E2E Edition-Edit Book ${Date.now()}`;
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Book" }).click();
    await expect(page.getByRole("heading", { name: title })).toBeVisible();

    await page.getByRole("link", { name: "+ New Edition" }).click();
    await expect(page.getByRole("heading", { name: "New Edition" })).toBeVisible();
    await page.locator('input[name="books_edition[publisher_name]"]').fill("E2E Press");
    await page.getByRole("button", { name: "Create Edition" }).click();
    await expect(page.getByText("Edition of")).toBeVisible();

    await page.getByRole("link", { name: "Edit" }).click();
    await expect(page).toHaveURL(/\/edit/);
    await page.locator('input[name="books_edition[publisher_name]"]').fill("E2E Press Revised");
    await page.getByRole("button", { name: "Update Edition" }).click();
    await expect(page.getByText("E2E Press Revised")).toBeVisible();
  });

  test("deletes an edition", async ({ page }) => {
    await page.goto("/admin/books/new");
    const title = `E2E Edition-Delete Book ${Date.now()}`;
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Book" }).click();
    await expect(page.getByRole("heading", { name: title })).toBeVisible();

    await page.getByRole("link", { name: "+ New Edition" }).click();
    await page.locator('input[name="books_edition[publisher_name]"]').fill("E2E Delete Press");
    await page.getByRole("button", { name: "Create Edition" }).click();
    await expect(page.getByText("Edition of")).toBeVisible();

    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    // Delete of an edition redirects to its book's show page.
    await expect(page.getByRole("heading", { name: title })).toBeVisible();
  });
```

(Verify the edition-delete redirect target against the shipped `EditionsController#destroy`; if it redirects to the book show page the heading assertion holds, otherwise adjust to the actual destination — confirm via the run.)

- [ ] **Step 3: Run both**

Run: `yarn test:e2e e2e/tests/books/admin/categories.spec.ts e2e/tests/books/admin/editions.spec.ts`
Expected: all pass. Fix selectors against real markup; do not weaken assertions.

- [ ] **Step 4: Commit**

```bash
git add e2e/tests/books/admin/categories.spec.ts e2e/tests/books/admin/editions.spec.ts
git commit -m "$(cat <<'EOF'
Add edit/delete e2e coverage for categories + editions (inc 7)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: CRUD depth + interactions for lists and ranking-configurations

Lists: edit/delete + penalty attach/detach (via the shared ShowComponent modal, mirroring games' lists-crud). RC: show-details, update, delete.

**Files:**
- Modify: `web-app/e2e/tests/books/admin/lists.spec.ts`
- Modify: `web-app/e2e/tests/books/admin/ranking-configurations.spec.ts`

- [ ] **Step 1: Extend `lists.spec.ts`** — append inside the describe:

```ts
  test("edits a list name", async ({ page }) => {
    const name = `E2E Edit List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    await page.getByRole("link", { name: "Edit" }).click();
    await expect(page).toHaveURL(/\/edit/);
    const updated = `E2E Updated List ${Date.now()}`;
    await page.locator('input[name="books_list[name]"]').fill(updated);
    await page.getByRole("button", { name: "Update Book List" }).click();
    await expect(page.getByRole("heading", { name: updated, level: 1 })).toBeVisible();
  });

  test("deletes a list", async ({ page }) => {
    const name = `E2E Delete List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    await expect(page).toHaveURL(/\/admin\/lists$/);
  });

  test("attaches and detaches a penalty via the modal", async ({ page }) => {
    const name = `E2E Penalty List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    await page.getByRole("button", { name: "+ Attach Penalty" }).click();
    const modal = page.locator("#attach_penalty_modal_dialog");
    await expect(modal).toBeVisible();
    const select = modal.locator('select[name="list_penalty[penalty_id]"]');
    const firstText = await select.locator('option:not([value=""])').first().innerText();
    await select.selectOption({ index: 1 });
    await modal.getByRole("button", { name: "Attach Penalty" }).click();

    const frame = page.locator("turbo-frame#list_penalties_list");
    await expect(frame.getByText(firstText)).toBeVisible({ timeout: 10000 });

    page.on("dialog", (d) => d.accept());
    await frame.getByRole("button", { name: "Delete" }).click();
    await expect(frame.getByText("No penalties attached to this list yet.")).toBeVisible({ timeout: 10000 });
  });
```

(Verify the penalties turbo-frame id (`list_penalties_list`) and the empty-state copy against the shared `Admin::Lists::ShowComponent` / `admin/list_penalties/index`; adjust to the actual id/text if they differ — the games spec uses the same shared partials, so they should match.)

- [ ] **Step 2: Extend `ranking-configurations.spec.ts`** — append inside the describe:

```ts
  test("updates a ranking configuration", async ({ page }) => {
    const name = `E2E Edit RC ${Date.now()}`;
    await page.goto("/admin/ranking_configurations/new");
    await page.locator('input[name="ranking_configuration[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Configuration" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    await page.getByRole("link", { name: "Edit" }).click();
    await expect(page).toHaveURL(/\/edit/);
    const updated = `E2E Updated RC ${Date.now()}`;
    await page.locator('input[name="ranking_configuration[name]"]').fill(updated);
    await page.getByRole("button", { name: "Update Configuration" }).click();
    await expect(page.getByRole("heading", { name: updated, level: 1 })).toBeVisible();
  });

  test("show page displays the refresh/recalculate action buttons", async ({ page }) => {
    const name = `E2E Actions RC ${Date.now()}`;
    await page.goto("/admin/ranking_configurations/new");
    await page.locator('input[name="ranking_configuration[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Configuration" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    await expect(page.getByRole("button", { name: /Refresh Rankings/ })).toBeVisible();
  });

  test("deletes a ranking configuration", async ({ page }) => {
    const name = `E2E Delete RC ${Date.now()}`;
    await page.goto("/admin/ranking_configurations/new");
    await page.locator('input[name="ranking_configuration[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Configuration" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    await expect(page).toHaveURL(/\/admin\/ranking_configurations$/);
  });
```

(Also tighten the existing "creates a ranking configuration" test's submit matcher from `/Create|Save/` to `"Create Configuration"` while here — the exact label is confirmed.)

- [ ] **Step 3: Run both**

Run: `yarn test:e2e e2e/tests/books/admin/lists.spec.ts e2e/tests/books/admin/ranking-configurations.spec.ts`
Expected: all pass. Fix selectors against real markup; do not weaken assertions.

- [ ] **Step 4: Commit**

```bash
git add e2e/tests/books/admin/lists.spec.ts e2e/tests/books/admin/ranking-configurations.spec.ts
git commit -m "$(cat <<'EOF'
Add edit/delete + penalty + RC-depth e2e coverage for lists + ranking-configs (inc 7)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] Run the whole books-admin suite: `yarn test:e2e e2e/tests/books/admin/` — all green (existing + new, ~50 tests).
- [ ] Confirm every edit/update/delete test created its own record (grep the diff for `Date.now()` before each mutation; no test targets a seeded name).
- [ ] `git status` clean; no Ruby changed (so `bin/rails test`/`standardrb` unaffected — optionally run once to confirm the tree is otherwise clean).
- [ ] With inc 7 merged, the 7-increment books admin project (umbrella `2026-07-13-books-admin-ui-design.md`) is complete.

## Notes

- Every mutation test is self-contained (create → mutate own record); the read-only row→show tests navigate existing data without changing it. No test edits or deletes seeded books data.
- If the dev server is down during implementation, each spec still ships code-complete and registered (`yarn playwright test --list`); the owner runs the full suite once the server is up.
- Selector reality-check: the games specs use the same shared partials for lists penalties and RC forms, so those selectors should transfer; verify entity-table row-action labels ("View") against the books `_table` partials and adjust if needed.
