import { test, expect } from "@playwright/test";

test.describe("Books admin — lists", () => {
  test("lists index and links to New List", async ({ page }) => {
    await page.goto("/admin/lists");
    await expect(page.getByRole("heading", { name: "Book Lists", level: 1 })).toBeVisible();
  });

  test("creates a list and shows it without a wizard button", async ({ page }) => {
    const name = `E2E List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: "Launch Wizard" })).toHaveCount(0);
  });
});
