import { test, expect } from '@playwright/test';

test.describe('Games Lists', () => {
  test('lists page loads successfully', async ({ page }) => {
    await page.goto('/lists');

    await expect(page.getByRole('heading', { name: /Greatest Video Game Lists/i })).toBeVisible();
  });
});
