import { test, expect } from '@playwright/test';

test.describe('Games Categories', () => {
  test('category show page loads successfully', async ({ page }) => {
    await page.goto('/categories/action');

    await expect(page.getByRole('heading', { name: /Greatest.*Action.*Games/i })).toBeVisible();
  });

  test('category show page has correct title', async ({ page }) => {
    await page.goto('/categories/action');

    await expect(page).toHaveTitle(/The Greatest Action Games of All Time/i);
  });

  test('category show page displays game cards', async ({ page }) => {
    await page.goto('/categories/action');

    const gameCards = page.locator('div.card');
    await expect(gameCards.first()).toBeVisible();
  });

  test('game cards have rank badges', async ({ page }) => {
    await page.goto('/categories/action');

    await expect(page.locator('text=#1').first()).toBeVisible();
  });

  test('returns 404 for non-existent category', async ({ page }) => {
    const response = await page.goto('/categories/nonexistent-category-slug');

    expect(response?.status()).toBe(404);
  });
});
