import { type Page, type Locator } from '@playwright/test';

export class GamesPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly subtitle: Locator;
  readonly searchInput: Locator;
  readonly newGameButton: Locator;
  readonly table: Locator;
  readonly tableRows: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'Games', exact: true });
    this.subtitle = page.getByText('Manage video games catalog');
    this.searchInput = page.getByPlaceholder('Search games by title or developer...');
    this.newGameButton = page.getByRole('link', { name: 'New Game' });
    this.table = page.locator('#games_table table');
    this.tableRows = this.table.locator('tbody tr');
  }

  async goto() {
    await this.page.goto('/admin/games');
  }

  async clickFirstGame() {
    await this.tableRows.first().getByRole('link').first().click();
  }
}
