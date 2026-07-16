import { test, expect } from '@playwright/test';

test.describe('books admin — editions', () => {
  test('create an edition from a book and set it as default', async ({ page }) => {
    // Create a fresh book to attach an edition to.
    await page.goto('/admin/books/new');
    const title = `E2E Edition Book ${Date.now()}`;
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole('button', { name: 'Create Book' }).click();
    await expect(page.getByRole('heading', { name: title })).toBeVisible();

    // Add an edition from the book show page.
    await page.getByRole('link', { name: '+ New Edition' }).click();
    await expect(page.getByRole('heading', { name: 'New Edition' })).toBeVisible();
    await page.locator('input[name="books_edition[publisher_name]"]').fill('E2E Press');
    await page.locator('input[name="books_edition[publication_year]"]').fill('2011');
    await page.getByRole('button', { name: 'Create Edition' }).click();

    // Lands on the edition show page.
    await expect(page.getByText('Edition of')).toBeVisible();
    await expect(page.getByText('E2E Press')).toBeVisible();

    // Set it as the book's default; redirects to the book show page where the
    // lazy editions frame shows the ★ Default badge.
    await page.getByRole('button', { name: 'Set as default' }).click();
    await expect(page.getByRole('heading', { name: title })).toBeVisible();
    await page.locator('turbo-frame#book_editions').scrollIntoViewIfNeeded();
    await expect(page.getByText('★ Default')).toBeVisible();
  });
});
