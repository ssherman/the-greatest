import { test, expect } from '@playwright/test';

// Signed-in only: the saved-search write flow requires an owner. This file
// lives under tests/books/account/ so the books-account project (which
// carries a signed-in storage state) picks it up, rather than the anonymous
// books project.
test.describe('Saved search write flow', () => {
  test('a user can create, edit and delete a saved search', async ({ page }) => {
    await page.goto('/searches');
    await page.getByRole('link', { name: 'New Saved Search' }).click();

    const name = `E2E search ${Date.now()}`;
    await page.getByLabel('Name').fill(name);
    await page.getByLabel('Type').selectOption({ label: 'Fiction' });
    await page.getByLabel('Ranking').selectOption({ label: 'Ranked books only' });

    // The category, language and country pickers all share the same
    // Stimulus controller -- exercising one of each is what proves the
    // language and country boxes actually got the picker treatment rather
    // than staying broken <select multiple> boxes.
    const included = page.locator('[data-saved-search-picker-name-value*="included_category_ids"]');
    await included.getByPlaceholder('Search genres, subjects, settings').fill('fict');
    await included.locator('[data-action="saved-search-picker#add"]').first().click();
    await expect(included.locator('[data-chip]')).toHaveCount(1);

    const includedLanguage = page.locator('[data-saved-search-picker-name-value*="included_language_ids"]');
    await includedLanguage.getByPlaceholder('Search languages').fill('engl');
    await includedLanguage.locator('[data-action="saved-search-picker#add"]').first().click();
    await expect(includedLanguage.locator('[data-chip]')).toHaveCount(1);

    await page.getByRole('button', { name: 'Create search' }).click();

    await expect(page.getByRole('heading', { level: 1 })).toContainText(name);

    // Edit: the stored chips must come back server-rendered.
    await page.getByRole('link', { name: 'Edit' }).click();
    await expect(page.locator('[data-saved-search-picker-name-value*="included_category_ids"] [data-chip]'))
      .toHaveCount(1);
    await expect(page.locator('[data-saved-search-picker-name-value*="included_language_ids"] [data-chip]'))
      .toHaveCount(1);

    await page.getByLabel('Name').fill(`${name} (edited)`);
    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByRole('heading', { level: 1 })).toContainText('(edited)');

    // Delete, and confirm it is gone from the index rather than merely redirected.
    page.on('dialog', (dialog) => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();

    await expect(page).toHaveURL('/searches');
    await expect(page.getByText(`${name} (edited)`)).toHaveCount(0);
  });

  test('removing every category chip clears the stored ids', async ({ page }) => {
    // What makes this work is that the controller REPLACES the whole criteria
    // hash on save, so a key nobody posted is simply absent -- not the hidden
    // blank field before the picker, which this spec never checks and which
    // only makes the cleared key explicit in the request. Do not treat a green
    // run here as evidence that the hidden field is load-bearing. Type is set
    // too, so removing the chip leaves criteria as {"book_type"=>0} rather
    // than {} -- SavedSearch validates :criteria, presence: true, and an
    // empty hash is blank, which would 422 the update and mask whether the
    // id array itself cleared.
    await page.goto('/searches');
    await page.getByRole('link', { name: 'New Saved Search' }).click();

    const name = `E2E clear ${Date.now()}`;
    await page.getByLabel('Name').fill(name);
    await page.getByLabel('Type').selectOption({ label: 'Fiction' });
    const included = page.locator('[data-saved-search-picker-name-value*="included_category_ids"]');
    await included.getByPlaceholder('Search genres, subjects, settings').fill('fict');
    await included.locator('[data-action="saved-search-picker#add"]').first().click();
    // Same settle as the first spec: waiting for the chip to actually land
    // in the DOM before submitting avoids a race where the form serializes
    // before the picker's client-side state (or, empirically, the Type
    // select's value) has settled.
    await expect(included.locator('[data-chip]')).toHaveCount(1);
    await page.getByRole('button', { name: 'Create search' }).click();

    await page.getByRole('link', { name: 'Edit' }).click();
    // Turbo intercepts this link and navigates via fetch, so the URL and DOM
    // update asynchronously after the click resolves. The assertion below
    // wants a COUNT OF 0, which the pre-navigation page (still the show page,
    // which also has no [data-chip] elements) satisfies just as well as the
    // real settled edit page -- an auto-retrying expect(...).toHaveCount(0)
    // can resolve "successfully" against that stale snapshot before Turbo
    // ever finishes. Waiting for the URL first removes that false positive.
    await page.waitForURL(/\/edit$/);
    await page.locator('[data-chip] button').first().click();
    await page.getByRole('button', { name: 'Save changes' }).click();

    await page.getByRole('link', { name: 'Edit' }).click();
    await page.waitForURL(/\/edit$/);
    await expect(page.locator('[data-saved-search-picker-name-value*="included_category_ids"] [data-chip]'))
      .toHaveCount(0);
    // The surviving criterion proves this cleared just the category ids
    // rather than the update silently failing or dropping everything.
    await expect(page.getByLabel('Type')).toHaveValue('0');

    // Clean up: this runs against the real dev database.
    await page.getByRole('link', { name: 'Cancel' }).click();
    page.on('dialog', (dialog) => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();
    await expect(page).toHaveURL('/searches');
  });

  test('a stale category search response never clobbers a fresher one', async ({ page }) => {
    // Delay only the response to the query that gets superseded. Letting the
    // fresh query's own response through immediately means it has plenty of
    // time to render before the stale one finally lands -- if the controller
    // applies whichever response arrives last rather than whichever query is
    // still current, the fresh results get wiped out from underneath a box
    // that no longer even reads that query.
    await page.route('**/searches/categories*', async (route) => {
      const url = new URL(route.request().url());
      if (url.searchParams.get('q') === 'zzznomatch') {
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
      await route.continue();
    });

    await page.goto('/searches');
    await page.getByRole('link', { name: 'New Saved Search' }).click();

    const included = page.locator('[data-saved-search-picker-name-value*="included_category_ids"]');
    const search = included.getByPlaceholder('Search genres, subjects, settings');
    const results = included.locator('[data-action="saved-search-picker#add"]');

    const staleRequest = page.waitForRequest(
      (req) => req.url().includes('/searches/categories') && new URL(req.url()).searchParams.get('q') === 'zzznomatch'
    );
    await search.fill('zzznomatch');
    await staleRequest; // the debounce fired; the (delayed) fetch is now in flight

    await search.fill('fict');
    await expect(results.first()).toBeVisible();
    const freshCount = await results.count();
    expect(freshCount).toBeGreaterThan(0);

    // Give the stale, delayed (empty-result) response time to land. If it
    // clobbers the box, the fresh results disappear from underneath it.
    await page.waitForTimeout(2500);
    await expect(results).toHaveCount(freshCount);
  });

  test('typing into a picker does not push the rest of the form down the page', async ({ page }) => {
    // The bug: the results panel used to render in-flow (a plain block
    // element), so with results showing it pushed everything below it --
    // the Category matching select, the Create search button -- down the
    // page. It must float over the page instead. Category matching sits
    // right after the picker block, so it is the most sensitive tripwire;
    // the Create search button (further down, outside the card) is checked
    // too so a fix that only floats the last picker's panel doesn't pass.
    //
    // Document-relative Y (getBoundingClientRect().top + scrollY), not
    // Playwright's boundingBox(): filling the input auto-scrolls it into
    // view, which shifts every viewport-relative box on the page even when
    // nothing in the DOM moved, making boundingBox() compare apples to
    // oranges here.
    const docY = (locator: import('@playwright/test').Locator) =>
      locator.evaluate((el) => el.getBoundingClientRect().top + window.scrollY);

    await page.goto('/searches');
    await page.getByRole('link', { name: 'New Saved Search' }).click();

    const categoryMatchSelect = page.getByLabel('Category matching');
    const createButton = page.getByRole('button', { name: 'Create search' });
    const selectBefore = await docY(categoryMatchSelect);
    const buttonBefore = await docY(createButton);

    const included = page.locator('[data-saved-search-picker-name-value*="included_category_ids"]');
    await included.getByPlaceholder('Search genres, subjects, settings').fill('fict');
    await expect(included.locator('[data-action="saved-search-picker#add"]').first()).toBeVisible();

    expect(await docY(categoryMatchSelect)).toBe(selectBefore);
    expect(await docY(createButton)).toBe(buttonBefore);
  });

  test('clearing the category search box stays empty even after a delayed response lands', async ({ page }) => {
    await page.route('**/searches/categories*', async (route) => {
      const url = new URL(route.request().url());
      if (url.searchParams.get('q') === 'fict') {
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
      await route.continue();
    });

    await page.goto('/searches');
    await page.getByRole('link', { name: 'New Saved Search' }).click();

    const included = page.locator('[data-saved-search-picker-name-value*="included_category_ids"]');
    const search = included.getByPlaceholder('Search genres, subjects, settings');
    const results = included.locator('[data-action="saved-search-picker#add"]');

    const delayedRequest = page.waitForRequest(
      (req) => req.url().includes('/searches/categories') && new URL(req.url()).searchParams.get('q') === 'fict'
    );
    await search.fill('fict');
    await delayedRequest; // the debounce fired; the (delayed) fetch is now in flight

    await search.fill('');
    await expect(results).toHaveCount(0);

    // Give the delayed response -- for a query the box no longer holds --
    // time to land. It must not repopulate an empty box.
    await page.waitForTimeout(2500);
    await expect(results).toHaveCount(0);
  });
});
