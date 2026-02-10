import { type Page, type Locator } from '@playwright/test';

export class DashboardPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly subtitle: Locator;
  readonly totalArtistsStat: Locator;
  readonly totalAlbumsStat: Locator;
  readonly totalSongsStat: Locator;
  readonly categoriesStat: Locator;
  readonly artistsCard: Locator;
  readonly albumsCard: Locator;
  readonly songsCard: Locator;
  readonly recentArtistsHeading: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'Welcome to Music Admin' });
    this.subtitle = page.getByText('Manage artists, albums, songs, and more');
    this.totalArtistsStat = page.locator('.stat-title', { hasText: 'Total Artists' });
    this.totalAlbumsStat = page.locator('.stat-title', { hasText: 'Total Albums' });
    this.totalSongsStat = page.locator('.stat-title', { hasText: 'Total Songs' });
    this.categoriesStat = page.locator('.stat-title', { hasText: 'Categories' });
    this.artistsCard = page.locator('.card', { hasText: 'Manage artists and bands' });
    this.albumsCard = page.locator('.card', { hasText: 'Manage album catalog' });
    this.songsCard = page.locator('.card', { hasText: 'Manage individual tracks' });
    this.recentArtistsHeading = page.getByRole('heading', { name: 'Recently Added Artists' });
  }

  async goto() {
    await this.page.goto('/admin');
  }

  async getStatValue(statTitle: string): Promise<string> {
    const stat = this.page.locator('.stat', { hasText: statTitle });
    return stat.locator('.stat-value').innerText();
  }
}
