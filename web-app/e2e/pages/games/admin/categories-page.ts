import { type Page, type Locator } from '@playwright/test';

export class CategoriesPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly subtitle: Locator;
  readonly searchInput: Locator;
  readonly newCategoryButton: Locator;
  readonly table: Locator;
  readonly tableRows: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'Categories', exact: true });
    this.subtitle = page.getByText('Manage game genres, locations, and subjects');
    this.searchInput = page.getByPlaceholder('Search categories by name...');
    this.newCategoryButton = page.getByRole('link', { name: 'New Category' });
    this.table = page.locator('#categories_table table');
    this.tableRows = this.table.locator('tbody tr');
  }

  async goto() {
    await this.page.goto('/admin/categories');
  }

  async clickFirstCategory() {
    await this.tableRows.first().getByRole('link').first().click();
  }
}
