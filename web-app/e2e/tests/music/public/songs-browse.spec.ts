import { test, expect } from '../../../fixtures/auth';

test.describe('Songs Browse', () => {
  test('all-time songs page loads with ranked songs', async ({ page }) => {
    await page.goto('/songs');

    await expect(page.getByRole('heading').first()).toBeVisible();
    // Verify ranked items are shown
    await expect(page.locator('text=#1').first()).toBeVisible();
  });

  test('decade songs page loads', async ({ page }) => {
    await page.goto('/songs/1970s');

    await expect(page.getByRole('heading').first()).toBeVisible();
  });
});
