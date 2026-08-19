import { test, expect } from '@playwright/test';

test.describe('The Global Canon', () => {
  test('loads and renders the heading', async ({ page }) => {
    const response = await page.goto('/global-canon');

    expect(response?.status()).toBe(200);
    await expect(page.getByRole('heading', { name: 'The Global Literary Canon', level: 1 })).toBeVisible();
  });

  test('is reachable from the Lists nav menu', async ({ page }) => {
    await page.goto('/');

    await page.locator('.menu-horizontal summary', { hasText: 'Lists' }).click();
    await page.locator('.menu-horizontal').getByRole('link', { name: 'The Global Canon', exact: true }).click();

    await expect(page).toHaveURL(/\/global-canon$/);
  });

  test('changing a setting rewrites the URL into the path form', async ({ page }) => {
    await page.goto('/global-canon');

    await page.getByLabel('Total books').selectOption('50');
    await page.getByTestId('canon-update').click();

    await expect(page).toHaveURL('/global-canon/total_books/50/nonfiction/20/max_per_country/3');
  });

  test('a smaller total returns fewer books', async ({ page }) => {
    await page.goto('/global-canon/total_books/50/nonfiction/20/max_per_country/3');
    const fifty = await page.locator('[data-listable-type="Books::Book"]').count();

    await page.goto('/global-canon/total_books/250/nonfiction/20/max_per_country/3');
    const twoFifty = await page.locator('[data-listable-type="Books::Book"]').count();

    expect(twoFifty).toBeGreaterThan(fifty);
  });

  test('an all-fiction canon and an all-nonfiction canon differ', async ({ page }) => {
    await page.goto('/global-canon/total_books/50/nonfiction/0/max_per_country/3');
    const fictionFirst = await page.locator('[data-listable-type="Books::Book"]').first().innerText();

    await page.goto('/global-canon/total_books/50/nonfiction/100/max_per_country/3');
    const nonfictionFirst = await page.locator('[data-listable-type="Books::Book"]').first().innerText();

    expect(fictionFirst).not.toEqual(nonfictionFirst);
  });

  test('spelled-out defaults redirect to the bare path', async ({ page }) => {
    await page.goto('/global-canon/total_books/150/nonfiction/20/max_per_country/3');

    await expect(page).toHaveURL('/global-canon');
  });
});
