import { test, expect } from '@playwright/test';

// /rankings is one shared component across books, music and games
// (Rankings::PageComponent), so these headings are the same on every site and
// the stat labels differ only in the media noun.
test.describe('Games Rankings Page', () => {
  test('rankings page loads successfully', async ({ page }) => {
    await page.goto('/rankings');

    await expect(page.getByRole('heading', { name: 'How Our Rankings Work' })).toBeVisible();
  });

  test('rankings page explains how a list is weighted', async ({ page }) => {
    await page.goto('/rankings');

    await expect(page.getByRole('heading', { name: 'How a list earns its weight' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'What we adjust for' })).toBeVisible();
  });

  test('rankings page displays stats section', async ({ page }) => {
    await page.goto('/rankings');

    // Scoped to .stats: "Typical list length" is also a row header in the
    // configuration facts table further down the page.
    const stats = page.locator('.stats');

    await expect(stats.getByText('Lists we count')).toBeVisible();
    await expect(stats.getByText('Ranked games')).toBeVisible();
    await expect(stats.getByText('Typical list length')).toBeVisible();
  });

  test('rankings page states the recency adjustment the right way round', async ({ page }) => {
    await page.goto('/rankings');

    // The direction is the whole point of this section: a release from the same
    // year as the list takes the maximum cut, and classics take none. The old
    // hand-written page claimed the opposite.
    await expect(page.getByRole('heading', { name: 'Correcting for recency' })).toBeVisible();
    await expect(page.getByText(/same year the list came out/i)).toBeVisible();
    await expect(page.getByText(/Classics are not penalized/i)).toBeVisible();
  });

  test('rankings page displays open source links', async ({ page }) => {
    await page.goto('/rankings');

    await expect(page.getByRole('link', { name: /weighted_list_rank/ }).first()).toBeVisible();
    await expect(page.getByRole('link', { name: /full source/ }).first()).toBeVisible();
  });

  test('rankings page links to Discord', async ({ page }) => {
    await page.goto('/rankings');

    await expect(page.getByRole('link', { name: 'Join us on Discord' })).toBeVisible();
  });

  test('the western tilt section is books-only', async ({ page }) => {
    await page.goto('/rankings');

    // percentage_western is implemented for books lists alone and the Global
    // Canon is a books page, so promising that correction here would be a lie.
    await expect(page.getByRole('heading', { name: /skews western/i })).toHaveCount(0);
  });
});
