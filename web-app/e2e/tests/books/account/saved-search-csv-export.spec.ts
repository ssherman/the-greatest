import { test, expect } from '@playwright/test';

// Signed-in only, like saved_searches_write.spec.ts: a saved search needs an
// owner, so this lives under tests/books/account/ for the books-account
// project. Creates a real search on the shared dev database and deletes it.
test.describe('Saved search CSV export', () => {
  test('a saved search page offers a CSV download that serves CSV', async ({ page }) => {
    await page.goto('/searches');
    await page.getByRole('link', { name: 'New Saved Search' }).click();

    const name = `E2E csv ${Date.now()}`;
    await page.getByLabel('Name').fill(name);
    await page.getByLabel('Type').selectOption({ label: 'Fiction' });
    await page.getByRole('button', { name: 'Create search' }).click();
    await expect(page.getByRole('heading', { level: 1 })).toContainText(name);

    const link = page.getByTestId('download-csv');
    await expect(link).toBeVisible();
    const href = (await link.getAttribute('href'))!;
    expect(href).toMatch(/^\/searches\/\d+\/export\.csv$/);

    const response = await page.request.get(href);
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toContain('text/csv');

    // Clean up so the account does not accumulate searches across runs.
    page.on('dialog', (dialog) => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();
    await expect(page).toHaveURL('/searches');
  });
});
