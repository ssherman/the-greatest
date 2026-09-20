import { test, expect } from '@playwright/test';

// Built at runtime: a literal U+FEFF in the source is invisible in review.
const BOM = String.fromCharCode(0xfeff);

// The `games` project signs in as the admin account, so the export serves
// CSV rather than redirecting. A year filter keeps this on the on-demand
// path, which answers immediately whether or not the account is a member.
test.describe('Games CSV export', () => {
  test('the games page offers a download and a filtered export serves CSV', async ({ page }) => {
    await page.goto('/video-games');
    await expect(page.getByTestId('download-csv')).toBeVisible();

    const response = await page.request.get('/video-games/export.csv?year=2017&year_mode=since');
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toContain('text/csv');
    // Compared as a slice rather than startsWith so a failure shows what
    // actually came back.
    const expected = BOM + 'Rank,Score,ID,Title,Year,Platforms';
    expect((await response.text()).slice(0, expected.length)).toBe(expected);
  });
});
