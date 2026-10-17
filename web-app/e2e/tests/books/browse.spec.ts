import { test, expect, type Page } from '@playwright/test';

// The category index lives at /categories (genres), /categories/settings and
// /categories/subjects. E2E runs against the real dev database, so these assert
// structure and categories that certainly exist (Fiction, Europe, War), never
// counts.

const CARD_LINKS = "#categories_results a[href^='/the-greatest/']";
const searchBox = (page: Page) => page.getByRole('searchbox', { name: 'Search categories' });
const categoryTabs = (page: Page) => page.getByRole('navigation', { name: 'Category type' });
// The persistent live region lives outside the results frame, inside the form.
const announcer = (page: Page) => page.locator("form [role='status']");
// Only the search results page renders this; the grid never does.
const inFrameStatus = (page: Page) => page.locator('#categories_results [data-search-status]');

async function firstCardHref(page: Page) {
  return page.locator(CARD_LINKS).first().getAttribute('href');
}

test.describe('Books browse pages', () => {
  test('a genre card navigates to its filter page', async ({ page }) => {
    await page.goto('/categories');

    const card = page.locator("a[href^='/the-greatest/']").first();
    const href = await card.getAttribute('href');
    await card.click();

    await expect(page).toHaveURL(href!);
    await expect(page.getByTestId('filter-chip')).toHaveCount(1);
  });

  test('a country card navigates to its filter page', async ({ page }) => {
    await page.goto('/countries');

    const card = page.locator("a[href*='written-by/']").first();
    const href = await card.getAttribute('href');
    await card.click();

    await expect(page).toHaveURL(href!);
    await expect(page.getByTestId('filter-chip')).toHaveCount(1);
  });

  test('the Subjects tab lists different categories', async ({ page }) => {
    await page.goto('/categories');
    const before = await firstCardHref(page);

    await categoryTabs(page).getByRole('link', { name: 'Subjects' }).click();

    await expect(page).toHaveURL('/categories/subjects');
    await expect(categoryTabs(page).getByRole('link', { name: 'Subjects' })).toHaveAttribute('aria-current', 'page');
    await expect(page.locator(CARD_LINKS).first()).toBeVisible();
    expect(await firstCardHref(page)).not.toBe(before);
  });

  test('the sort dropdown reorders A to Z', async ({ page }) => {
    await page.goto('/categories');

    await expect(page.getByTestId('sort-label')).toHaveText('Sort: Most books');
    await page.locator('details.dropdown summary').click();
    await page.getByRole('link', { name: 'A–Z' }).click();

    await expect(page).toHaveURL('/categories/sorted-by/name');
    await expect(page.getByTestId('sort-label')).toHaveText('Sort: A–Z');
  });

  test('going Back after sorting leaves the sort menu closed', async ({ page }) => {
    await page.goto('/categories');

    await page.locator('details.dropdown summary').click();
    await expect(page.locator('details.dropdown')).toHaveAttribute('open', '');
    await page.getByRole('link', { name: 'A–Z' }).click();
    await expect(page).toHaveURL('/categories/sorted-by/name');

    await page.goBack();

    await expect(page).toHaveURL('/categories');
    await expect(page.getByTestId('sort-label')).toHaveText('Sort: Most books');
    await expect(page.locator('details.dropdown')).not.toHaveAttribute('open', /.*/);
  });

  test('searching as you type finds a category, and clearing restores the grid', async ({ page }) => {
    await page.goto('/categories');
    const original = await firstCardHref(page);

    await searchBox(page).fill('fiction');

    // The genres grid already has a Fiction card, so wait for the search itself:
    // its status line, and a result card (only results carry a type badge).
    await expect(inFrameStatus(page)).toContainText(/match/);
    await expect(page.locator("#categories_results a:has(.badge)[href='/the-greatest/fiction/books']")).toBeVisible();
    // Searching in place: the address bar stays on the index.
    await expect(page).toHaveURL('/categories');

    await searchBox(page).fill('');

    await expect(inFrameStatus(page)).toHaveCount(0);
    await expect(page.locator(CARD_LINKS).first()).toHaveAttribute('href', original!);
  });

  test('search finds a category from another tab', async ({ page }) => {
    await page.goto('/categories');

    await searchBox(page).fill('europe');

    await expect(page.locator('#categories_results .badge', { hasText: 'Setting' }).first()).toBeVisible();
  });

  test('typing a single character leaves the grid alone', async ({ page }) => {
    await page.goto('/categories');
    const original = await firstCardHref(page);
    const searches: string[] = [];
    page.on('request', (request) => {
      if (request.url().includes('/categories/search')) searches.push(request.url());
    });

    await searchBox(page).fill('f');
    // Waiting out the 250 ms debounce is the point: nothing may fire after it.
    await page.waitForTimeout(600);

    expect(searches).toEqual([]);
    await expect(inFrameStatus(page)).toHaveCount(0);
    await expect(page.locator(CARD_LINKS).first()).toHaveAttribute('href', original!);
  });

  test('clearing the box before results land ends on the grid', async ({ page }) => {
    // Hold the search response so the box can be cleared while it is in flight.
    await page.route('**/categories/search**', async (route) => {
      await new Promise((resolve) => setTimeout(resolve, 800));
      try {
        await route.continue();
      } catch {
        // The page abandoned the request when the box was cleared.
      }
    });
    await page.goto('/categories');
    const original = await firstCardHref(page);

    const requested = page.waitForRequest('**/categories/search**');
    await searchBox(page).fill('war');
    await requested;
    await searchBox(page).fill('');

    await expect(inFrameStatus(page)).toHaveCount(0);
    await expect(page.locator(CARD_LINKS).first()).toHaveAttribute('href', original!);
    // The held response must not land late and put results back under an empty box.
    await page.waitForTimeout(1500);
    await expect(inFrameStatus(page)).toHaveCount(0);
    await expect(page.locator(CARD_LINKS).first()).toHaveAttribute('href', original!);
  });

  test('the live region repeats the in-frame result count', async ({ page }) => {
    await page.goto('/categories');

    await searchBox(page).fill('war');

    await expect(inFrameStatus(page)).toContainText(/match/);
    const text = (await inFrameStatus(page).textContent())!.trim();
    await expect(announcer(page)).toHaveText(text);
  });

  test('Back from a result, then clearing the box, brings the grid back', async ({ page }) => {
    await page.goto('/categories');
    const original = await firstCardHref(page);

    await searchBox(page).fill('fiction');
    // Real search results, not the genres grid's own Fiction card (which would
    // be clicked inside the debounce and leave no search behind).
    await expect(inFrameStatus(page)).toContainText(/match/);
    await expect(announcer(page)).toContainText(/match/);
    const result = page.locator("#categories_results a:has(.badge)[href='/the-greatest/fiction/books']");
    await expect(result).toBeVisible();
    await result.click();
    await expect(page).toHaveURL('/the-greatest/fiction/books');

    await page.goBack();
    await expect(page).toHaveURL('/categories');
    // The restored page still shows the search results under the typed text,
    // with the announcer blanked so no stale count is read out.
    await expect(searchBox(page)).toHaveValue('fiction');
    await expect(inFrameStatus(page)).toHaveCount(1);
    await expect(announcer(page)).not.toContainText(/match/);

    await searchBox(page).fill('');

    await expect(inFrameStatus(page)).toHaveCount(0);
    await expect(page.locator(CARD_LINKS).first()).toHaveAttribute('href', original!);
  });

  test('the search results page keeps the type tabs and has no sort menu', async ({ page }) => {
    await page.goto('/categories/search?q=war');

    for (const name of ['Genres', 'Settings', 'Subjects']) {
      await expect(categoryTabs(page).getByRole('link', { name })).toBeVisible();
    }
    await expect(inFrameStatus(page)).toContainText(/match/);
    await expect(page.locator('details.dropdown')).toHaveCount(0);
    await expect(page.getByTestId('sort-label')).toHaveCount(0);
  });

  test('old genre index URLs redirect to /categories', async ({ page }) => {
    await page.goto('/genres');
    await expect(page).toHaveURL('/categories');

    await page.goto('/genres/filtered-by/location');
    await expect(page).toHaveURL('/categories/settings');
  });

  test('the top nav Categories link reaches the index', async ({ page }) => {
    await page.goto('/');

    // Default desktop viewport: on a phone this link sits in the drawer.
    await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Categories', exact: true }).click();

    await expect(page).toHaveURL('/categories');
  });

  test('the footer links reach both browse pages', async ({ page }) => {
    await page.goto('/');

    await page.getByRole('contentinfo').getByRole('link', { name: 'Categories', exact: true }).click();
    await expect(page).toHaveURL('/categories');

    await page.goto('/');

    await page.getByRole('contentinfo').getByRole('link', { name: 'Origins' }).click();
    await expect(page).toHaveURL('/countries');
  });

  test('the filter pane links out to the browse page', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();
    await page.getByRole('button', { name: /Category/ }).click();

    await page.getByRole('link', { name: /Browse all categories/ }).click();

    await expect(page).toHaveURL('/categories');
  });

  test.describe('on a phone', () => {
    test.use({ viewport: { width: 375, height: 812 } });

    test('the tabs show and the sort menu does not scroll the page sideways', async ({ page }) => {
      await page.goto('/categories');

      for (const name of ['Genres', 'Settings', 'Subjects']) {
        await expect(categoryTabs(page).getByRole('link', { name })).toBeVisible();
      }

      await page.locator('details.dropdown summary').click();
      await expect(page.getByRole('link', { name: 'A–Z' })).toBeVisible();

      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
      );
      expect(overflow).toBeLessThanOrEqual(0);
    });
  });
});
