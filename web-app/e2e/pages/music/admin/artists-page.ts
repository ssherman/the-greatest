import { type Page, type Locator } from '@playwright/test';

export class ArtistsPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly subtitle: Locator;
  readonly searchInput: Locator;
  readonly newArtistButton: Locator;
  readonly table: Locator;
  readonly tableRows: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'Artists', exact: true });
    this.subtitle = page.getByText('Manage music artists, bands, and performers');
    this.searchInput = page.getByPlaceholder('Search artists by name...');
    this.newArtistButton = page.getByRole('link', { name: 'New Artist' });
    this.table = page.locator('#artists_table table');
    this.tableRows = this.table.locator('tbody tr');
  }

  async goto() {
    await this.page.goto('/admin/artists');
  }

  async clickFirstArtist() {
    await this.tableRows.first().getByRole('link').first().click();
  }
}
