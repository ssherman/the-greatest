import { test, expect } from "@playwright/test";

test.describe("Books admin — categories", () => {
  test("lists categories and links to New Category", async ({ page }) => {
    await page.goto("/admin/categories");
    await expect(page.getByRole("heading", { name: "Categories", level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: "New Category" })).toBeVisible();
  });

  test("creates a category and shows it", async ({ page }) => {
    const name = `Test Genre ${Date.now()}`;
    await page.goto("/admin/categories");
    await page.getByRole("link", { name: "New Category" }).click();

    await page.locator('input[name="books_category[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Category" }).click();

    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
  });

  test("tags a book with a category via the typeahead", async ({ page }) => {
    const name = `Tag Genre ${Date.now()}`;
    await page.goto("/admin/categories");
    await page.getByRole("link", { name: "New Category" }).click();
    await page.locator('input[name="books_category[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Category" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    const bookTitle = `Tag Book ${Date.now()}`;
    await page.goto("/admin/books/new");
    await page.locator('input[name="books_book[title]"]').fill(bookTitle);
    await page.getByRole("button", { name: "Create Book" }).click();
    await expect(page.getByRole("heading", { name: bookTitle, level: 1 })).toBeVisible();

    const categoriesCard = page.locator(".card", { hasText: "Categories" });
    await categoriesCard.getByRole("button", { name: "+ Add" }).click();

    const modal = page.locator("dialog#add_category_modal_dialog");
    await expect(modal).toBeVisible();
    await modal.getByPlaceholder("Search for category...").fill(name);
    await modal.locator("li.cursor-pointer").first().click();
    await modal.getByRole("button", { name: "Add Category" }).click();

    await expect(
      page.locator("turbo-frame#category_items_list").getByText(name, { exact: false })
    ).toBeVisible();
  });
});
