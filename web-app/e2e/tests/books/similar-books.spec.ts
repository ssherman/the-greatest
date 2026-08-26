import { test, expect } from '@playwright/test';

test.describe('Similar books', () => {
  test('a book page shows similar books that link through', async ({ page }) => {
    await page.goto('/book/war-and-peace');

    const card = page.getByTestId('similar-books');
    await expect(card).toBeVisible();

    const firstLink = card.locator('a').first();
    const title = (await firstLink.textContent())?.trim() ?? '';
    await firstLink.click();

    await expect(page).toHaveURL(/\/book\//);
    await expect(page.getByRole('heading', { level: 1, name: title })).toBeVisible();
  });

  test('show more opens the full similar books grid', async ({ page }) => {
    await page.goto('/book/war-and-peace');

    await page.getByTestId('similar-books-show-more').click();

    await expect(page).toHaveURL(/\/book\/war-and-peace\/similar$/);
    await expect(
      page.getByRole('heading', { level: 1, name: /Books similar to/ })
    ).toBeVisible();
    await expect(page.locator('.card').first()).toBeVisible();
  });

  test('the similar page links back to the book', async ({ page }) => {
    await page.goto('/book/war-and-peace/similar');

    await page.getByRole('link', { name: /Back to/ }).click();

    await expect(page).toHaveURL(/\/book\/war-and-peace$/);
  });
});
