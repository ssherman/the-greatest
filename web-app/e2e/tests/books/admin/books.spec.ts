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

  test("edits alternate titles one per input and keeps a comma title whole", async ({ page }) => {
    const title = `E2E Alt Titles Book ${Date.now()}`;
    const alt = "Good Night, Mr. Tom";
    await page.goto("/admin/books/new");
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Book" }).click();
    await expect(page.getByRole("heading", { name: title })).toBeVisible();

    await page.getByRole("link", { name: "Edit", exact: true }).click();
    await page.getByRole("button", { name: "Add alternate title" }).click();
    await page.locator('input[type="text"][name="books_book[alternate_titles][]"]').fill(alt);
    await page.getByRole("button", { name: "Update Book" }).click();
    const line = page.locator("dd", { hasText: alt });
    await expect(line).toHaveText(alt);

    await page.getByRole("link", { name: "Edit", exact: true }).click();
    await expect(page.locator('input[type="text"][name="books_book[alternate_titles][]"]')).toHaveValue(alt);
    await page.getByRole("button", { name: "Remove" }).click();
    await page.getByRole("button", { name: "Update Book" }).click();
    await expect(page.getByText("Basic Information")).toBeVisible();
    await expect(page.getByText(alt)).toHaveCount(0);
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

  test("shows the Enrichment runs card", async ({ page }) => {
    const title = `E2E Runs Book ${Date.now()}`;
    await page.goto("/admin/books/new");
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Book" }).click();
    await expect(page.getByRole("heading", { name: title })).toBeVisible();

    // The card's frame loads lazily, once it scrolls into view.
    const heading = page.getByRole("heading", { name: "Enrichment runs" });
    await heading.scrollIntoViewIfNeeded();
    await expect(heading).toBeVisible();
    // A new book has no runs, or its runs show as a table.
    await expect(page.getByText("No enrichment runs.").or(page.getByRole("table").filter({ hasText: "Outcome" }))).toBeVisible();
  });

  test("shows the Identifiers card", async ({ page }) => {
    const title = `E2E Identifiers Book ${Date.now()}`;
    await page.goto("/admin/books/new");
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Book" }).click();
    await expect(page.getByRole("heading", { name: title })).toBeVisible();

    // The card's frame loads lazily, once it scrolls into view. A new book has none.
    const heading = page.getByRole("heading", { name: /^Identifiers/ });
    await heading.scrollIntoViewIfNeeded();
    await expect(heading).toBeVisible();
    await expect(page.getByText("No identifiers.")).toBeVisible();
  });

  test("lists an existing book's identifiers in a table", async ({ page }) => {
    await page.goto("/admin/books");
    await page.locator("table tbody tr").first().getByRole("link").first().click();
    await expect(page.getByText("Basic Information")).toBeVisible();

    const heading = page.getByRole("heading", { name: /^Identifiers/ });
    await heading.scrollIntoViewIfNeeded();
    // Seeded books may or may not hold identifiers; either way the frame must fill.
    await expect(page.getByText("No identifiers.").or(page.getByRole("table").filter({ hasText: "Source" }))).toBeVisible();
  });
});
