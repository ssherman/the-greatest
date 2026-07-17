import { test, expect } from '@playwright/test';

test.describe('books admin — inline associations', () => {
  test('add an author and a credit to a book', async ({ page }) => {
    // Create a fresh book.
    await page.goto('/admin/books/new');
    const title = `E2E Assoc Book ${Date.now()}`;
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole('button', { name: 'Create Book' }).click();
    await expect(page.getByRole('heading', { name: title })).toBeVisible();

    // Add an author via the typeahead. Scope the "+ Add" click to the Authors card
    // (Images / Related Books / Credits cards also have a "+ Add" button).
    await page.locator('.card', { hasText: 'Authors' }).getByRole('button', { name: '+ Add' }).click();
    await expect(page.getByRole('heading', { name: 'Add Author' })).toBeVisible();
    await page.locator('#books_book_author_author_id_autocomplete').fill('Tolstoy');
    await page.locator('dialog[open] li', { hasText: /tolstoy/i }).first().click();
    await page.getByRole('button', { name: 'Add Author' }).click();
    await expect(page.locator('#book_authors_list')).toContainText(/tolstoy/i);

    // Add a credit via the typeahead.
    await page.locator('.card', { hasText: 'Credits' }).getByRole('button', { name: '+ Add' }).click();
    await expect(page.getByRole('heading', { name: 'Add Credit' })).toBeVisible();
    await page.locator('#books_credit_author_id_autocomplete').fill('Tolstoy');
    await page.locator('dialog[open] li', { hasText: /tolstoy/i }).first().click();
    await page.getByRole('button', { name: 'Add Credit' }).click();
    await expect(page.locator('#credits_list')).toContainText(/tolstoy/i);
  });
});
