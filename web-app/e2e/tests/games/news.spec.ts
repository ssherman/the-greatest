import { test, expect, type Page } from "@playwright/test";

// The games and music projects both run authenticated (storageState in
// e2e/playwright.config.ts), so this public spec can create the post it needs
// through the admin UI rather than depending on seeded content. That matters:
// development has ZERO games news posts, so the plan's `test.skip(count === 0)`
// guard would have made every assertion here skip -- coverage that reads as
// green while testing nothing.
//
// The development database is not disposable (CLAUDE.md), so everything created
// is deleted again through the admin UI, with an afterEach sweep as the safety
// net for a test that fails before its own cleanup. Both mirror
// e2e/tests/books/admin/news.spec.ts, including the "main table tbody tr"
// scoping that keeps rack-mini-profiler's injected markup out of row locators.
const E2E_PREFIX = "E2E Games News";

async function createPublishedPost(page: Page, title: string) {
  await page.goto("/admin/news_posts/new");
  await page.locator('input[name="news_post[title]"]').fill(title);
  await page.locator('textarea[name="news_post[body]"]').fill(
    "A **bold** claim from the games E2E spec."
  );
  // Without a publish date the post is a draft and never reaches /news.
  await page.locator('input[name="news_post[published_at]"]').fill("2026-01-01T09:00");
  await page.getByRole("button", { name: "Create Post" }).click();
  await expect(page).toHaveURL(/\/admin\/news_posts\/[a-z0-9-]+$/);
}

async function sweepByPrefix(page: Page, indexPath: string, prefix: string, maxIterations = 20) {
  await page.goto(indexPath);
  const rows = page.locator("main table tbody tr", { hasText: prefix });
  for (let i = 0; i < maxIterations; i++) {
    const before = await rows.count();
    if (before === 0) return;
    page.once("dialog", (dialog) => dialog.accept());
    await rows.first().getByRole("button", { name: "Delete" }).click();
    await expect(rows).toHaveCount(before - 1);
  }
  throw new Error(
    `sweepByPrefix: rows matching "${prefix}" at ${indexPath} were not fully cleared after ${maxIterations} attempts`
  );
}

test.describe("Games news", () => {
  test.afterEach(async ({ page }) => {
    await sweepByPrefix(page, "/admin/news_posts", E2E_PREFIX);
  });

  test("the index loads and renders the heading", async ({ page }) => {
    const response = await page.goto("/news");

    expect(response?.status()).toBe(200);
    await expect(page.getByRole("heading", { name: "News", level: 1 })).toBeVisible();
  });

  test("a published post appears on the index and links through to its page", async ({ page }) => {
    const title = `${E2E_PREFIX} ${Date.now()}`;
    await createPublishedPost(page, title);

    await page.goto("/news");
    const link = page.locator("article h2 a", { hasText: title });
    await expect(link).toBeVisible();
    await link.click();

    await expect(page).toHaveURL(/\/news\/[a-z0-9-]+$/);
    await expect(page.getByRole("heading", { name: title, level: 1 })).toBeVisible();
  });

  test("a post page renders formatted body text and Open Graph tags", async ({ page }) => {
    const title = `${E2E_PREFIX} ${Date.now()}`;
    await createPublishedPost(page, title);

    await page.goto("/news");
    await page.locator("article h2 a", { hasText: title }).click();

    // Rendered through BodyRenderer, so it is real markup: the <strong> exists
    // and the Markdown asterisks are gone. Asserting only "not ** " would pass
    // against a page that rendered no body at all.
    await expect(page.locator(".prose strong")).toHaveText("bold");
    await expect(page.locator(".prose")).not.toContainText("**");

    await expect(page.locator('meta[property="og:type"]')).toHaveAttribute("content", "article");
    await expect(page.locator('meta[property="og:title"]')).toHaveAttribute("content", title);
  });

  test("the index advertises its feed and the feed serves this site", async ({ page }) => {
    const title = `${E2E_PREFIX} ${Date.now()}`;
    await createPublishedPost(page, title);

    await page.goto("/news");
    await expect(page.locator('link[rel="alternate"][type="application/rss+xml"]')).toHaveAttribute(
      "href",
      "https://dev.thegreatest.games/news.rss"
    );

    const response = await page.goto("/news.rss");
    expect(response?.status()).toBe(200);
    expect(await response?.text()).toContain(title);
  });
});
