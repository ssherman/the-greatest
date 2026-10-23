import { test, expect, type Page, type Locator } from '@playwright/test';

// A filtered URL that resolves against the development database. Novels used
// to be the genre here, but the genre cleanup made it a subject, and a subject
// in the genre slot is a 404. Fiction and French are both large and stable.
const FILTERED = '/the-greatest/fiction/books/written-by/french/authors';

const dialog = (page: Page) => page.locator('dialog#books_filter_modal');
const level = (page: Page, key: string) => page.locator(`[data-level='${key}']`);
const scrollRegion = (page: Page) => page.locator('[data-books--filter-target="scroll"]');
const showButton = (page: Page) => dialog(page).getByRole('button', { name: /^Show/ });
const summary = (page: Page, type: string) =>
  page.locator(`[data-books--filter-target='summary'][data-type='${type}']`);
const results = (page: Page, type: string) => page.locator(`turbo-frame#books_filter_results_${type}`);
const chips = (page: Page, type: string) =>
  page.locator(`[data-books--filter-target='chips'][data-type='${type}']`);

// Matches both today's "Filters" and the "Filter books" label Task 7 brings in.
const openPanel = async (page: Page) => {
  await page.getByRole('button', { name: /Filter/ }).click();
  await expect(dialog(page)).toBeVisible();
};

const openPage = async (page: Page, key: string) => {
  await page.locator(`[data-level-target='${key}']`).click();
  await expect(level(page, key)).toBeVisible();
};

const rows = (page: Page, key: string) => level(page, key).locator('[data-filter-row]');

// The old controller moved rows inside a requestAnimationFrame, so a check made
// straight after the click would have passed against the broken code too.
const nextFrames = (page: Page) =>
  page.evaluate(
    () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(null))))
  );

const positionOf = async (page: Page, row: Locator) => {
  const box = await row.boundingBox();
  const scrollTop = await scrollRegion(page).evaluate((el) => el.scrollTop);
  return { y: box!.y, scrollTop };
};

const search = async (page: Page, type: string, term: string) => {
  await level(page, type).getByRole('searchbox').fill(term);
};

const waitForResult = async (page: Page, type: string, text: string) => {
  await expect(
    results(page, type).locator(`[data-filter-row][data-filter-text='${text.toLowerCase()}']`)
  ).toBeVisible();
};

test.describe('Books filters', () => {
  test('the first page lists Genre, Published, Audience, Origin, Subject, Setting', async ({ page }) => {
    await page.goto('/');
    await openPanel(page);

    await expect(level(page, 'root').locator('[data-level-target]')).toHaveText([
      /^\s*Genre/,
      /^\s*Published/,
      /^\s*Audience/,
      /^\s*Origin/,
      /^\s*Subject/,
      /^\s*Setting/,
    ]);
  });

  test('the first page summaries reflect applied filters without opening any page', async ({ page }) => {
    await page.goto(FILTERED);
    await openPanel(page);

    await expect(summary(page, 'genre')).toHaveText('Fiction');
    await expect(summary(page, 'country')).toHaveText('French');
    await expect(summary(page, 'subject')).toHaveText('Any');
  });

  test('no page is fetched until it is opened', async ({ page }) => {
    const paneRequests: string[] = [];
    page.on('request', (r) => {
      if (r.url().includes('/filters/categories')) paneRequests.push(r.url());
    });

    await page.goto('/');
    await page.waitForLoadState('networkidle');
    await openPanel(page);

    expect(paneRequests).toHaveLength(0);

    await openPage(page, 'genre');
    await expect.poll(() => paneRequests.length).toBe(1);
    expect(paneRequests[0]).toContain('/filters/categories?type=genre');
  });

  test('Show without opening a page keeps the filters', async ({ page }) => {
    await page.goto(FILTERED);
    await openPanel(page);

    // The GET to /filters 303s and Turbo follows it with a fetch; the address bar
    // only updates once that settles. Asserting the URL before then would pass on
    // the first poll, before the round trip even starts.
    await showButton(page).click();
    await page.waitForLoadState('networkidle');

    await expect(page).toHaveURL(FILTERED);
    await expect(page.getByTestId('filter-chip')).toHaveCount(2);
  });

  test('Show after opening one page still keeps the other filters', async ({ page }) => {
    await page.goto(FILTERED);
    await openPanel(page);

    await openPage(page, 'genre');
    await rows(page, 'genre').first().waitFor();
    await level(page, 'genre').getByRole('button', { name: 'Back to filters' }).click();

    await showButton(page).click();
    await page.waitForLoadState('networkidle');

    await expect(page).toHaveURL(FILTERED);
    await expect(page.getByTestId('filter-chip')).toHaveCount(2);
  });

  test('ticking a genre does not move it or scroll the list', async ({ page }) => {
    await page.goto('/');
    await openPanel(page);
    await openPage(page, 'genre');

    const row = rows(page, 'genre').nth(20);
    await row.waitFor();
    await row.scrollIntoViewIfNeeded();

    const before = await positionOf(page, row);
    expect(before.scrollTop).toBeGreaterThan(0);

    await row.locator('input[type=checkbox]').check();
    await nextFrames(page);

    await expect(row.locator('input[type=checkbox]')).toBeChecked();
    expect(await positionOf(page, row)).toEqual(before);
  });

  test('ticking a subject search result does not move it or scroll the list', async ({ page }) => {
    await page.goto('/');
    await openPanel(page);
    await openPage(page, 'subject');

    await search(page, 'subject', 'war');
    await waitForResult(page, 'subject', 'war');
    const found = results(page, 'subject').locator('[data-filter-row]');
    expect(await found.count()).toBeGreaterThan(1);

    const row = found.last();
    await row.scrollIntoViewIfNeeded();
    const name = await row.locator('input').getAttribute('data-name');
    const before = await positionOf(page, row);

    await row.locator('input[type=checkbox]').check();
    await nextFrames(page);

    await expect(row.locator('input[type=checkbox]')).toBeChecked();
    expect(await positionOf(page, row)).toEqual(before);
    await expect(chips(page, 'subject').getByRole('button', { name: `Remove ${name}` })).toBeVisible();
  });

  // The old "twin" case: the same subject sits in the popular list and in the
  // search results. Ticking one checks both, in place.
  test('ticking a search result that is also in the popular list checks both without moving either', async ({ page }) => {
    await page.goto('/');
    await openPanel(page);
    await openPage(page, 'subject');

    const popular = level(page, 'subject').locator("[data-books--filter-target='browse'] [data-filter-row]").first();
    await popular.waitFor();
    const name = (await popular.locator('input').getAttribute('data-name'))!;
    const slug = (await popular.locator('input').getAttribute('data-slug'))!;

    await search(page, 'subject', name);
    const hit = results(page, 'subject').locator(`input[data-slug='${slug}']`);
    await expect(hit).toBeVisible();

    const hitRow = results(page, 'subject')
      .locator('[data-filter-row]')
      .filter({ has: page.locator(`input[data-slug='${slug}']`) });
    const hitBefore = await positionOf(page, hitRow);
    const popularBefore = await positionOf(page, popular);

    await hit.check();
    await nextFrames(page);

    await expect(hit).toBeChecked();
    await expect(popular.locator('input')).toBeChecked();
    expect(await positionOf(page, hitRow)).toEqual(hitBefore);
    expect(await positionOf(page, popular)).toEqual(popularBefore);
  });

  test('a ticked search result survives the next search as a chip', async ({ page }) => {
    await page.goto('/');
    await openPanel(page);
    await openPage(page, 'subject');

    await search(page, 'subject', 'war');
    await waitForResult(page, 'subject', 'war crimes');
    const hit = results(page, 'subject').locator("[data-filter-row][data-filter-text='war crimes'] input");
    const slug = (await hit.getAttribute('data-slug'))!;
    await hit.check();

    await search(page, 'subject', 'love');
    await waitForResult(page, 'subject', 'love');
    // Without this the chip assertion below could be satisfied by the result
    // row itself still sitting on the page.
    await expect(results(page, 'subject').locator(`input[data-slug='${slug}']`)).toHaveCount(0);

    await expect(chips(page, 'subject').getByRole('button', { name: 'Remove War Crimes' })).toBeVisible();

    await showButton(page).click();
    await expect(page).toHaveURL(new RegExp(slug));
  });

  test('typing on the Genre page narrows the list without a request', async ({ page }) => {
    await page.goto('/');
    await openPanel(page);
    await openPage(page, 'genre');

    const all = rows(page, 'genre');
    await all.first().waitFor();
    const total = await all.count();

    const requests: string[] = [];
    page.on('request', (r) => {
      if (r.url().includes('/filters/categories')) requests.push(r.url());
    });

    await search(page, 'genre', 'fic');

    const visible = level(page, 'genre').locator('[data-filter-row]:visible');
    await expect.poll(() => visible.count()).toBeLessThan(total);
    expect(await visible.count()).toBeGreaterThan(0);
    const texts = await visible.evaluateAll((els) => els.map((el) => (el as HTMLElement).dataset.filterText));
    expect(texts.every((text) => text!.includes('fic'))).toBe(true);

    // Longer than the search debounce, so a debounced request would have gone.
    await page.waitForTimeout(500);
    expect(requests).toHaveLength(0);
  });

  test('the category cap spans pages and later search results', async ({ page }) => {
    await page.goto('/');
    await openPanel(page);

    await openPage(page, 'genre');
    const genres = rows(page, 'genre').locator('input[type=checkbox]');
    await genres.first().waitFor();
    for (let i = 0; i < 5; i++) await genres.nth(i).check();
    await level(page, 'genre').getByRole('button', { name: 'Back to filters' }).click();

    await openPage(page, 'subject');
    const popular = level(page, 'subject').locator("[data-books--filter-target='browse'] input[type=checkbox]");
    await popular.first().waitFor();
    await popular.first().check();

    await search(page, 'subject', 'war');
    await waitForResult(page, 'subject', 'war');

    const states = await results(page, 'subject')
      .locator('input[type=checkbox]')
      .evaluateAll((els) => els.map((el) => ({ checked: (el as HTMLInputElement).checked, disabled: (el as HTMLInputElement).disabled })));
    const unticked = states.filter((s) => !s.checked);
    expect(unticked.length).toBeGreaterThan(0);
    expect(unticked.every((s) => s.disabled)).toBe(true);
    await expect(page.locator("[data-books--filter-target='capNotice']")).not.toBeEmpty();
  });

  test('the Show button count changes after a tick', async ({ page }) => {
    await page.goto('/');
    await openPanel(page);

    const before = (await showButton(page).textContent())!.trim();
    expect(before).toMatch(/^Show [\d,]+ books?$/);

    await openPage(page, 'genre');
    const first = rows(page, 'genre').locator('input[type=checkbox]').first();
    await first.waitFor();
    await first.check();

    await expect.poll(async () => (await showButton(page).textContent())!.trim()).not.toBe(before);
    await expect(showButton(page)).toHaveText(/^Show [\d,]+ books?$/);
  });

  test('an era fills the year boxes and a single year goes to /of/<year>', async ({ page }) => {
    await page.goto('/');
    await openPanel(page);
    await openPage(page, 'year');

    const since2000 = level(page, 'year').getByRole('button', { name: 'Since 2000' });
    await since2000.click();
    await expect(page.locator('#year_start')).toHaveValue('2000');
    await expect(page.locator('#year_end')).toHaveValue('');
    await expect(since2000).toHaveAttribute('aria-pressed', 'true');

    const single = level(page, 'year').getByRole('button', { name: /^\d{4}$/ }).first();
    const year = (await single.textContent())!.trim();
    await single.click();
    await expect(single).toHaveAttribute('aria-pressed', 'true');
    await expect(since2000).toHaveAttribute('aria-pressed', 'false');

    await showButton(page).click();
    await expect(page).toHaveURL(new RegExp(`/of/${year}$`));
  });

  test('closing restores the applied selection, even after Clear', async ({ page }) => {
    await page.goto(FILTERED);
    await openPanel(page);

    await dialog(page).getByRole('button', { name: 'Clear' }).click();
    await expect(summary(page, 'genre')).toHaveText('Any');
    await expect(summary(page, 'country')).toHaveText('Any');

    await page.keyboard.press('Escape');
    await expect(dialog(page)).toBeHidden();

    await openPanel(page);
    await expect(summary(page, 'genre')).toHaveText('Fiction');
    await expect(summary(page, 'country')).toHaveText('French');

    await showButton(page).click();
    await page.waitForLoadState('networkidle');
    await expect(page).toHaveURL(FILTERED);
  });

  test('closing discards a staged search pick and returns focus to the trigger', async ({ page }) => {
    await page.goto('/');
    await openPanel(page);
    await openPage(page, 'subject');

    await search(page, 'subject', 'war');
    await waitForResult(page, 'subject', 'war crimes');
    await results(page, 'subject').locator("[data-filter-row][data-filter-text='war crimes'] input").check();
    await expect(chips(page, 'subject').getByRole('button')).toHaveCount(1);

    await page.keyboard.press('Escape');
    await expect(dialog(page)).toBeHidden();
    await expect(page.getByRole('button', { name: /Filter/ })).toBeFocused();

    await openPanel(page);
    await expect(summary(page, 'subject')).toHaveText('Any');
    await openPage(page, 'subject');
    await expect(chips(page, 'subject').getByRole('button')).toHaveCount(0);
    await expect(level(page, 'subject').getByRole('searchbox')).toHaveValue('');
    await expect(results(page, 'subject').locator('input')).toHaveCount(0);
  });

  test('pressing Enter in a search box does not submit', async ({ page }) => {
    await page.goto('/');
    await openPanel(page);

    for (const key of ['genre', 'subject']) {
      await openPage(page, key);
      const box = level(page, key).getByRole('searchbox');
      await box.fill('war');
      await box.press('Enter');
      await level(page, key).getByRole('button', { name: 'Back to filters' }).click();
    }

    await page.waitForTimeout(500);
    await expect(page).toHaveURL('/');
    await expect(dialog(page)).toBeVisible();
  });

  test('a search typed before its page finishes loading still runs once it arrives', async ({ page }) => {
    // Delay only the page's own (non-search) load. The search box is
    // server-rendered and usable the moment the page opens, before the results
    // frame it depends on exists; typing inside that window is the case here.
    await page.route('**/filters/categories*', async (route) => {
      const url = new URL(route.request().url());
      if (!url.searchParams.has('q')) {
        await new Promise((resolve) => setTimeout(resolve, 1000));
      }
      await route.continue();
    });

    await page.goto('/');
    await openPanel(page);
    await openPage(page, 'subject');
    await search(page, 'subject', 'war');

    await expect(results(page, 'subject').locator('input').first()).toBeVisible({ timeout: 8000 });
  });

  test('chips on the page remove one filter at a time', async ({ page }) => {
    await page.goto(FILTERED);

    await expect(page.getByTestId('filter-chip')).toHaveCount(2);
    await page.getByTestId('filter-chip').filter({ hasText: 'French' }).getByRole('link').click();

    await expect(page).toHaveURL('/the-greatest/fiction/books');
    await page.getByTestId('filter-chip').filter({ hasText: 'Fiction' }).getByRole('link').click();

    await expect(page).toHaveURL('/');
    await expect(page.getByTestId('filter-chip')).toHaveCount(0);
  });

  test('the heading reflects the active filter', async ({ page }) => {
    await page.goto('/the-greatest/fiction/books');

    await expect(page.getByRole('heading', { level: 1 })).toContainText(/Fiction/i);
  });

  test('an unknown genre slug is a 404', async ({ page }) => {
    const response = await page.goto('/the-greatest/no-such-genre/books');

    expect(response?.status()).toBe(404);
  });

  test('on a phone the footer buttons are visible on every page', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/');
    await openPanel(page);

    const clear = dialog(page).getByRole('button', { name: 'Clear' });
    await expect(clear).toBeInViewport();
    await expect(showButton(page)).toBeInViewport();

    for (const key of ['genre', 'year', 'audience', 'country', 'subject', 'location']) {
      await openPage(page, key);
      if (key !== 'year') {
        await level(page, key).locator("[data-filter-row], [data-testid='filter-pane-empty']").first().waitFor();
      }

      await expect(clear).toBeInViewport();
      await expect(showButton(page)).toBeInViewport();

      await level(page, key).getByRole('button', { name: 'Back to filters' }).click();
    }
  });
});
