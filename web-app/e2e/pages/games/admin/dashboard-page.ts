import { type Page, type Locator } from '@playwright/test';

export class GamesDashboardPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly subtitle: Locator;
  readonly totalGamesStat: Locator;
  readonly totalCompaniesStat: Locator;
  readonly totalPlatformsStat: Locator;
  readonly totalSeriesStat: Locator;
  readonly gamesCard: Locator;
  readonly companiesCard: Locator;
  readonly platformsCard: Locator;
  readonly recentGamesHeading: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'Welcome to Games Admin' });
    this.subtitle = page.getByText('Manage games, companies, platforms, and more');
    this.totalGamesStat = page.getByTestId('stat-card-games');
    this.totalCompaniesStat = page.getByTestId('stat-card-companies');
    this.totalPlatformsStat = page.getByTestId('stat-card-platforms');
    this.totalSeriesStat = page.getByTestId('stat-card-series');
    this.gamesCard = page.locator('.card', { hasText: 'Manage video games' });
    this.companiesCard = page.locator('.card', { hasText: 'Manage game developers' });
    this.platformsCard = page.locator('.card', { hasText: 'Manage gaming platforms' });
    this.recentGamesHeading = page.getByRole('heading', { name: 'Recently Added Games' });
  }

  async goto() {
    await this.page.goto('/admin');
  }

  async getStatValue(testId: string): Promise<string> {
    const stat = this.page.getByTestId(testId);
    return stat.locator('.stat-value').innerText();
  }
}
