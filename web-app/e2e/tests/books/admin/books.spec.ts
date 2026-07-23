import { test, expect } from '@playwright/test';

test.describe('books admin — books', () => {
  test('index lists books and links to a show page', async ({ page }) => {
    await page.goto('/admin/books');
    await expect(page.getByRole('heading', { name: 'Books', exact: true })).toBeVisible();
    await expect(page.getByRole('link', { name: 'New Book' })).toBeVisible();
  });

  test('create a book and land on its show page', async ({ page }) => {
    await page.goto('/admin/books/new');
    const title = `E2E Smoke Book ${Date.now()}`;
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole('button', { name: 'Create Book' }).click();
    await expect(page.getByRole('heading', { name: title })).toBeVisible();
    await expect(page.getByText('Basic Information')).toBeVisible();
  });

  test("clicking a book row navigates to its show page", async ({ page }) => {
    await page.goto("/admin/books");
    await page.locator("table tbody tr").first().getByRole("link").first().click();
    await expect(page.getByText("Basic Information")).toBeVisible();
  });

  test("edits a book's title", async ({ page }) => {
    const title = `E2E Edit Book ${Date.now()}`;
    await page.goto("/admin/books/new");
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Book" }).click();
    await expect(page.getByRole("heading", { name: title })).toBeVisible();

    await page.getByRole("link", { name: "Edit", exact: true }).click();
    await expect(page).toHaveURL(/\/edit/);
    const updated = `E2E Updated Book ${Date.now()}`;
    await page.locator('input[name="books_book[title]"]').fill(updated);
    await page.getByRole("button", { name: "Update Book" }).click();
    await expect(page.getByRole("heading", { name: updated })).toBeVisible();
  });

  test("deletes a book", async ({ page }) => {
    const title = `E2E Delete Book ${Date.now()}`;
    await page.goto("/admin/books/new");
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Book" }).click();
    await expect(page.getByRole("heading", { name: title })).toBeVisible();

    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    await expect(page).toHaveURL(/\/admin\/books$/);
  });
});
