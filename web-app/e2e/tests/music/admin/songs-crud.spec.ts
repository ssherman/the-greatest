import { test, expect } from '../../../fixtures/auth';

test.describe('Admin Songs', () => {
  test('index page loads with heading and table', async ({ songsPage }) => {
    await songsPage.goto();

    await expect(songsPage.heading).toBeVisible();
    await expect(songsPage.subtitle).toBeVisible();
    await expect(songsPage.table).toBeVisible();
  });

  test('index page shows search input', async ({ songsPage }) => {
    await songsPage.goto();

    await expect(songsPage.searchInput).toBeVisible();
  });

  test('index page shows New Song button', async ({ songsPage }) => {
    await songsPage.goto();

    await expect(songsPage.newSongButton).toBeVisible();
  });

  test('index page shows song rows', async ({ songsPage }) => {
    await songsPage.goto();

    const rowCount = await songsPage.tableRows.count();
    expect(rowCount).toBeGreaterThan(0);
  });

  test('clicking a song navigates to show page', async ({ songsPage }) => {
    await songsPage.goto();
    await songsPage.clickFirstSong();

    await expect(songsPage.page.getByTestId('back-button')).toBeVisible();
    await expect(songsPage.page.getByRole('link', { name: 'Edit' })).toBeVisible();
  });
});
