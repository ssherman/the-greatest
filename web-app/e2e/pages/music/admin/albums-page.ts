import { type Page, type Locator } from '@playwright/test';

export class AlbumsPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly subtitle: Locator;
  readonly searchInput: Locator;
  readonly newAlbumButton: Locator;
  readonly table: Locator;
  readonly tableRows: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'Albums', exact: true });
    this.subtitle = page.getByText('Manage music albums and releases');
    this.searchInput = page.getByPlaceholder('Search albums by title or artist...');
    this.newAlbumButton = page.getByRole('link', { name: 'New Album' });
    this.table = page.locator('#albums_table table');
    this.tableRows = this.table.locator('tbody tr');
  }

  async goto() {
    await this.page.goto('/admin/albums');
  }

  async clickFirstAlbum() {
    await this.tableRows.first().getByRole('link').first().click();
  }
}
