import { type Page, type Locator } from '@playwright/test';

export class RankingConfigurationsPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly subtitle: Locator;
  readonly newButton: Locator;
  readonly table: Locator;
  readonly tableRows: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'Ranking Configurations', exact: true });
    this.subtitle = page.getByText('Manage game ranking configurations and algorithms');
    this.newButton = page.getByRole('link', { name: /New Ranking Configuration/ }).first();
    this.table = page.locator('table');
    this.tableRows = this.table.locator('tbody tr');
  }

  async goto() {
    await this.page.goto('/admin/ranking_configurations');
  }
}
