import { test, expect } from "@playwright/test";

test.describe("Books admin — authors", () => {
  test("lists authors and links to New Author", async ({ page }) => {
    await page.goto("/admin/authors");
    await expect(page.getByRole("heading", { name: "Authors", level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: "New Author" })).toBeVisible();
  });

  test("creates an author and shows it", async ({ page }) => {
    const name = `Test Author ${Date.now()}`;
    await page.goto("/admin/authors");
    await page.getByRole("link", { name: "New Author" }).click();

    await page.locator('input[name="books_author[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Author" }).click();

    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
  });

  test("adds a relationship via the author typeahead", async ({ page }) => {
    const name = `Rel Author ${Date.now()}`;
    await page.goto("/admin/authors");
    await page.getByRole("link", { name: "New Author" }).click();
    await page.locator('input[name="books_author[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Author" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    await page.getByRole("button", { name: "+ Add" }).last().click();
    const modal = page.locator("dialog#add_author_relationship_modal");
    await expect(modal).toBeVisible();

    await modal.getByPlaceholder("Search for an author…").fill("Tolstoy");
    await modal.locator("li.cursor-pointer").first().click();
    await modal.getByRole("button", { name: "Add Relationship" }).click();

    await expect(
      page.locator("turbo-frame#author_relationships_list").getByText("Tolstoy", { exact: false })
    ).toBeVisible();
  });
});
