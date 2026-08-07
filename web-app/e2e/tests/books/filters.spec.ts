import { test, expect } from '@playwright/test';

test.describe('Books filters', () => {
  test('the facets frame is not requested until the modal opens', async ({ page }) => {
    const filterOptionsRequests: string[] = [];
    page.on('request', (request) => {
      if (request.url().includes('/filters/options')) {
        filterOptionsRequests.push(request.url());
      }
    });

    await page.goto('/');
    await page.waitForLoadState('networkidle');

    expect(filterOptionsRequests).toHaveLength(0);

    await page.getByRole('button', { name: 'Filters' }).click();

    await expect.poll(() => filterOptionsRequests.length).toBe(1);
  });

  test('the filter modal opens and lists genres', async ({ page }) => {
    await page.goto('/');

    await page.getByRole('button', { name: 'Filters' }).click();

    await expect(page.locator('dialog#books_filter_modal')).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Filters' })).toBeVisible();
    await expect(page.locator('input[name="category_slugs[]"]').first()).toBeVisible();
  });

  test('applying a genre navigates to its canonical filter URL', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();

    await page.locator('input[name="category_slugs[]"]').first().check();
    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page).toHaveURL(/\/the-greatest\/[^/]+\/books$/);
    await expect(page.getByTestId('filter-chip')).toHaveCount(1);
  });

  test('applying a second genre keeps the first', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');
    await page.getByRole('button', { name: 'Filters' }).click();

    const others = page.locator('input[name="category_slugs[]"]:not([value="novels"])');
    await others.first().waitFor();
    const second = await others.first().getAttribute('value');

    await others.first().check();
    await page.getByRole('button', { name: 'Apply' }).click();

    const expected = ['novels', second!].sort().join(',');
    await expect(page).toHaveURL(`/the-greatest/${expected}/books`);
    await expect(page.getByTestId('filter-chip')).toHaveCount(2);
  });

  test('the heading reflects the active filter', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');

    await expect(page.getByRole('heading', { level: 1 })).toContainText(/Novels/i);
  });

  test('chips remove one filter at a time down to the root', async ({ page }) => {
    await page.goto('/the-greatest/novels/books/written-by/french/authors');

    await expect(page.getByTestId('filter-chip')).toHaveCount(2);

    await page.getByTestId('filter-chip').filter({ hasText: 'French' }).getByRole('link').click();

    await expect(page).toHaveURL('/the-greatest/novels/books');
    await expect(page.getByTestId('filter-chip')).toHaveCount(1);
    await expect(page.getByTestId('filter-chip')).toHaveText(/Novels/);

    await page.getByTestId('filter-chip').filter({ hasText: 'Novels' }).getByRole('link').click();

    await expect(page).toHaveURL('/');
    await expect(page.getByTestId('filter-chip')).toHaveCount(0);
  });

  test('cancelling discards staged selections', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();

    const first = page.locator('input[name="category_slugs[]"]').first();
    await first.waitFor();
    const slug = await first.getAttribute('value');
    await first.check();

    await page.getByRole('button', { name: 'Cancel' }).click();
    await expect(page.locator('dialog#books_filter_modal')).not.toBeVisible();

    await page.getByRole('button', { name: 'Filters' }).click();
    await expect(page.locator(`input[name="category_slugs[]"][value="${slug}"]`)).not.toBeChecked();
  });

  test('genre search filters the visible options', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();
    await page.locator('input[name="category_slugs[]"]').first().waitFor();

    const before = await page.locator('label[data-filter-label]:visible').count();
    await page.getByPlaceholder('Filter genres and countries').fill('zzzzz-no-such-genre');
    const after = await page.locator('label[data-filter-label]:visible').count();

    expect(after).toBeLessThan(before);
  });

  test('search reaches genres and countries outside the most-common ones', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();
    await page.locator('input[name="category_slugs[]"]').first().waitFor();

    const search = page.getByPlaceholder('Filter genres and countries');

    await search.fill('sur');
    await expect(page.locator('label[data-filter-label="surreal"]')).toBeVisible();

    await search.fill('ab');
    await expect(page.locator('label[data-filter-label="absurdist"]')).toBeVisible();

    await search.fill('peruv');
    await expect(page.locator('label[data-filter-label="peruvian"]')).toBeVisible();
  });

  test('an unknown genre slug is a 404', async ({ page }) => {
    const response = await page.goto('/the-greatest/no-such-genre/books');

    expect(response?.status()).toBe(404);
  });
});
