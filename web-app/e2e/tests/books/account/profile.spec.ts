import { test, expect, type Page } from '@playwright/test';

// Ticks or unticks the Favorites row of the add-to-list modal on the first card
// of the home grid, waiting for the request so a following navigation cannot race it.
async function setFavorite(page: Page, on: boolean): Promise<void> {
  await page.goto('/');
  const card = page.locator('[data-listable-type="Books::Book"]').first();
  await card.getByRole('button').first().click();
  const modal = page.locator('#user_list_modal');
  await expect(modal).toBeVisible();
  const row = modal.getByRole('checkbox', { name: /My Favorite Books/ });
  if ((await row.isChecked()) === on) {
    await page.keyboard.press('Escape');
    return;
  }
  const done = page.waitForResponse(
    (r) => r.request().method() === (on ? 'POST' : 'DELETE') && r.url().includes('/items'),
  );
  await (on ? row.check() : row.uncheck());
  await done;
  await page.keyboard.press('Escape');
}

test.describe('Books reader profile', () => {
  test('opens from the My Books menu with the heading, stat row and Favorites card', async ({ page }) => {
    await page.goto('/');
    const myBooks = page.locator('.navbar-center #navbar_my_books');
    await myBooks.locator('summary').click();
    await myBooks.getByRole('link', { name: 'Profile', exact: true }).click();

    await expect(page).toHaveURL(/\/my\/profile$/);
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
    await expect(page.getByTestId('profile-stats')).toBeVisible();
    await expect(page.getByTestId('stat-books-read')).toBeVisible();
    // The E2E accounts' lists are emptied on every run, so Favorites shows either
    // the shelf or the owner's prompt depending on what ran before this.
    await expect(page.getByTestId(/^profile-favorites(-prompt)?$/)).toBeVisible();
  });

  test('a Favorites shelf links through See all to the list page', async ({ page }) => {
    await setFavorite(page, true);
    try {
      await page.goto('/my/profile');
      const card = page.getByTestId('profile-favorites');
      await expect(card.getByTestId('profile-book')).not.toHaveCount(0);
      await card.getByRole('link', { name: /^See all/ }).click();
      await expect(page).toHaveURL(/\/my\/lists\//);
      await expect(page.getByRole('heading', { name: 'My Favorite Books', level: 1 })).toBeVisible();
    } finally {
      await setFavorite(page, false);
    }
  });

  test('the page does not scroll sideways on a phone', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/my/profile');
    await expect(page.getByTestId('profile-stats')).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });

  test('sharing: a public page shows the chosen sections, and going private makes it a 404', async ({ page, browser }) => {
    await page.goto('/my/profile');
    await expect(page.getByTestId('profile-status')).toHaveText(/private/i);
    await page.getByRole('link', { name: 'Share settings' }).click();
    await expect(page).toHaveURL(/\/my\/profile\/settings$/);

    await page.getByLabel('Make my profile public').check();
    await page.getByLabel('Display name').fill('E2E Sharing Reader');
    await page.getByLabel('Reading stats').check();
    await page.getByLabel('Highest rated').check();
    await page.getByRole('button', { name: 'Save settings' }).click();
    await expect(page.getByTestId('profile-settings-notice')).toBeVisible();

    const publicUrl = await page.getByTestId('profile-public-url').inputValue();
    expect(publicUrl).toMatch(/\/profiles\/\d+$/);

    const visitor = await browser.newContext({ storageState: undefined, ignoreHTTPSErrors: true });
    try {
      const guest = await visitor.newPage();
      const shown = await guest.goto(publicUrl);
      expect(shown?.status()).toBe(200);
      await expect(guest.getByRole('heading', { name: 'E2E Sharing Reader', level: 1 })).toBeVisible();
      await expect(guest.getByTestId('profile-stats')).toBeVisible();
      await expect(guest.getByTestId('profile-top-rated')).toBeVisible();
      await expect(guest.getByTestId('profile-reviews')).toHaveCount(0);
      await expect(guest.getByTestId('profile-reviews-prompt')).toHaveCount(0);
      await expect(guest.locator('meta[name="robots"]')).toHaveAttribute('content', /noindex/);

      // The owner's preview shows the same page and the banner only the owner sees.
      await page.goto('/my/profile/preview');
      await expect(page.getByTestId('profile-preview-banner')).toBeVisible();
      await expect(page.getByTestId('profile-stats')).toBeVisible();

      await page.goto('/my/profile/settings');
      await page.getByLabel('Make my profile public').uncheck();
      await page.getByRole('button', { name: 'Save settings' }).click();
      await expect(page.getByTestId('profile-settings-notice')).toBeVisible();

      const gone = await guest.goto(publicUrl);
      expect(gone?.status()).toBe(404);
    } finally {
      await visitor.close();
    }
  });
});
