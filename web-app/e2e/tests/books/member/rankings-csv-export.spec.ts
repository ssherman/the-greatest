import { test, expect } from '@playwright/test';

// Matched by `books-member`: PLAYWRIGHT_MEMBER_EMAIL, comped by
// `bin/rails e2e:member`. A member never sees the top-500 dialog.
test.describe('Books rankings CSV export (member)', () => {
  test('a member is taken straight to the file on a filtered page', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');

    const [download] = await Promise.all([
      page.waitForEvent('download'),
      page.getByTestId('download-csv').click(),
    ]);

    expect(download.suggestedFilename()).toMatch(/\.csv$/);
    await expect(page.locator('#csv_export_modal')).not.toBeVisible();
  });

  test('the unfiltered export is the pre-built file or the preparing page', async ({ page }) => {
    // The pre-built file is generated in the background, so either answer is
    // correct here; what must not happen is an on-demand capped CSV.
    const response = await page.request.get('/export.csv');

    expect([200, 202]).toContain(response.status());
    if (response.status() === 200) {
      expect(response.headers()['content-type']).toContain('text/csv');
    } else {
      expect(response.headers()['refresh']).toBe('15');
      expect(await response.text()).toContain('Preparing your export');
    }
  });
});
