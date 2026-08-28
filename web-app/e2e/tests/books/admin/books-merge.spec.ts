import { test, expect } from "@playwright/test";

// Deliberately does NOT perform a real merge. E2E runs against the development
// database, whose books data is irreversible and takes hours to rebuild, and a
// merge destroys a row with no undo. These drive the modal up to but not past
// submission, exactly as authors-merge.spec.ts does.
test.describe("Books admin — book merge", () => {
  test("merge button opens the modal on a book show page", async ({ page }) => {
    await page.goto("/admin/books");
    await page.getByRole("link", { name: "View" }).first().click();
    await page.waitForURL(/\/admin\/books\/[^/]+$/);

    await page.getByTestId("merge-book-button").click();

    await expect(page.getByRole("heading", { name: "Merge Another Book Into This One" }))
      .toBeVisible();
    await expect(page.getByRole("button", { name: "Merge Book" })).toBeVisible();
  });

  test("merge requires the confirmation checkbox", async ({ page }) => {
    await page.goto("/admin/books");
    await page.getByRole("link", { name: "View" }).first().click();
    await page.waitForURL(/\/admin\/books\/[^/]+$/);

    await page.getByTestId("merge-book-button").click();
    await page.getByRole("button", { name: "Merge Book" }).click();

    // The checkbox is `required`, so the browser blocks submission and the modal stays open.
    await expect(page.getByRole("heading", { name: "Merge Another Book Into This One" }))
      .toBeVisible();
  });
});
