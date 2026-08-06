import { test, expect } from '@playwright/test';

const openModal = async (page) => {
  await page.getByRole('button', { name: 'Filters' }).click();
  await expect(page.locator('dialog#books_filter_modal')).toBeVisible();
};

test.describe('Books filters', () => {
  test('no pane is fetched until its axis is opened', async ({ page }) => {
    const paneRequests: string[] = [];
    page.on('request', (r) => {
      if (r.url().includes('/filters/categories')) paneRequests.push(r.url());
    });

    await page.goto('/');
    await page.waitForLoadState('networkidle');
    await openModal(page);

    expect(paneRequests).toHaveLength(0);

    await page.getByRole('button', { name: /Category/ }).click();
    await expect.poll(() => paneRequests.length).toBe(1);
  });

  test('level 1 shows three axes and drills into one', async ({ page }) => {
    await page.goto('/');
    await openModal(page);

    await expect(page.locator("[data-level='root']")).toBeVisible();
    await page.getByRole('button', { name: /Category/ }).click();

    await expect(page.locator("[data-level='root']")).toBeHidden();
    await expect(page.locator("[data-level='category']")).toBeVisible();
    await expect(page.locator("input[name='category_slugs[]']").first()).toBeVisible();
  });

  test('staging survives navigating between panes', async ({ page }) => {
    await page.goto('/');
    await openModal(page);

    await page.getByRole('button', { name: /Category/ }).click();
    const genre = page.locator("input[name='category_slugs[]']").first();
    await genre.waitFor();
    await genre.check();

    await page.getByRole('button', { name: /^‹/ }).click();
    await page.getByRole('button', { name: /Origin/ }).click();
    await page.locator("input[name='country_slugs[]']").first().waitFor();
    await page.getByRole('button', { name: /^‹/ }).click();
    await page.getByRole('button', { name: /Category/ }).click();

    await expect(genre).toBeChecked();
  });

  test('applying across two axes navigates to the canonical URL', async ({ page }) => {
    await page.goto('/');
    await openModal(page);

    await page.getByRole('button', { name: /Category/ }).click();
    await page.locator("input[name='category_slugs[]'][value='novels']").check();
    await page.getByRole('button', { name: /^‹/ }).click();
    await page.getByRole('button', { name: /Origin/ }).click();
    await page.locator("input[name='country_slugs[]'][value='french']").check();
    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page).toHaveURL('/the-greatest/novels/books/written-by/french/authors');
    await expect(page.getByTestId('filter-chip')).toHaveCount(2);
  });

  test('search is scoped to its own axis', async ({ page }) => {
    await page.goto('/');
    await openModal(page);

    await page.getByRole('button', { name: /Category/ }).click();
    await page.getByPlaceholder('Search genres, subjects, settings').fill('fren');

    await expect(page.locator("turbo-frame#books_filter_results_category input")).toHaveCount(0);
  });

  test('a checked search result survives the next search', async ({ page }) => {
    await page.goto('/');
    await openModal(page);
    await page.getByRole('button', { name: /Category/ }).click();

    const search = page.getByPlaceholder('Search genres, subjects, settings');
    await search.fill('politic');
    const hit = page.locator("turbo-frame#books_filter_results_category input").first();
    await hit.waitFor();
    const slug = await hit.getAttribute('value');
    await hit.check();

    await search.fill('zzzzz-no-such-category');
    await expect(page.locator("turbo-frame#books_filter_results_category input")).toHaveCount(0);

    await expect(page.locator(`input[name='category_slugs[]'][value='${slug}']`)).toBeChecked();
  });

  test('a staged subject can be unchecked after applying', async ({ page }) => {
    await page.goto('/');
    await openModal(page);
    await page.getByRole('button', { name: /Category/ }).click();

    const search = page.getByPlaceholder('Search genres, subjects, settings');
    await search.fill('politic');
    const hit = page.locator("turbo-frame#books_filter_results_category input").first();
    await hit.waitFor();
    const slug = await hit.getAttribute('value');
    await hit.check();
    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page.getByTestId('filter-chip')).toHaveCount(1);

    await openModal(page);
    await page.getByRole('button', { name: /Category/ }).click();
    const staged = page.locator(`input[name='category_slugs[]'][value='${slug}']`);
    await staged.waitFor();
    await expect(staged).toBeChecked();
    await staged.uncheck();
    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page).toHaveURL('/');
  });

  test('pressing Enter in the search box does not apply the filters', async ({ page }) => {
    await page.goto('/');
    await openModal(page);
    await page.getByRole('button', { name: /Category/ }).click();

    const search = page.getByPlaceholder('Search genres, subjects, settings');
    await search.fill('novel');
    await search.press('Enter');

    await page.waitForTimeout(500);
    await expect(page).toHaveURL('/');
    await expect(page.locator('dialog#books_filter_modal')).toBeVisible();
  });

  test('chips remove one filter at a time down to the root', async ({ page }) => {
    await page.goto('/the-greatest/novels/books/written-by/french/authors');

    await expect(page.getByTestId('filter-chip')).toHaveCount(2);
    await page.getByTestId('filter-chip').filter({ hasText: 'French' }).getByRole('link').click();

    await expect(page).toHaveURL('/the-greatest/novels/books');
    await page.getByTestId('filter-chip').filter({ hasText: 'Novels' }).getByRole('link').click();

    await expect(page).toHaveURL('/');
    await expect(page.getByTestId('filter-chip')).toHaveCount(0);
  });

  test('the heading reflects the active filter', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');

    await expect(page.getByRole('heading', { level: 1 })).toContainText(/Novels/i);
  });

  test('an unknown genre slug is a 404', async ({ page }) => {
    const response = await page.goto('/the-greatest/no-such-genre/books');

    expect(response?.status()).toBe(404);
  });
});
