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
    // Basic Information is also on the edit form, so wait for the show page itself.
    await expect(page).not.toHaveURL(/\/edit/);
    await expect(page.getByText("Book updated.")).toBeVisible();
    await expect(page.locator("dt", { hasText: "Alternate Titles" }).locator("xpath=following-sibling::dd")).toHaveText("—");
    await expect(page.getByText(alt)).toHaveCount(0);
  });

  test("alternate titles card removes and restores a title, and the review page loads", async ({ page }) => {
    const title = `E2E Alt Card Book ${Date.now()}`;
    const alt = `E2E Alt Card Title ${Date.now()}`;
    await page.goto("/admin/books/new");
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Book" }).click();
    await expect(page.getByRole("heading", { name: title })).toBeVisible();

    await page.getByRole("link", { name: "Edit", exact: true }).click();
    await page.getByRole("button", { name: "Add alternate title" }).click();
    await page.locator('input[type="text"][name="books_book[alternate_titles][]"]').fill(alt);
    await page.getByRole("button", { name: "Update Book" }).click();
    await expect(page).not.toHaveURL(/\/edit/);
    await expect(page.getByText("Book updated.")).toBeVisible();

    // The card is a lazy frame: it loads once scrolled into view.
    await page.locator("#alternate_titles_list").scrollIntoViewIfNeeded();
    const row = page.locator('[data-testid="alternate-title-row"]', { hasText: alt });
    await expect(row).toBeVisible();
    await expect(row).toHaveAttribute("data-status", "kept");

    await row.getByRole("button", { name: "Remove" }).click();
    // The redirect reloads the page and the lazy card with it.
    await expect(page.getByText("Alternate title removed.")).toBeVisible();
    await page.locator("#alternate_titles_list").scrollIntoViewIfNeeded();
    await expect(row).toHaveAttribute("data-status", "removed");

    await row.getByRole("button", { name: "Restore" }).click();
    await expect(page.getByText("Alternate title kept.")).toBeVisible();
    await page.locator("#alternate_titles_list").scrollIntoViewIfNeeded();
    await expect(row).toHaveAttribute("data-status", "kept");

    await page.goto("/admin/alternate_titles/review");
    await expect(page.getByRole("heading", { name: "Alternate titles to review" })).toBeVisible();
    await expect(page.getByLabel("Source")).toBeVisible();
  });

  test("copies a deep-research prompt for an alternate title", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    const title = `E2E Alt Prompt Book ${Date.now()}`;
    const alt = `E2E Alt Prompt Title ${Date.now()}`;
    await page.goto("/admin/books/new");
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Book" }).click();
    await expect(page.getByRole("heading", { name: title })).toBeVisible();

    await page.getByRole("link", { name: "Edit", exact: true }).click();
    await page.getByRole("button", { name: "Add alternate title" }).click();
    await page.locator('input[type="text"][name="books_book[alternate_titles][]"]').fill(alt);
    await page.getByRole("button", { name: "Update Book" }).click();
    await expect(page.getByText("Book updated.")).toBeVisible();

    await page.locator("#alternate_titles_list").scrollIntoViewIfNeeded();
    const row = page.locator('[data-testid="alternate-title-row"]', { hasText: alt });
    const copy = row.getByTestId("copy-research-prompt");
    await copy.click();
    await expect(copy).toHaveText("Copied!");

    const clipboardText = await page.evaluate(() => navigator.clipboard.readText());
    expect(clipboardText).toContain(`Title: ${title}`);
    expect(clipboardText).toContain(`Alternate title in question: "${alt}"`);
    // The icon-only button gets its icon back after the "Copied!" feedback.
    await expect(copy.locator("svg")).toBeVisible({ timeout: 5000 });
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
