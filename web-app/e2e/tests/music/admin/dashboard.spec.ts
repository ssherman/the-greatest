import { test, expect } from '../../../fixtures/auth';

test.describe('Admin Dashboard', () => {
  test('displays welcome heading and subtitle', async ({ dashboardPage }) => {
    await dashboardPage.goto();

    await expect(dashboardPage.heading).toBeVisible();
    await expect(dashboardPage.subtitle).toBeVisible();
  });

  test('displays stat cards with numeric counts', async ({ dashboardPage }) => {
    await dashboardPage.goto();

    await expect(dashboardPage.totalArtistsStat).toBeVisible();
    await expect(dashboardPage.totalAlbumsStat).toBeVisible();
    await expect(dashboardPage.totalSongsStat).toBeVisible();
    await expect(dashboardPage.categoriesStat).toBeVisible();

    // Verify stat values are numeric
    const artistCount = await dashboardPage.getStatValue('Total Artists');
    expect(Number(artistCount.replace(/,/g, ''))).toBeGreaterThan(0);

    const albumCount = await dashboardPage.getStatValue('Total Albums');
    expect(Number(albumCount.replace(/,/g, ''))).toBeGreaterThanOrEqual(0);

    const songCount = await dashboardPage.getStatValue('Total Songs');
    expect(Number(songCount.replace(/,/g, ''))).toBeGreaterThanOrEqual(0);
  });

  test('displays quick link cards', async ({ dashboardPage }) => {
    await dashboardPage.goto();

    await expect(dashboardPage.artistsCard).toBeVisible();
    await expect(dashboardPage.albumsCard).toBeVisible();
    await expect(dashboardPage.songsCard).toBeVisible();
  });

  test('displays recently added artists section', async ({ dashboardPage }) => {
    await dashboardPage.goto();

    await expect(dashboardPage.recentArtistsHeading).toBeVisible();
  });
});
