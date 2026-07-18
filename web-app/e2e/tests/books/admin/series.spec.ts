import { test, expect } from "@playwright/test";

test.describe("Books admin — series", () => {
  test("lists series and links to New Series", async ({ page }) => {
    await page.goto("/admin/series");
    await expect(page.getByRole("heading", { name: "Series", level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: "New Series" })).toBeVisible();
  });

  test("creates a series and shows it", async ({ page }) => {
    const title = `Test Series ${Date.now()}`;
    await page.goto("/admin/series");
    await page.getByRole("link", { name: "New Series" }).click();

    await page.locator('input[name="books_series[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Series" }).click();

    await expect(page.getByRole("heading", { name: title, level: 1 })).toBeVisible();
  });

  test("adds a book to the series and makes it representative", async ({ page }) => {
    const title = `Rep Series ${Date.now()}`;
    await page.goto("/admin/series");
    await page.getByRole("link", { name: "New Series" }).click();
    await page.locator('input[name="books_series[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Series" }).click();
    await expect(page.getByRole("heading", { name: title, level: 1 })).toBeVisible();

    // Add a book via the typeahead
    await page.getByRole("button", { name: "+ Add" }).last().click();
    const modal = page.locator("dialog#add_series_book_modal");
    await expect(modal).toBeVisible();
    await modal.getByPlaceholder("Search for a book…").fill("War and Peace");
    await modal.locator("li.cursor-pointer").first().click();
    await modal.getByRole("button", { name: "Add Book" }).click();

    const frame = page.locator("turbo-frame#series_books_list");
    await expect(frame.getByText("War and Peace", { exact: false })).toBeVisible();

    // Make it representative
    await frame.getByRole("button", { name: "★ Make representative" }).click();
    await expect(frame.getByText("★ Representative")).toBeVisible();
  });
});
