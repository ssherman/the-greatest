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

    // The category picker is the only field needing a round trip.
    const included = page.locator('[data-saved-search-picker-name-value*="included_category_ids"]');
    await included.getByPlaceholder('Search genres, subjects, settings').fill('fict');
    await included.locator('[data-action="saved-search-picker#add"]').first().click();
    await expect(included.locator('[data-chip]')).toHaveCount(1);

    await page.getByRole('button', { name: 'Create search' }).click();

    await expect(page.getByRole('heading', { level: 1 })).toContainText(name);

    // Edit: the stored chip must come back server-rendered.
    await page.getByRole('link', { name: 'Edit' }).click();
    await expect(page.locator('[data-saved-search-picker-name-value*="included_category_ids"] [data-chip]'))
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
    // The hidden blank field is what makes this possible; without it the form
    // posts no key at all and the stored ids survive the save. Type is set
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
});
