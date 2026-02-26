import { type Page, type Locator } from '@playwright/test';

export class ListsPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly subtitle: Locator;
  readonly searchInput: Locator;
  readonly statusFilter: Locator;
  readonly newListButton: Locator;
  readonly table: Locator;
  readonly tableRows: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'Game Lists', exact: true });
    this.subtitle = page.getByText('Manage game lists and their rankings');
    this.searchInput = page.getByPlaceholder('Search by name or source...');
    this.statusFilter = page.locator('select[name="status"]');
    this.newListButton = page.getByRole('link', { name: 'New Game List' });
    this.table = page.locator('table');
    this.tableRows = this.table.locator('tbody tr');
  }

  async goto() {
    await this.page.goto('/admin/lists');
  }

  async clickFirstList() {
    await this.tableRows.first().getByRole('link').first().click();
  }
}
