import { test, expect } from '@playwright/test';

test.describe('Recommendation settings, as a free account', () => {
  test('the form is locked and offers membership instead of save', async ({ page }) => {
    await page.goto('/recommendations/settings');
    await expect(page.getByTestId('settings-locked')).toBeVisible();
    await expect(page.locator('[data-testid="settings-fields"][disabled]')).toHaveCount(1);
    await expect(page.getByTestId('settings-join')).toHaveAttribute('href', /\/membership$/);
    await expect(page.getByTestId('settings-save')).toHaveCount(0);
  });

  test('the My Books menu links to recommendations', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#navbar_my_books a[href="/recommendations"]').first()).toBeAttached();
  });
});
