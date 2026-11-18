import { test, expect } from '@playwright/test';

test.describe('Books Admin Publisher Intake', () => {
  test('sidebar reaches the overview, the titles list and a title', async ({ page }) => {
    await page.goto('/admin');
    await page.getByTestId('admin-sidebar').getByRole('link', { name: 'Publisher Intake', exact: true }).click();

    await expect(page).toHaveURL(/\/admin\/publisher_intake/);
    await expect(page.getByRole('heading', { name: 'Publisher Intake', exact: true })).toBeVisible();

    await page.getByRole('link', { name: 'All titles' }).click();
    await expect(page).toHaveURL(/\/admin\/publisher_titles/);
    await expect(page.getByRole('heading', { name: 'Publisher Titles', exact: true })).toBeVisible();

    const rows = page.getByTestId('title-row');
    if (await rows.count() === 0) {
      await expect(page.getByText('No titles match.')).toBeVisible();
      return;
    }
    await rows.first().getByRole('link').first().click();
    await expect(page).toHaveURL(/\/admin\/publisher_titles\/\d+/);
    await expect(page.getByRole('heading', { name: 'Formats' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Listings' })).toBeVisible();
  });
});
