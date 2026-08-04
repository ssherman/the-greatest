import { test, expect } from '@playwright/test';

test.describe('Books filters', () => {
  test('the filter modal opens and lists genres', async ({ page }) => {
    await page.goto('/');

    await page.getByRole('button', { name: 'Filters' }).click();

    await expect(page.locator('dialog#books_filter_modal')).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Filters' })).toBeVisible();
    await expect(page.locator('input[name="category_slugs[]"]').first()).toBeVisible();
  });

  test('applying a genre navigates to its canonical filter URL', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();

    await page.locator('input[name="category_slugs[]"]').first().check();
    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page).toHaveURL(/\/the-greatest\/[^/]+\/books$/);
    await expect(page.getByTestId('filter-chip')).toHaveCount(1);
  });

  test('the heading reflects the active filter', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');

    await expect(page.getByRole('heading', { level: 1 })).toContainText(/Novels/i);
  });

  test('a chip removes its filter and returns to the root', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');

    await page.getByTestId('filter-chip').getByRole('link').click();

    await expect(page).toHaveURL(/\/$/);
    await expect(page.getByTestId('filter-chip')).toHaveCount(0);
  });

  test('genre search filters the visible options', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();
    await page.locator('input[name="category_slugs[]"]').first().waitFor();

    const before = await page.locator('label[data-filter-label]:visible').count();
    await page.getByPlaceholder('Filter genres').fill('zzzzz-no-such-genre');
    const after = await page.locator('label[data-filter-label]:visible').count();

    expect(after).toBeLessThan(before);
  });

  test('an unknown genre slug is a 404', async ({ page }) => {
    const response = await page.goto('/the-greatest/no-such-genre/books');

    expect(response?.status()).toBe(404);
  });
});
