import { type Page, type Locator } from '@playwright/test';

export class CompaniesPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly subtitle: Locator;
  readonly searchInput: Locator;
  readonly newCompanyButton: Locator;
  readonly table: Locator;
  readonly tableRows: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'Companies', exact: true });
    this.subtitle = page.getByText('Manage game developers and publishers');
    this.searchInput = page.getByPlaceholder('Search companies by name...');
    this.newCompanyButton = page.getByRole('link', { name: 'New Company' });
    this.table = page.locator('#companies_table table');
    this.tableRows = this.table.locator('tbody tr');
  }

  async goto() {
    await this.page.goto('/admin/companies');
  }

  async clickFirstCompany() {
    await this.tableRows.first().getByRole('link').first().click();
  }
}
