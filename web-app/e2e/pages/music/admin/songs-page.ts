import { type Page, type Locator } from '@playwright/test';

export class SongsPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly subtitle: Locator;
  readonly searchInput: Locator;
  readonly newSongButton: Locator;
  readonly table: Locator;
  readonly tableRows: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'Songs', exact: true });
    this.subtitle = page.getByText('Manage music songs and recordings');
    this.searchInput = page.getByPlaceholder('Search songs by title or artist...');
    this.newSongButton = page.getByRole('link', { name: 'New Song' });
    this.table = page.locator('#songs_table table');
    this.tableRows = this.table.locator('tbody tr');
  }

  async goto() {
    await this.page.goto('/admin/songs');
  }

  async clickFirstSong() {
    await this.tableRows.first().getByRole('link').first().click();
  }
}
