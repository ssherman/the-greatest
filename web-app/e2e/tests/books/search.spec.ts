import { test, expect } from '@playwright/test';

// "War and Peace" is a real, indexed book in the development data. If this
// suite starts failing on zero results, check that OpenSearch has the books
// index populated before suspecting the search code.
const knownQuery = 'War and Peace';

test.describe('Books search', () => {
  test('the navbar search box takes a visitor from the homepage to results', async ({ page }) => {
    await page.goto('/');

    await page.getByRole('searchbox', { name: 'Search books' }).fill(knownQuery);
    await page.getByRole('searchbox', { name: 'Search books' }).press('Enter');

    await expect(page).toHaveURL(/\/search\?q=War\+and\+Peace/);
    await expect(page.getByRole('heading', { level: 1, name: /Search results for/ })).toBeVisible();
    await expect(page.locator('[data-listable-type="Books::Book"]').first()).toBeVisible();
  });

  test('a direct search URL returns matching books', async ({ page }) => {
    const response = await page.goto(`/search?q=${encodeURIComponent(knownQuery)}`);

    expect(response?.status()).toBe(200);
    await expect(page.getByRole('link', { name: knownQuery }).first()).toBeVisible();
  });

  test('the navbar box keeps the query after searching', async ({ page }) => {
    await page.goto(`/search?q=${encodeURIComponent(knownQuery)}`);

    await expect(page.getByRole('searchbox', { name: 'Search books' })).toHaveValue(knownQuery);
  });

  test('search with no query prompts instead of listing books', async ({ page }) => {
    const response = await page.goto('/search');

    expect(response?.status()).toBe(200);
    await expect(page.getByText('Enter a search term to find books')).toBeVisible();
    await expect(page.locator('[data-listable-type="Books::Book"]')).toHaveCount(0);
  });

  test('a query matching nothing says so', async ({ page }) => {
    await page.goto('/search?q=zzzqqqxxnotabook');

    await expect(page.getByText('No results found for')).toBeVisible();
    await expect(page.locator('[data-listable-type="Books::Book"]')).toHaveCount(0);
  });

  test('results are noindex and never edge cached', async ({ page }) => {
    const response = await page.goto(`/search?q=${encodeURIComponent(knownQuery)}`);

    await expect(page.locator('meta[name="robots"]')).toHaveAttribute('content', /noindex/);
    expect(response?.headers()['cache-control']).toMatch(/no-store/);
  });
});
