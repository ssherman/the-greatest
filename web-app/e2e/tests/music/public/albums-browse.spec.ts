import { test, expect } from '../../../fixtures/auth';

test.describe('Albums Browse', () => {
  test('all-time albums page loads with ranked albums', async ({ page }) => {
    await page.goto('/albums');

    await expect(page.getByRole('heading').first()).toBeVisible();
    // Verify ranked items are shown (badges with #1, #2, etc.)
    await expect(page.locator('text=#1').first()).toBeVisible();
  });

  test('decade albums page loads', async ({ page }) => {
    await page.goto('/albums/1970s');

    await expect(page.getByRole('heading').first()).toBeVisible();
  });
});
