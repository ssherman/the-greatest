import { test, expect } from '@playwright/test';

test.describe('Recommendations, signed out', () => {
  test('shows the pitch with a sign-in button', async ({ page }) => {
    await page.goto('/recommendations');
    await expect(page.getByRole('heading', { level: 1 })).toContainText(/recommendations/i);
    await page.getByTestId('pitch-sign-in').click();
    await expect(page.locator('#login_modal')).toBeVisible();
  });
});
