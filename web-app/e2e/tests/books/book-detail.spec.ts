import { test, expect } from '@playwright/test';

test.describe('Book detail page', () => {
  test('a grid card links through to a book page', async ({ page }) => {
    await page.goto('/');

    const firstCardLink = page.locator('.card h2 a').first();
    const title = (await firstCardLink.textContent())?.trim() ?? '';
    await firstCardLink.click();

    await expect(page).toHaveURL(/\/book\//);
    await expect(page.getByRole('heading', { level: 1, name: title })).toBeVisible();
  });

  test('legacy /books/:id redirects permanently to the slug url', async ({ page }) => {
    const response = await page.goto('/books/1');

    expect(response?.status()).toBe(200);
    await expect(page).toHaveURL(/\/book\/[^/]+$/);
  });

  test('legacy /items/:id redirects to the slug url', async ({ page }) => {
    await page.goto('/items/1');

    await expect(page).toHaveURL(/\/book\/[^/]+$/);
  });

  test('/the-greatest-books redirects to the root', async ({ page }) => {
    await page.goto('/the-greatest-books');

    await expect(page).toHaveURL(/thegreatestbooks\.org\/$/);
  });
});
