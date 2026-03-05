import { type Page, type Locator } from '@playwright/test';

export class AlbumListsPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly subtitle: Locator;
  readonly searchInput: Locator;
  readonly statusFilter: Locator;
  readonly table: Locator;
  readonly tableRows: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'Album Lists', exact: true });
    this.subtitle = page.getByText('Manage album lists and their rankings');
    this.searchInput = page.getByPlaceholder('Search by name or source...');
    this.statusFilter = page.locator('select[name="status"]');
    this.table = page.locator('turbo-frame#lists_table table');
    this.tableRows = this.table.locator('tbody tr');
  }

  async goto() {
    await this.page.goto('/admin/albums/lists');
  }
}
