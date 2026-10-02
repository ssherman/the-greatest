import { test, expect } from '@playwright/test';

// Anonymous `books` project: no storage state, so the page has no tg_uid
// cookie and the button must open the sign-in modal, never the top-500
// dialog. The endpoint itself is sign-in only.
test.describe('Books rankings CSV export (anonymous)', () => {
  test('the download button opens the login modal for a visitor', async ({ page }) => {
    await page.goto('/');

    await page.getByTestId('download-csv').click();

    await expect(page.locator('#login_modal')).toBeVisible();
    await expect(page.locator('#csv_export_modal')).not.toBeVisible();
  });

  test('the export endpoint turns an anonymous request away', async ({ page }) => {
    const response = await page.request.get('/export.csv', { maxRedirects: 0 });

    expect(response.status()).toBe(302);
  });
});
