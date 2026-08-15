import { test, expect } from "@playwright/test";

// nightmare-abbey is the scratch book: lib/tasks/e2e.rake excludes it from the
// /my/reviews seed precisely so specs can create and destroy reviews on it.
const SCRATCH_BOOK = "/book/nightmare-abbey";

test.describe("Books admin — reviews", () => {
  test("the list renders newest-first and links into a review", async ({ page }) => {
    await page.goto("/admin/reviews");
    await expect(page.getByRole("heading", { name: "Reviews", level: 1 })).toBeVisible();

    // Date is column 5 (Reviewer, Book, Rating, Review, Date, [Delete]) and
    // renders as an ISO 8601 date, so lexicographic string order is
    // chronological order. Comparing the page's own rows against a
    // descending-sorted copy of themselves proves non-increasing order without
    // needing to create any data -- the dev corpus already has plenty of rows.
    // Scoped to <main> (app/views/layouts/admin.html.erb): rack-mini-profiler
    // injects its own sql-count table straight into <body> in development, and
    // an unscoped tbody selector picks up its cells too.
    const dates = await page.locator("main table tbody tr td:nth-child(5)").allTextContents();
    expect(dates.length).toBeGreaterThan(1);
    expect(dates).toEqual([...dates].sort().reverse());

    const firstReviewLink = page.locator("tbody tr").first().getByRole("link").first();
    await firstReviewLink.click();

    await expect(page).toHaveURL(/\/admin\/reviews\/\d+$/);
    await expect(page.getByRole("link", { name: "← Reviews" })).toBeVisible();
  });

  test.describe("deleting a review", () => {
    // Safety net only -- the happy path deletes through the admin UI itself.
    // A mid-test failure would otherwise strand a review that breaks
    // my-reviews.spec.ts's exact seeded-count assertion on every later run.
    test.afterEach(async ({ page }) => {
      await page.unrouteAll();
      await page.goto("/my/reviews");
      const scratchRow = page.locator("li", { has: page.locator(`a[href="${SCRATCH_BOOK}"]`) });

      while ((await scratchRow.count()) > 0) {
        page.once("dialog", (d) => d.accept());
        await scratchRow.first().getByTestId("delete-review").click();
        await expect(page.locator(`a[href="${SCRATCH_BOOK}"]`)).toHaveCount(0);
      }
    });

    test("an admin reads the full review, then deletes it", async ({ page }) => {
      // Create the review to destroy, through the normal public write flow.
      const body = `E2E admin scratch review ${Date.now()}`;
      await page.goto(SCRATCH_BOOK);
      await page.getByTestId("review-widget-label").click();
      await expect(page.locator("#review_modal")).toBeVisible();
      await page.getByTestId("review-star-button").nth(2).click();
      await page.locator("#review_modal textarea").fill(body);
      await page.getByRole("button", { name: "Save" }).click();
      await expect(page.locator("#review_modal")).not.toBeVisible();

      // Find it in the admin list by its own text, never by position -- the list
      // is newest-first but other specs write reviews too.
      await page.goto("/admin/reviews?q=nightmare");
      const row = page.locator("tbody tr", { hasText: "E2E admin scratch review" }).first();
      await expect(row).toBeVisible();
      await row.getByRole("link").first().click();

      // The detail page shows the whole body, which the list truncates at 80 chars.
      await expect(page).toHaveURL(/\/admin\/reviews\/\d+$/);
      await expect(page.getByTestId("admin-review-body")).toContainText(body);

      page.once("dialog", (d) => {
        expect(d.message()).toContain("permanently");
        d.accept();
      });
      await page.getByRole("button", { name: "Delete" }).click();

      await expect(page).toHaveURL(/\/admin\/reviews$/);
      await expect(
        page.locator("tbody tr", { hasText: "E2E admin scratch review" })
      ).toHaveCount(0);
    });
  });

  // The second Playwright flow the spec promises (docs/superpowers/specs/
  // 2026-08-14-reviews-admin-design.md, Testing section). Purely read-only: it
  // never deletes or mutates a review. The Playwright admin account itself
  // always has reviews -- `bin/rails e2e:my_reviews` idempotently seeds it with
  // 30 -- so this opens the admin's own user record rather than creating or
  // guessing at another user's id. The one thing only a real browser proves
  // here is that the card's link is reachable: Admin::UsersControllerTest only
  // asserts the books host STRING appears in the response body, never that a
  // click on it actually lands on the review.
  test("an admin opens a user with reviews and sees the Reviews card", async ({ page }) => {
    const adminEmail = process.env.PLAYWRIGHT_ADMIN_EMAIL!;

    await page.goto(`/admin/users?q=${encodeURIComponent(adminEmail)}`);
    await page.getByRole("link", { name: adminEmail, exact: true }).first().click();
    await expect(page).toHaveURL(/\/admin\/users\/\d+$/);

    const reviewsCard = page
      .locator(".card")
      .filter({ has: page.getByRole("heading", { name: "Reviews", level: 2 }) });
    await expect(reviewsCard).toBeVisible();

    const rows = reviewsCard.locator("tbody tr");
    await expect(rows.first()).toBeVisible();

    // Follow the first row's link all the way through -- this is the
    // cross-host URL Admin::ReviewsHelper#cross_domain_review_url builds, and
    // it lands here on the same books host only because reviews exist for
    // books alone today (see the design's "Music and games wiring" scope
    // note). Clicking it end to end is still what proves the link resolves at
    // all, which the Minitest suite cannot.
    await rows.first().getByRole("link").click();
    await expect(page).toHaveURL(/\/admin\/reviews\/\d+$/);
    await expect(page.getByRole("link", { name: "← Reviews" })).toBeVisible();
  });
});
