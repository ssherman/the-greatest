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

  test("edits a category name", async ({ page }) => {
    const name = `E2E Edit Genre ${Date.now()}`;
    await page.goto("/admin/categories");
    await page.getByRole("link", { name: "New Category" }).click();
    await page.locator('input[name="books_category[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Category" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    await page.getByRole("link", { name: "Edit" }).click();
    await expect(page).toHaveURL(/\/edit/);
    const updated = `E2E Updated Genre ${Date.now()}`;
    await page.locator('input[name="books_category[name]"]').fill(updated);
    await page.getByRole("button", { name: "Update Category" }).click();
    await expect(page.getByRole("heading", { name: updated, level: 1 })).toBeVisible();
  });

  test("deletes a category (soft delete)", async ({ page }) => {
    const name = `E2E Delete Genre ${Date.now()}`;
    await page.goto("/admin/categories");
    await page.getByRole("link", { name: "New Category" }).click();
    await page.locator('input[name="books_category[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Category" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    await expect(page).toHaveURL(/\/admin\/categories$/);
  });

  test("chooses a parent through the typeahead and the show page links it", async ({ page }) => {
    const parent = `E2E Parent Genre ${Date.now()}`;
    await page.goto("/admin/categories/new");
    await page.locator('input[name="books_category[name]"]').fill(parent);
    await page.getByRole("button", { name: "Create Category" }).click();
    await expect(page.getByRole("heading", { name: parent, level: 1 })).toBeVisible();

    const child = `E2E Child Genre ${Date.now()}`;
    await page.goto("/admin/categories/new");
    await page.locator('input[name="books_category[name]"]').fill(child);
    await page.getByPlaceholder("Search for a parent category...").fill(parent);
    await page.locator("li.cursor-pointer", { hasText: parent }).first().click();
    await expect(page.locator('input[name="books_category[parent_id]"]')).not.toHaveValue("");
    await page.getByRole("button", { name: "Create Category" }).click();

    await expect(page.getByRole("heading", { name: child, level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: parent })).toBeVisible();
  });

  test("merges a category into another and its old URL redirects", async ({ page }) => {
    const name = `E2E Merge Source ${Date.now()}`;
    await page.goto("/admin/categories");
    await page.getByRole("link", { name: "New Category" }).click();
    await page.locator('input[name="books_category[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Category" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    const sourceSlug = new URL(page.url()).pathname.split("/").pop();

    const mergeCard = page.getByTestId("merge-category");
    await mergeCard.getByPlaceholder("Search for the category to keep...").fill("E2E Merge Target");
    await mergeCard.locator("li.cursor-pointer").first().click();
    await mergeCard.getByRole("checkbox").check();
    await mergeCard.getByRole("button", { name: "Merge" }).click();

    await expect(page.getByRole("heading", { name: "E2E Merge Target", level: 1 })).toBeVisible();

    await page.goto(`/the-greatest/${sourceSlug}/books`);
    await expect(page).toHaveURL(/\/the-greatest\/e2e-merge-target\/books/);
  });

  test("an inherited location is labelled 'via' with no Remove, and re-adding succeeds", async ({ page }) => {
    const stamp = Date.now();
    const country = `E2E Country ${stamp}`;
    const city = `E2E City ${stamp}`;

    await page.goto("/admin/categories/new");
    await page.locator('input[name="books_category[name]"]').fill(country);
    await page.locator('select[name="books_category[category_type]"]').selectOption("location");
    await page.getByRole("button", { name: "Create Category" }).click();
    await expect(page.getByRole("heading", { name: country, level: 1 })).toBeVisible();

    await page.goto("/admin/categories/new");
    await page.locator('input[name="books_category[name]"]').fill(city);
    await page.locator('select[name="books_category[category_type]"]').selectOption("location");
    await page.getByPlaceholder("Search for a parent category...").fill(country);
    await page.locator("li.cursor-pointer", { hasText: country }).first().click();
    await page.getByRole("button", { name: "Create Category" }).click();
    await expect(page.getByRole("heading", { name: city, level: 1 })).toBeVisible();

    const bookTitle = `E2E Inherit Book ${stamp}`;
    await page.goto("/admin/books/new");
    await page.locator('input[name="books_book[title]"]').fill(bookTitle);
    await page.getByRole("button", { name: "Create Book" }).click();
    await expect(page.getByRole("heading", { name: bookTitle, level: 1 })).toBeVisible();

    const addCategory = async (name: string) => {
      const categoriesCard = page.locator(".card", { hasText: "Categories" });
      await categoriesCard.getByRole("button", { name: "+ Add" }).click();
      const modal = page.locator("dialog#add_category_modal_dialog");
      await expect(modal).toBeVisible();
      await modal.getByPlaceholder("Search for category...").fill(name);
      await modal.locator("li.cursor-pointer").first().click();
      await modal.getByRole("button", { name: "Add Category" }).click();
    };

    await addCategory(city);

    const list = page.locator("turbo-frame#category_items_list");
    const cityRow = list.locator("tr", { hasText: city });
    const countryRow = list.locator("tr", { hasText: country });
    await expect(cityRow.getByRole("button", { name: "Remove" })).toBeVisible();
    await expect(countryRow).toContainText(`via ${city}`);
    await expect(countryRow.getByRole("button", { name: "Remove" })).toHaveCount(0);

    // Tagging the inherited country directly upgrades it; tagging it again is a success.
    await addCategory(country);
    await expect(countryRow.getByRole("button", { name: "Remove" })).toBeVisible();
    await addCategory(country);
    await expect(page.getByText("Category added successfully")).toBeVisible();
    await expect(list.locator("tr", { hasText: country })).toHaveCount(1);
  });
});
