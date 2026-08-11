import { test, expect } from '@playwright/test';

const openModal = async (page) => {
  await page.getByRole('button', { name: 'Filters' }).click();
  await expect(page.locator('dialog#books_filter_modal')).toBeVisible();
};

// Every category result carries a type tag, so the tag alone no longer says
// anything about a row. A tag reading Subject or Setting does: FilterFacetsQuery
// .genres only ever returns genre-type rows, so such a row cannot be in the
// browse facet list, which is the structural guarantee two tests below need.
const nonGenreResult = (page) =>
  page
    .locator('turbo-frame#books_filter_results_category label')
    .filter({ has: page.locator('.badge', { hasText: /^(Subject|Setting)$/ }) });

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

  test('the level-1 summary reflects applied filters without opening any pane', async ({ page }) => {
    await page.goto('/the-greatest/novels/books/written-by/french/authors');
    await openModal(page);

    await expect(page.locator("[data-books--filter-target='summary'][data-axis='category']")).toHaveText('Novels');
    await expect(page.locator("[data-books--filter-target='summary'][data-axis='country']")).toHaveText('French');
  });

  test('applying without opening any pane preserves the current filters', async ({ page }) => {
    await page.goto('/the-greatest/novels/books/written-by/french/authors');
    await openModal(page);

    // Asserting the URL is unchanged would pass trivially on the very first
    // poll, before the redirect round trip even starts -- exactly the vacuous
    // pattern this branch's review is about. The GET to /filters 303s, and
    // Turbo's fetch-driven follow of that redirect doesn't complete (and the
    // address bar doesn't update) until the network settles, so waiting for
    // that forces the assertion to observe the real outcome.
    await page.getByRole('button', { name: 'Apply' }).click();
    await page.waitForLoadState('networkidle');

    await expect(page).toHaveURL('/the-greatest/novels/books/written-by/french/authors');
    await expect(page.getByTestId('filter-chip')).toHaveCount(2);
  });

  test('applying after opening only one pane still preserves the other axis', async ({ page }) => {
    await page.goto('/the-greatest/novels/books/written-by/french/authors');
    await openModal(page);

    await page.getByRole('button', { name: /Category/ }).click();
    await page.locator("input[name='category_slugs[]']").first().waitFor();
    await page.getByRole('button', { name: /^‹/ }).click();

    await page.getByRole('button', { name: 'Apply' }).click();
    await page.waitForLoadState('networkidle');

    await expect(page).toHaveURL('/the-greatest/novels/books/written-by/french/authors');
    await expect(page.getByTestId('filter-chip')).toHaveCount(2);
  });

  test('cancelling discards staged selections', async ({ page }) => {
    await page.goto('/');
    await openModal(page);
    await page.getByRole('button', { name: /Category/ }).click();

    // A Subject/Setting row can't be in the browse facet list (see
    // nonGenreResult), so this guarantees the hoist path (no twin to adopt
    // into) rather than relying on search-result order.
    const search = page.getByPlaceholder('Search genres, subjects, settings');
    await search.fill('novels');
    const hit = nonGenreResult(page).first().locator('input');
    await hit.waitFor();
    const slug = await hit.getAttribute('value');
    await hit.check();
    await expect(page.locator(`input[name='category_slugs[]'][value='${slug}']`)).toBeChecked();

    await page.getByRole('button', { name: 'Cancel' }).click();
    await expect(page.locator('dialog#books_filter_modal')).toBeHidden();

    // discard() ends with show("root"), which used to focus a button inside the
    // dialog that just closed -- DaisyUI keeps it focusable through its fade-out,
    // so that overrode the browser's restoration and stranded the user at <body>.
    await expect(page.getByRole('button', { name: 'Filters' })).toBeFocused();

    await openModal(page);
    await page.getByRole('button', { name: /Category/ }).click();

    // A naive form.reset() would leave the hoisted row parked -- unchecked but
    // still present -- in the selected container. It must be gone entirely.
    await expect(page.locator(`input[name='category_slugs[]'][value='${slug}']`)).toHaveCount(0);
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
    await page.locator("input[name='category_slugs[]'][value='fiction']").check();
    await page.getByRole('button', { name: /^‹/ }).click();
    await page.getByRole('button', { name: /Origin/ }).click();
    await page.locator("input[name='country_slugs[]'][value='french']").check();
    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page).toHaveURL('/the-greatest/fiction/books/written-by/french/authors');
    await expect(page.getByTestId('filter-chip')).toHaveCount(2);
  });

  test('search is scoped to its own axis', async ({ page }) => {
    await page.goto('/');
    await openModal(page);

    await page.getByRole('button', { name: /Category/ }).click();
    const search = page.getByPlaceholder('Search genres, subjects, settings');

    await search.fill('novel');
    await expect(page.locator("turbo-frame#books_filter_results_category input").first()).toBeVisible();

    // "peruvian" matches only the Peruvian country, never a category name --
    // verified against the dev dataset -- so this proves scoping rather than
    // merely proving the debounce fired.
    await search.fill('peruvian');
    await expect(page.locator("turbo-frame#books_filter_results_category input")).toHaveCount(0);
  });

  test('every category search result is tagged with its type, genres included', async ({ page }) => {
    await page.goto('/');
    await openModal(page);
    await page.getByRole('button', { name: /Category/ }).click();

    const search = page.getByPlaceholder('Search genres, subjects, settings');
    const rows = page.locator('turbo-frame#books_filter_results_category label');
    const tagged = (text: RegExp) => rows.filter({ has: page.locator('.badge', { hasText: text }) });

    // Genre rows carried no tag at all before this change, so a search spanning
    // all three types gave the user no way to tell a genre from a setting.
    await search.fill('novels');
    await expect(rows.first()).toBeVisible();
    await expect(tagged(/^Genre$/).first()).toBeVisible();

    // A location is tagged "Setting" -- friendlier than the enum's own word for
    // a place a book is set in.
    await search.fill('new york');
    await expect(tagged(/^Setting$/).first()).toBeVisible();

    // Untagged rows would mean a type is slipping through unlabelled.
    await expect(rows).toHaveCount(await tagged(/./).count());
  });

  test('search results stack one per row rather than flowing into columns', async ({ page }) => {
    await page.goto('/');
    await openModal(page);

    await page.getByRole('button', { name: /Category/ }).click();
    await page.getByPlaceholder('Search genres, subjects, settings').fill('new york');

    const rows = page.locator("turbo-frame#books_filter_results_category label");
    await expect(rows.first()).toBeVisible();
    expect(await rows.count()).toBeGreaterThan(1);

    // DaisyUI's .label is inline-flex and turbo-frame has no default display, so
    // without a flex-col on the frame these wrap into unreadable columns.
    const tops = await rows.evaluateAll((els) => els.map((el) => el.getBoundingClientRect().top));
    expect(new Set(tops).size).toBe(tops.length);
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

    // Picking a Subject/Setting row (see nonGenreResult), rather than relying
    // on search-result order, guarantees this test exercises the move path
    // regardless of how facet ranking shifts.
    const search = page.getByPlaceholder('Search genres, subjects, settings');
    await search.fill('novels');
    const hit = nonGenreResult(page).first().locator('input');
    await hit.waitFor();
    const slug = await hit.getAttribute('value');

    await expect(page.locator(`[data-books--filter-target='browse'][data-axis='category'] input[value='${slug}']`)).toHaveCount(0);

    await hit.check();
    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page.getByTestId('filter-chip')).toHaveCount(1);

    await openModal(page);
    await page.getByRole('button', { name: /Category/ }).click();
    const staged = page.locator(`input[name='category_slugs[]'][value='${slug}']`);
    await staged.waitFor();
    await expect(staged).toBeVisible();
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

  test('a search typed before its pane finishes loading still runs once the pane arrives', async ({ page }) => {
    // Delay only the pane's own (non-search) load. The search input is
    // server-rendered and usable the instant the modal opens, well before the
    // results frame it depends on exists -- typing inside that window is the
    // defect under test. Letting the follow-up search request through
    // immediately keeps the assertion's timing budget tight.
    await page.route('**/filters/categories*', async (route) => {
      const url = new URL(route.request().url());
      if (!url.searchParams.has('q')) {
        await new Promise((resolve) => setTimeout(resolve, 1000));
      }
      await route.continue();
    });

    await page.goto('/');
    await openModal(page);
    await page.getByRole('button', { name: /Category/ }).click();

    const search = page.getByPlaceholder('Search genres, subjects, settings');
    await search.fill('novel');

    await expect(page.locator("turbo-frame#books_filter_results_category input").first()).toBeVisible({ timeout: 8000 });
  });

  test('selection caps are reapplied to newly rendered search results', async ({ page }) => {
    await page.goto('/');
    await openModal(page);
    await page.getByRole('button', { name: /Category/ }).click();

    const browseBoxes = page.locator(
      "[data-books--filter-target='browse'][data-axis='category'] input[type='checkbox']"
    );
    await browseBoxes.first().waitFor();
    for (let i = 0; i < 6; i++) {
      await browseBoxes.nth(i).check();
    }

    // "new york" is a location-type category -- FilterFacetsQuery.genres only
    // ever returns genre-type rows -- so it cannot be among the 6 checked
    // above. Any disabled state on its results can only come from the cap
    // being reapplied to the search response itself.
    await page.getByPlaceholder('Search genres, subjects, settings').fill('new york');

    const resultsInputs = page.locator("turbo-frame#books_filter_results_category input");
    await expect(resultsInputs.first()).toBeVisible();
    const disabledStates = await resultsInputs.evaluateAll((els) =>
      els.map((el) => (el as HTMLInputElement).disabled)
    );
    expect(disabledStates.length).toBeGreaterThan(0);
    expect(disabledStates.every(Boolean)).toBe(true);
  });
});
