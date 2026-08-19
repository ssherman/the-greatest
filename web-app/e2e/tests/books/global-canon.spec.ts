import { test, expect } from '@playwright/test';

test.describe('The Global Canon', () => {
  test('loads and renders the heading', async ({ page }) => {
    const response = await page.goto('/global-canon');

    expect(response?.status()).toBe(200);
    await expect(page.getByRole('heading', { name: 'The Global Literary Canon', level: 1 })).toBeVisible();
  });

  test('is reachable from the Lists nav menu', async ({ page }) => {
    await page.goto('/');

    await page.locator('.menu-horizontal summary', { hasText: 'Lists' }).click();
    await page.locator('.menu-horizontal').getByRole('link', { name: 'The Global Canon', exact: true }).click();

    await expect(page).toHaveURL(/\/global-canon$/);
  });

  test('changing a setting rewrites the URL into the path form', async ({ page }) => {
    await page.goto('/global-canon');

    await page.getByLabel('Total books').selectOption('50');
    await page.getByTestId('canon-update').click();

    await expect(page).toHaveURL('/global-canon/total_books/50/nonfiction/20/max_per_country/3');
  });

  test('a smaller total returns fewer books', async ({ page }) => {
    await page.goto('/global-canon/total_books/50/nonfiction/20/max_per_country/3');
    const fifty = await page.locator('[data-listable-type="Books::Book"]').count();

    await page.goto('/global-canon/total_books/250/nonfiction/20/max_per_country/3');
    const twoFifty = await page.locator('[data-listable-type="Books::Book"]').count();

    expect(twoFifty).toBeGreaterThan(fifty);
  });

  // This only holds because the top-ranked fiction candidate and the
  // top-ranked non-fiction candidate are different books -- today Ulysses
  // (rank 1) versus Essays (rank 82), a wide margin. 1,633 books in the
  // development database carry BOTH the `fiction` and `nonfiction` category
  // tags, so if a re-tag ever made the single top-ranked book dual-tagged,
  // this test would fail for a data reason rather than a real regression.
  test('an all-fiction canon and an all-nonfiction canon differ', async ({ page }) => {
    await page.goto('/global-canon/total_books/50/nonfiction/0/max_per_country/3');
    const fictionFirst = await page.locator('[data-listable-type="Books::Book"]').first().innerText();

    await page.goto('/global-canon/total_books/50/nonfiction/100/max_per_country/3');
    const nonfictionFirst = await page.locator('[data-listable-type="Books::Book"]').first().innerText();

    expect(fictionFirst).not.toEqual(nonfictionFirst);
  });

  test('spelled-out defaults redirect to the bare path', async ({ page }) => {
    await page.goto('/global-canon/total_books/150/nonfiction/20/max_per_country/3');

    await expect(page).toHaveURL('/global-canon');
  });

  test('excluding a genre adds it to the URL and drops its books', async ({ page }) => {
    await page.goto('/global-canon/total_books/50/nonfiction/20/max_per_country/3');
    const before = await page.locator('[data-listable-type="Books::Book"]').allInnerTexts();

    await page.getByTestId('canon-genre-search').fill('literary fiction');
    await page.getByRole('button', { name: /Literary Fiction/ }).first().click();
    await page.getByTestId('canon-update').click();

    await expect(page).toHaveURL(/\/excluding\/[a-z0-9,-]+$/);

    const after = await page.locator('[data-listable-type="Books::Book"]').allInnerTexts();
    expect(after).not.toEqual(before);
  });

  test('an active exclusion is shown back on the page', async ({ page }) => {
    await page.goto('/global-canon/total_books/50/nonfiction/20/max_per_country/3');

    await page.getByTestId('canon-genre-search').fill('literary fiction');
    await page.getByRole('button', { name: /Literary Fiction/ }).first().click();
    await page.getByTestId('canon-update').click();

    await expect(page.locator('[data-chip]')).toHaveCount(1);
  });

  // Books::GlobalCanonParams::MAX_EXCLUDED_GENRES is 6 -- a 7th selection
  // used to 404 the moment "Update list" was pressed, with no explanation.
  // Seven distinct, unambiguous genre queries, each verified to resolve to
  // exactly the genre it names.
  test('a 7th genre exclusion is blocked in the picker, with an explanation', async ({ page }) => {
    await page.goto('/global-canon');

    const search = page.getByTestId('canon-genre-search');
    const addFirstResult = () => page.locator('[data-action="saved-search-picker#add"]').first().click();
    const genreQueries = ['21st cent', 'aapi', 'absurdist', 'americana', 'ancient', 'anthologies'];

    for (const query of genreQueries) {
      await search.fill(query);
      await addFirstResult();
    }
    await expect(page.locator('[data-chip]')).toHaveCount(6);

    // The limit notice is not shown until the cap is actually hit.
    await expect(page.getByTestId('canon-genre-limit')).toBeHidden();

    // The 7th chip must not be added -- the picker silently accepting it
    // (only to 404 on submit) is exactly the bug being fixed.
    await search.fill('apocalyptic');
    await addFirstResult();
    await expect(page.locator('[data-chip]')).toHaveCount(6);

    // The visitor is told why, not left with a silent no-op.
    await expect(page.getByTestId('canon-genre-limit')).toBeVisible();
    await expect(page.getByTestId('canon-genre-limit')).toContainText('up to 6');

    // Update list still succeeds with exactly the 6 chips that made it in --
    // no 404, the page it lands on is the real canon page.
    await page.getByTestId('canon-update').click();
    await expect(page.getByRole('heading', { name: 'The Global Literary Canon', level: 1 })).toBeVisible();
    await expect(page).toHaveURL(/\/excluding\/[a-z0-9,-]+$/);
    await expect(page.locator('[data-chip]')).toHaveCount(6);
  });
});
