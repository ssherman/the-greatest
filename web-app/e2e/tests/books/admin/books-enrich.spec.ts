import { test, expect } from "@playwright/test";

// Drives the modal up to but not past submission: submitting would enqueue a
// real AI job against the development database and spend money.
test.describe("Books admin — enrich with AI", () => {
  test("the enrich button opens the modal on a book show page", async ({ page }) => {
    await page.goto("/admin/books");
    await page.getByRole("link", { name: "View" }).first().click();
    await page.waitForURL(/\/admin\/books\/[^/]+$/);

    await page.getByTestId("enrich-book-button").click();

    await expect(page.getByRole("heading", { name: "Enrich With AI" })).toBeVisible();
    await expect(page.getByRole("checkbox", { name: /Search the web/ })).not.toBeChecked();
    await expect(page.getByRole("button", { name: "Enrich Book" })).toBeVisible();
  });

  test("cancel closes the modal without submitting", async ({ page }) => {
    await page.goto("/admin/books");
    await page.getByRole("link", { name: "View" }).first().click();
    await page.waitForURL(/\/admin\/books\/[^/]+$/);

    await page.getByTestId("enrich-book-button").click();
    await page.getByRole("button", { name: "Cancel" }).click();

    await expect(page.getByRole("heading", { name: "Enrich With AI" })).not.toBeVisible();
  });
});
