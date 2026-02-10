import { test as base } from '@playwright/test';
import { GamesDashboardPage } from '../pages/games/admin/dashboard-page';
import { GamesPage } from '../pages/games/admin/games-page';
import { CompaniesPage } from '../pages/games/admin/companies-page';
import { PlatformsPage } from '../pages/games/admin/platforms-page';
import { SeriesPage } from '../pages/games/admin/series-page';

type GamesFixtures = {
  gamesDashboardPage: GamesDashboardPage;
  gamesPage: GamesPage;
  companiesPage: CompaniesPage;
  platformsPage: PlatformsPage;
  seriesPage: SeriesPage;
};

export const test = base.extend<GamesFixtures>({
  gamesDashboardPage: async ({ page }, use) => {
    await use(new GamesDashboardPage(page));
  },
  gamesPage: async ({ page }, use) => {
    await use(new GamesPage(page));
  },
  companiesPage: async ({ page }, use) => {
    await use(new CompaniesPage(page));
  },
  platformsPage: async ({ page }, use) => {
    await use(new PlatformsPage(page));
  },
  seriesPage: async ({ page }, use) => {
    await use(new SeriesPage(page));
  },
});

export { expect } from '@playwright/test';
