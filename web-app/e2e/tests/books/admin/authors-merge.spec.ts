import { test, expect } from "@playwright/test";

// Deliberately does NOT perform a real merge. E2E runs against the development
// database, whose books data is irreversible and takes hours to rebuild, and a
// merge destroys a row with no undo. These drive the modal up to but not past
// submission, exactly as games-merge.spec.ts does.
test.describe("Books admin — author merge", () => {
  test("merge button opens the modal on an author show page", async ({ page }) => {
    await page.goto("/admin/authors");
    await page.getByRole("link", { name: "View" }).first().click();
    await page.waitForURL(/\/admin\/authors\/[^/]+$/);

    await page.getByTestId("merge-author-button").click();

    await expect(page.getByRole("heading", { name: "Merge Another Author Into This One" }))
      .toBeVisible();
    await expect(page.getByRole("button", { name: "Merge Author" })).toBeVisible();
  });

  test("merge requires the confirmation checkbox", async ({ page }) => {
    await page.goto("/admin/authors");
    await page.getByRole("link", { name: "View" }).first().click();
    await page.waitForURL(/\/admin\/authors\/[^/]+$/);

    await page.getByTestId("merge-author-button").click();
    await page.getByRole("button", { name: "Merge Author" }).click();

    // The checkbox is `required`, so the browser blocks submission and the modal stays open.
    await expect(page.getByRole("heading", { name: "Merge Another Author Into This One" }))
      .toBeVisible();
  });
});
