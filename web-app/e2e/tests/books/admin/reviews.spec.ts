import { test, expect } from "@playwright/test";

// nightmare-abbey is the scratch book: lib/tasks/e2e.rake excludes it from the
// /my/reviews seed precisely so specs can create and destroy reviews on it.
const SCRATCH_BOOK = "/book/nightmare-abbey";

test.describe("Books admin — reviews", () => {
  test("the list renders newest-first and links into a review", async ({ page }) => {
    await page.goto("/admin/reviews");
    await expect(page.getByRole("heading", { name: "Reviews", level: 1 })).toBeVisible();

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
});
