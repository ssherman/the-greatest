import { test, expect, type Page } from '@playwright/test';

// A real book on the dev database with no migrated reviews, like reviews-write.spec.ts.
const BOOK_TITLE = 'Headlong Hall';
const BOOK_PATH = '/book/headlong-hall';

async function untickEveryList(page: Page) {
  await page.goto(BOOK_PATH);
  const card = page.locator('[data-listable-type="Books::Book"]').first();
  await card.getByRole('button', { name: /Add to list|On \d+ list/i }).click();
  const modal = page.locator('#user_list_modal');
  await expect(modal).toBeVisible();
  for (const box of await modal.getByRole('checkbox').all()) {
    if (await box.isChecked()) {
      await box.uncheck();
      await expect(box).not.toBeChecked();
    }
  }
  await page.keyboard.press('Escape');
}

async function removeReview(page: Page) {
  await page.goto(BOOK_PATH);
  await page.getByTestId('review-widget-label').click();
  await expect(page.locator('#review_modal')).toBeVisible();
  const remove = page.getByTestId('review-remove');
  if (await remove.isVisible()) {
    await remove.click();
    await expect(page.locator('#review_modal')).not.toBeVisible();
  } else {
    await page.locator('#review_modal').press('Escape');
  }
}

async function resetSettings(page: Page) {
  await page.goto('/recommendations/settings');
  // The results side panel and step 4 carry the reset button; settings does not, so go via step 4.
  await page.goto('/recommendations/wizard/4');
  const reset = page.getByTestId('reset-button');
  if (await reset.isVisible()) {
    await reset.click();
    await expect(page).toHaveURL(/\/recommendations\/wizard\/1$/);
  }
}

test.describe.configure({ mode: 'serial' });

test.describe('Recommendations, as a member', () => {
  test.beforeAll(async ({ browser }) => {
    const page = await browser.newPage();
    page.on('dialog', (d) => d.accept());
    await untickEveryList(page);
    await removeReview(page);
    await page.close();
  });

  test.afterAll(async ({ browser }) => {
    const page = await browser.newPage();
    page.on('dialog', (d) => d.accept());
    await resetSettings(page);
    await removeReview(page);
    await untickEveryList(page);
    await page.close();
  });

  test.beforeEach(async ({ page }) => {
    page.on('dialog', (d) => d.accept());
  });

  test('step 1: search for a book and add it to favorites', async ({ page }) => {
    await page.goto('/recommendations/wizard/1');
    await page.getByTestId('wizard-search').getByRole('searchbox').fill(BOOK_TITLE);
    await page.getByTestId('wizard-search').getByRole('button', { name: 'Find a book' }).click();
    const results = page.getByTestId('wizard-search-results');
    await expect(results).toBeVisible();
    const card = results.locator('[data-listable-type="Books::Book"]').first();
    await card.getByRole('button', { name: /Add to list/i }).click();
    const modal = page.locator('#user_list_modal');
    await expect(modal).toBeVisible();
    const favorites = modal.getByRole('checkbox', { name: /favorite/i }).first();
    await favorites.check();
    await expect(favorites).toBeChecked();
    await page.keyboard.press('Escape');

    await page.reload();
    await expect(page.getByTestId('favorites-list')).toContainText(BOOK_TITLE);
  });

  test('step 3: rate the favorite', async ({ page }) => {
    await page.goto('/recommendations/wizard/3');
    // Headlong Hall is a favorite, not a read book, so it is not in the unrated list;
    // add it to the read list from the book page first so step 3 has a row to rate.
    await page.goto(BOOK_PATH);
    const card = page.locator('[data-listable-type="Books::Book"]').first();
    await card.getByRole('button', { name: /Add to list|On \d+ list/i }).click();
    const modal = page.locator('#user_list_modal');
    const read = modal.getByRole('checkbox', { name: /^read$|books i.ve read|have read/i }).first();
    await read.check();
    await expect(read).toBeChecked();
    await page.keyboard.press('Escape');

    await page.goto('/recommendations/wizard/3');
    const row = page.getByTestId('unrated-list').locator('[data-testid="wizard-book-row"]', { hasText: BOOK_TITLE });
    await row.getByTestId('review-widget-label').click();
    await expect(page.locator('#review_modal')).toBeVisible();
    await page.getByTestId('review-star-button').nth(3).click();
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.locator('#review_modal')).not.toBeVisible();

    await page.reload();
    await expect(page.getByTestId('rated-list')).toContainText(BOOK_TITLE);
  });

  test('step 4: save deep cuts and land on the results', async ({ page }) => {
    await page.goto('/recommendations/wizard/4');
    await page.getByLabel('Deep cuts').check();
    await page.getByTestId('settings-save').click();
    await expect(page).toHaveURL(/\/recommendations$/);
    await expect(page.getByTestId('recommendations-grid')).toBeVisible();
    await expect(page.getByTestId('recommendation').first()).toBeVisible();
    await expect(page.getByTestId('recommendation-reason').first()).not.toBeEmpty();
    await expect(page.getByTestId('member-pitch')).toHaveCount(0);
    await expect(page.locator('aside')).toContainText('Deep cuts');
  });

  test('the settings page is editable for a member', async ({ page }) => {
    await page.goto('/recommendations/settings');
    await expect(page.getByTestId('settings-save')).toBeVisible();
    await expect(page.locator('[data-testid="settings-fields"][disabled]')).toHaveCount(0);
    await expect(page.getByLabel('Deep cuts')).toBeChecked();
  });
});
