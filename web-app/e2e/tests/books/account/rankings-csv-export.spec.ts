import { test, expect } from '@playwright/test';

// The BOM is built at runtime on purpose: a literal U+FEFF in the source is
// invisible in review and easy to lose on save.
const BOM = String.fromCharCode(0xfeff);

// books-account is the ordinary (non-member) E2E account. If it is ever
// comped, the modal never opens; the guard below skips rather than fails.
test.describe('Books rankings CSV export (non-member)', () => {
  test.beforeEach(async ({ page }) => {
    const state = await page.request.get('/membership_state', { headers: { Accept: 'application/json' } });
    test.skip(state.ok() && (await state.json()).member === true, 'account is a member');
  });

  test('explains the top-500 cap and downloads the preview', async ({ page }) => {
    await page.goto('/');
    await page.getByTestId('download-csv').click();

    const dialog = page.locator('#csv_export_modal');
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole('heading', { name: /500 books/ })).toBeVisible();
    await expect(dialog.getByRole('link', { name: 'Become a member' })).toHaveAttribute('href', '/membership');

    const [download] = await Promise.all([
      page.waitForEvent('download'),
      dialog.getByRole('link', { name: 'Download top 500' }).click(),
    ]);
    expect(download.suggestedFilename()).toMatch(/^the-greatest-books-rankings-\d{4}-\d{2}-\d{2}\.csv$/);
  });

  test('the preview is capped at 500 rows and carries the current filters', async ({ page }) => {
    const response = await page.request.get('/export.csv?category_id=novels');

    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toContain('text/csv');
    expect(response.headers()['cache-control']).toContain('no-store');
    const text = await response.text();
    expect(text.startsWith(BOM + 'Rank,Score,ID,Title')).toBe(true);
    // Header line plus at most 500 rows.
    expect(text.trim().split('\n').length).toBeLessThanOrEqual(501);
  });
});
