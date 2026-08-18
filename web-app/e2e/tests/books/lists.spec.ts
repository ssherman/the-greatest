import { test, expect } from '@playwright/test';

test.describe('Books lists index', () => {
  test('loads and renders the heading', async ({ page }) => {
    const response = await page.goto('/lists');

    expect(response?.status()).toBe(200);
    await expect(page.getByRole('heading', { name: 'The Lists', level: 1 })).toBeVisible();
  });

  test('is reachable from the nav', async ({ page }) => {
    await page.goto('/');

    await page.locator('.menu-horizontal summary', { hasText: 'Lists' }).click();
    await page.locator('.menu-horizontal').getByRole('link', { name: 'All Lists', exact: true }).click();

    await expect(page).toHaveURL(/\/lists$/);
  });

  test('pagination links are path-based', async ({ page }) => {
    await page.goto('/lists');

    await expect(page.locator('nav.pagy a[href="/lists/page/2"]').first()).toBeVisible();
  });

  test('the newest sort carries through pagination', async ({ page }) => {
    await page.goto('/lists?sort=newest');

    await expect(page.locator('nav.pagy a[href*="/lists/page/2"][href*="sort=newest"]').first()).toBeVisible();
  });

  test('search narrows the results', async ({ page }) => {
    await page.goto('/lists?q=the');

    await expect(page.getByText(/matching/)).toBeVisible();
  });

  test('a card links through to the list detail page', async ({ page }) => {
    await page.goto('/lists');

    const firstCard = page.locator('.card h3 a').first();
    const name = (await firstCard.textContent())?.trim() ?? '';
    await firstCard.click();

    await expect(page).toHaveURL(/\/lists\/\d+$/);
    await expect(page.getByRole('heading', { level: 1, name })).toBeVisible();
  });
});

test.describe('Books list detail', () => {
  test('renders the weight breakdown and a book grid', async ({ page }) => {
    await page.goto('/lists');
    await page.locator('.card h3 a').first().click();

    await expect(page.getByRole('heading', { name: 'How good is this list?' })).toBeVisible();
    await expect(page.getByText('Base weight')).toBeVisible();
    await expect(page.locator('.card h2 a').first()).toBeVisible();
  });

  test('legacy sorted-by url redirects to the canonical index', async ({ page }) => {
    await page.goto('/lists/sorted-by/weight');

    await expect(page).toHaveURL(/\/lists$/);
  });

  test('legacy view-prefixed detail url redirects to the plain path', async ({ page }) => {
    await page.goto('/lists');
    const href = await page.locator('.card h3 a').first().getAttribute('href');

    await page.goto(`/v/grid${href}`);

    await expect(page).toHaveURL(new RegExp(`${href}$`));
    expect(page.url()).not.toContain('/v/grid');
  });
});
