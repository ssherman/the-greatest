import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin Dashboard', () => {
  test('displays welcome heading and subtitle', async ({ gamesDashboardPage }) => {
    await gamesDashboardPage.goto();

    await expect(gamesDashboardPage.heading).toBeVisible();
    await expect(gamesDashboardPage.subtitle).toBeVisible();
  });

  test('displays stat cards with numeric counts', async ({ gamesDashboardPage }) => {
    await gamesDashboardPage.goto();

    await expect(gamesDashboardPage.totalGamesStat).toBeVisible();
    await expect(gamesDashboardPage.totalCompaniesStat).toBeVisible();
    await expect(gamesDashboardPage.totalPlatformsStat).toBeVisible();
    await expect(gamesDashboardPage.totalSeriesStat).toBeVisible();

    // Verify stat values are numeric
    const gamesCount = await gamesDashboardPage.getStatValue('stat-card-games');
    expect(Number(gamesCount.replace(/,/g, ''))).toBeGreaterThanOrEqual(0);

    const companiesCount = await gamesDashboardPage.getStatValue('stat-card-companies');
    expect(Number(companiesCount.replace(/,/g, ''))).toBeGreaterThanOrEqual(0);
  });

  test('displays quick link cards', async ({ gamesDashboardPage }) => {
    await gamesDashboardPage.goto();

    await expect(gamesDashboardPage.gamesCard).toBeVisible();
    await expect(gamesDashboardPage.companiesCard).toBeVisible();
    await expect(gamesDashboardPage.platformsCard).toBeVisible();
  });

  test('displays recently added games section', async ({ gamesDashboardPage }) => {
    await gamesDashboardPage.goto();

    await expect(gamesDashboardPage.recentGamesHeading).toBeVisible();
  });
});
