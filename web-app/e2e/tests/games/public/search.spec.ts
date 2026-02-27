import { test, expect } from '@playwright/test';

test.describe('Games Search', () => {
  test('search page loads with empty state', async ({ page }) => {
    await page.goto('/search');

    await expect(page.getByRole('heading', { name: 'Search Results' })).toBeVisible();
    await expect(page.getByText('Enter a search term to find video games')).toBeVisible();
  });

  test('search with query returns results', async ({ page }) => {
    await page.goto('/search?q=Super Mario Bros');

    await expect(page.getByRole('heading', { name: /Search Results for/ })).toBeVisible();
  });

  test('search bar in navbar submits search', async ({ page }) => {
    await page.goto('/');

    const searchInput = page.getByPlaceholder('Search games...');
    await expect(searchInput).toBeVisible();

    await searchInput.fill('Super Mario Bros');
    await searchInput.press('Enter');

    await expect(page).toHaveURL(/\/search\?q=Super\+Mario\+Bros/);
    await expect(page.getByRole('heading', { name: /Search Results/ })).toBeVisible();
  });
});
