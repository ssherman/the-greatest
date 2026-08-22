import { test, expect, type Page } from "@playwright/test";

// news_posts and news_topics are new tables introduced on this branch, not
// part of the legacy-migrated books corpus -- but the dev database is still
// not disposable (see CLAUDE.md), so every post and topic these specs create
// is deleted again through the admin UI itself before the test ends, rather
// than just given a unique name and left behind. That keeps repeated local
// runs of this file from growing the news tables indefinitely, and the
// deletions double as extra coverage of the delete flow beyond the one test
// dedicated to it.
//
// The live Markdown preview test is the one exception: it drives the `new`
// post form's body field directly and never submits, so it creates nothing to
// clean up.
//
// Every table-row locator below is scoped to "main table tbody tr", never a
// bare "tbody tr" -- same hazard reviews.spec.ts already documents:
// rack-mini-profiler (Gemfile, development only) injects its own markup
// straight into <body>, outside <main>, and an unscoped tbody selector can
// match its rows too. This was a real, reproducible flake here (not a
// timing issue): after a topic's row was gone and "Topic deleted." had
// rendered, an unscoped locator for the deleted row's own name still
// resolved to 1 element -- mini-profiler's own panel can carry the literal
// SQL text of the query that just ran, which contains the deleted row's
// name.
//
// Every name this file creates starts with E2E_PREFIX. The inline deletes
// below are the happy path; the test.afterEach sweep at the bottom is the
// safety net for when an assertion fails before a test reaches its own
// cleanup -- mirroring reviews.spec.ts's afterEach, the closest precedent
// named in the brief.
const E2E_PREFIX = "E2E News";

async function createTopic(page: Page, name: string) {
  await page.goto("/admin/news_topics/new");
  await page.locator('input[name="news_topic[name]"]').fill(name);
  await page.getByRole("button", { name: "Create Topic" }).click();
  await expect(page).toHaveURL(/\/admin\/news_topics$/);
}

async function deleteTopic(page: Page, name: string) {
  await page.goto("/admin/news_topics");
  const row = page.locator("main table tbody tr", { hasText: name });
  await expect(row).toBeVisible();
  page.once("dialog", (dialog) => dialog.accept());
  await row.getByRole("button", { name: "Delete" }).click();

  // Synchronizes on the flash notice before checking the row is gone, as a
  // clear checkpoint that the redirect + re-render actually completed.
  await expect(page.locator("#flash")).toContainText("Topic deleted.");
  await expect(page.locator("main table tbody tr", { hasText: name })).toHaveCount(0);
}

// Deletes the post whose show page is currently on screen.
async function deletePostFromShowPage(page: Page) {
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByRole("button", { name: "Delete" }).click();
  await expect(page).toHaveURL(/\/admin\/news_posts$/);
}

// Safety-net sweep: deletes every row at indexPath whose text contains
// prefix, through the admin UI itself. Used from test.afterEach so a test
// that fails before reaching its own inline delete cannot strand a row in
// the (not disposable) development database. Bounded so a stuck delete
// surfaces as a thrown error instead of hanging the run.
async function sweepByPrefix(page: Page, indexPath: string, prefix: string, maxIterations = 20) {
  await page.goto(indexPath);
  for (let i = 0; i < maxIterations; i++) {
    const row = page.locator("main table tbody tr", { hasText: prefix }).first();
    if ((await row.count()) === 0) return;
    page.once("dialog", (dialog) => dialog.accept());
    await row.getByRole("button", { name: "Delete" }).click();
    await expect(page).toHaveURL(new RegExp(`${indexPath}$`));
  }
  throw new Error(
    `sweepByPrefix: rows matching "${prefix}" at ${indexPath} were not fully cleared after ${maxIterations} attempts`
  );
}

test.describe("Books admin — news", () => {
  test.afterEach(async ({ page }) => {
    await sweepByPrefix(page, "/admin/news_posts", E2E_PREFIX);
    await sweepByPrefix(page, "/admin/news_topics", E2E_PREFIX);
  });

  test.describe("sidebar navigation", () => {
    const sidebar = (page: Page) => page.getByTestId("admin-sidebar");

    test("News link navigates to the news posts index", async ({ page }) => {
      await page.goto("/admin");
      await sidebar(page).getByRole("link", { name: "News", exact: true }).click();
      await expect(page).toHaveURL(/\/admin\/news_posts/);
      await expect(page.getByRole("heading", { name: "News", level: 1 })).toBeVisible();
    });

    test("News Topics link navigates to the news topics index", async ({ page }) => {
      await page.goto("/admin");
      await sidebar(page).getByRole("link", { name: "News Topics", exact: true }).click();
      await expect(page).toHaveURL(/\/admin\/news_topics/);
      await expect(page.getByRole("heading", { name: "News Topics", level: 1 })).toBeVisible();
    });
  });

  test("creates a topic, sees it listed, then deletes it", async ({ page }) => {
    const name = `${E2E_PREFIX} Topic ${Date.now()}`;
    await createTopic(page, name);

    const row = page.locator("main table tbody tr", { hasText: name });
    await expect(row).toBeVisible();

    await deleteTopic(page, name);
  });

  test("creates a post with a topic and sees it on the index", async ({ page }) => {
    const topicName = `${E2E_PREFIX} Topic ${Date.now()}`;
    const title = `${E2E_PREFIX} Post ${Date.now()}`;
    await createTopic(page, topicName);

    await page.goto("/admin/news_posts/new");
    await page.locator('input[name="news_post[title]"]').fill(title);
    await page.locator('textarea[name="news_post[body]"]').fill("Body for the E2E create-post spec.");
    await page.getByRole("checkbox", { name: topicName, exact: true }).check();
    await page.getByRole("button", { name: "Create Post" }).click();

    await expect(page).toHaveURL(/\/admin\/news_posts\/[^/]+$/);
    await expect(page.getByRole("heading", { name: title, level: 1 })).toBeVisible();

    await page.goto("/admin/news_posts");
    const row = page.locator("main table tbody tr", { hasText: title });
    await expect(row).toBeVisible();
    await expect(row.getByText(topicName)).toBeVisible();

    await row.getByRole("link", { name: title }).click();
    await expect(page).toHaveURL(/\/admin\/news_posts\/[^/]+$/);
    await deletePostFromShowPage(page);
    await deleteTopic(page, topicName);
  });

  test("the live Markdown preview renders typed Markdown", async ({ page }) => {
    // Drives the `new` form directly and never submits -- nothing is created,
    // so there is nothing to clean up here. This is the single highest-value
    // assertion in the file: the only automated check anywhere that the
    // Stimulus controller, its debounce, the turbo-stream response and
    // Services::News::BodyRenderer are all wired to each other.
    await page.goto("/admin/news_posts/new");
    const body = page.locator('textarea[name="news_post[body]"]');
    const preview = page.locator("#news_post_preview");

    await body.fill("# E2E Preview Heading\n\nSome **bold** text.");

    // Debounced 400ms, then a turbo-stream round trip -- assert on the
    // eventual state with Playwright's auto-retrying assertions rather than a
    // fixed sleep. BodyRenderer shifts h1 -> h2, since the post title is
    // already the page's own h1.
    await expect(preview.locator("h2", { hasText: "E2E Preview Heading" })).toBeVisible();
    await expect(preview.locator("strong", { hasText: "bold" })).toBeVisible();
  });

  test("editing a post persists the change", async ({ page }) => {
    const title = `${E2E_PREFIX} Post ${Date.now()}`;
    await page.goto("/admin/news_posts/new");
    await page.locator('input[name="news_post[title]"]').fill(title);
    await page.locator('textarea[name="news_post[body]"]').fill("Original body.");
    await page.getByRole("button", { name: "Create Post" }).click();
    await expect(page.getByRole("heading", { name: title, level: 1 })).toBeVisible();

    await page.getByRole("link", { name: "Edit" }).click();
    await expect(page).toHaveURL(/\/edit$/);

    const updatedTitle = `${title} Updated`;
    await page.locator('input[name="news_post[title]"]').fill(updatedTitle);
    await page.locator('textarea[name="news_post[body]"]').fill("Updated body content.");
    await page.getByRole("button", { name: "Save Post" }).click();

    await expect(page).toHaveURL(/\/admin\/news_posts\/[^/]+$/);
    await expect(page.getByRole("heading", { name: updatedTitle, level: 1 })).toBeVisible();
    await expect(page.getByText("Updated body content.")).toBeVisible();

    // Reload to prove the change is persisted server-side, not just reflected
    // in the page Turbo already had in memory.
    await page.reload();
    await expect(page.getByRole("heading", { name: updatedTitle, level: 1 })).toBeVisible();

    await deletePostFromShowPage(page);
  });

  test("deletes a post through the delete control, including the confirmation dialog", async ({ page }) => {
    const title = `${E2E_PREFIX} Post ${Date.now()}`;
    await page.goto("/admin/news_posts/new");
    await page.locator('input[name="news_post[title]"]').fill(title);
    await page.locator('textarea[name="news_post[body]"]').fill("Body to be deleted.");
    await page.getByRole("button", { name: "Create Post" }).click();
    await expect(page.getByRole("heading", { name: title, level: 1 })).toBeVisible();

    page.once("dialog", (dialog) => {
      expect(dialog.message()).toContain(title);
      expect(dialog.message()).toContain("cannot be undone");
      dialog.accept();
    });
    await page.getByRole("button", { name: "Delete" }).click();

    await expect(page).toHaveURL(/\/admin\/news_posts$/);
    await expect(page.locator("main table tbody tr", { hasText: title })).toHaveCount(0);
  });

  test("a draft post is visible in the admin list and marked as a draft in words", async ({ page }) => {
    const title = `${E2E_PREFIX} Draft ${Date.now()}`;
    await page.goto("/admin/news_posts/new");
    await page.locator('input[name="news_post[title]"]').fill(title);
    await page.locator('textarea[name="news_post[body]"]').fill("Draft body, no publish date set.");
    // published_at is left blank -- that is what makes this a draft.
    await page.getByRole("button", { name: "Create Post" }).click();
    await expect(page.getByRole("heading", { name: title, level: 1 })).toBeVisible();

    // Status is stated in words, never colour alone (the owner is red-green
    // colour blind) -- assert on the exact text "Draft", not a badge class.
    // exact: true matters here: Playwright's default hasText/getByText
    // substring matching is case-INsensitive, and the post's own slug
    // ("e2e-news-draft-...") would otherwise satisfy a loose "Draft" match.
    await expect(page.getByText("Draft", { exact: true })).toBeVisible();

    await page.goto("/admin/news_posts");
    const row = page.locator("main table tbody tr", { hasText: title });
    await expect(row).toBeVisible();
    await expect(row.getByText("Draft", { exact: true })).toBeVisible();

    await row.getByRole("link", { name: title }).click();
    await expect(page).toHaveURL(/\/admin\/news_posts\/[^/]+$/);
    await deletePostFromShowPage(page);
  });

  test.describe("body image copy button", () => {
    test("copies the uploaded image's Markdown snippet to the clipboard", async ({ page, context }) => {
      await context.grantPermissions(["clipboard-read", "clipboard-write"]);

      const title = `${E2E_PREFIX} Post Image ${Date.now()}`;
      // A minimal 1x1 PNG, inline -- no fixture file needed.
      const png = Buffer.from(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
        "base64"
      );

      await page.goto("/admin/news_posts/new");
      await page.locator('input[name="news_post[title]"]').fill(title);
      await page.locator('textarea[name="news_post[body]"]').fill("Body with an uploaded image.");
      await page.locator('input[name="news_post[body_images][]"]').setInputFiles({
        name: "e2e-body-image.png",
        mimeType: "image/png",
        buffer: png,
      });
      await page.getByRole("button", { name: "Create Post" }).click();
      await expect(page.getByRole("heading", { name: title, level: 1 })).toBeVisible();

      // The body-image preview and its Copy button render only for a
      // PERSISTED image, so it never appears on `new` -- it needs the edit
      // page of the post just created.
      await page.getByRole("link", { name: "Edit" }).click();
      await expect(page).toHaveURL(/\/edit$/);
      const editUrl = page.url();

      // This is the exact defect that shipped and was caught only by code
      // review: the Copy button was wired to a data attribute the
      // clipboard-copy Stimulus controller never reads, so clicking it
      // silently copied nothing, and no test failed. Comparing the
      // clipboard's contents against the snippet's own displayed text --
      // rather than hardcoding the expected Markdown -- proves the button
      // actually reads what is on screen instead of passing vacuously.
      const snippet = page.locator('code[data-clipboard-copy-target="source"]');
      await expect(snippet).toBeVisible();
      const expectedText = (await snippet.textContent())?.trim();
      expect(expectedText).toBeTruthy();

      await page.getByRole("button", { name: "Copy" }).click();
      await expect(page.getByRole("button", { name: "Copied!" })).toBeVisible();

      const clipboardText = await page.evaluate(() => navigator.clipboard.readText());
      expect(clipboardText).toBe(expectedText);

      await page.goto(editUrl.replace(/\/edit$/, ""));
      await deletePostFromShowPage(page);
    });
  });
});
