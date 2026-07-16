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
});
