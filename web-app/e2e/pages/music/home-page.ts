import { type Page, type Locator } from '@playwright/test';

export class HomePage {
  readonly page: Page;
  readonly heading: Locator;
  readonly subtitle: Locator;
  readonly topAlbumsHeading: Locator;
  readonly topSongsHeading: Locator;
  readonly topAlbumsLink: Locator;
  readonly topSongsLink: Locator;
  readonly topArtistsLink: Locator;
  readonly navAlbums: Locator;
  readonly navSongs: Locator;
  readonly navArtists: Locator;
  readonly navLists: Locator;
  readonly loginButton: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'The Greatest Music' });
    this.subtitle = page.getByText('Discover definitive rankings');
    this.topAlbumsHeading = page.getByRole('heading', { name: 'Top Ranked Albums' });
    this.topSongsHeading = page.getByRole('heading', { name: 'Top Ranked Songs' });
    this.topAlbumsLink = page.getByRole('link', { name: 'Top Albums' });
    this.topSongsLink = page.getByRole('link', { name: 'Top Songs' });
    this.topArtistsLink = page.getByRole('link', { name: 'Top Artists' });
    // Desktop navbar links
    this.navAlbums = page.locator('.navbar-center').getByText('Albums');
    this.navSongs = page.locator('.navbar-center').getByText('Songs');
    this.navArtists = page.locator('.navbar-center').getByRole('link', { name: 'Artists' });
    this.navLists = page.locator('.navbar-center').getByRole('link', { name: 'Lists' });
    this.loginButton = page.locator('#navbar_login_button');
  }

  async goto() {
    await this.page.goto('/');
  }
}
