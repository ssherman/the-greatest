import { test, expect } from '@playwright/test';

test.describe('Games Browse', () => {
  test('all-time games page loads with ranked games', async ({ page }) => {
    await page.goto('/video-games');

    await expect(page.getByRole('heading').first()).toBeVisible();
    // Verify ranked items are shown (badges with #1, #2, etc.)
    await expect(page.locator('text=#1').first()).toBeVisible();
  });

  test('decade games page loads', async ({ page }) => {
    await page.goto('/video-games/2000s');

    await expect(page.getByRole('heading').first()).toBeVisible();
  });

  test('front page loads ranked games', async ({ page }) => {
    await page.goto('/');

    await expect(page.getByRole('heading').first()).toBeVisible();
  });
});
