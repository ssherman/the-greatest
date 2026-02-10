import { type Page, type Locator } from '@playwright/test';

export class SeriesPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly subtitle: Locator;
  readonly searchInput: Locator;
  readonly newSeriesButton: Locator;
  readonly table: Locator;
  readonly tableRows: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'Series', exact: true });
    this.subtitle = page.getByText('Manage game franchises and series');
    this.searchInput = page.getByPlaceholder('Search series by name...');
    this.newSeriesButton = page.getByRole('link', { name: 'New Series' });
    this.table = page.locator('#series_table table');
    this.tableRows = this.table.locator('tbody tr');
  }

  async goto() {
    await this.page.goto('/admin/series');
  }

  async clickFirstSeries() {
    await this.tableRows.first().getByRole('link').first().click();
  }
}
