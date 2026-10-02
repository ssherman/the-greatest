import { test, expect } from '@playwright/test';

// Built at runtime: a literal U+FEFF in the source is invisible in review.
const BOM = String.fromCharCode(0xfeff);

// The `chromium` project signs in as the admin account, so the export serves
// CSV rather than redirecting. A year filter keeps this on the on-demand
// path, which answers immediately whether or not the account is a member.
test.describe('Music CSV export', () => {
  for (const [path, exportPath] of [
    ['/albums', '/albums/export.csv?year=1990s'],
    ['/songs', '/songs/export.csv?year=1990s'],
  ] as const) {
    test(`${path} offers a download and a filtered export serves CSV`, async ({ page }) => {
      await page.goto(path);
      await expect(page.getByTestId('download-csv')).toBeVisible();

      const response = await page.request.get(exportPath);
      expect(response.status()).toBe(200);
      expect(response.headers()['content-type']).toContain('text/csv');
      // Compared as a slice rather than startsWith so a failure shows what
      // actually came back.
      const expected = BOM + 'Rank,Score,ID,Title,Artists';
      expect((await response.text()).slice(0, expected.length)).toBe(expected);
    });
  }
});
