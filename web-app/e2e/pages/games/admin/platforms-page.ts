import { type Page, type Locator } from '@playwright/test';

export class PlatformsPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly subtitle: Locator;
  readonly searchInput: Locator;
  readonly newPlatformButton: Locator;
  readonly table: Locator;
  readonly tableRows: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'Platforms', exact: true });
    this.subtitle = page.getByText('Manage gaming platforms');
    this.searchInput = page.getByPlaceholder('Search platforms by name...');
    this.newPlatformButton = page.getByRole('link', { name: 'New Platform' });
    this.table = page.locator('#platforms_table table');
    this.tableRows = this.table.locator('tbody tr');
  }

  async goto() {
    await this.page.goto('/admin/platforms');
  }

  async clickFirstPlatform() {
    await this.tableRows.first().getByRole('link').first().click();
  }
}
