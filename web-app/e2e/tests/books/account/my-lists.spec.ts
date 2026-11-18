import { test, expect } from '@playwright/test';
import { seed } from '../../../support/seed';

test.describe('Books My Lists', () => {
  test('the My Books desktop group is revealed when signed in and orders personal links', async ({ page }) => {
    await page.goto('/');

    const myBooks = page.locator('.navbar-center #navbar_my_books');
    await expect(myBooks).not.toHaveClass(/hidden/);
    await expect(myBooks.locator('details > summary')).toHaveText('My Books');

    await myBooks.locator('summary').click();
    await expect(myBooks.getByRole('link')).toHaveText([
      'Lists',
      'Reading Goals',
      'Import from Goodreads',
      'My Rankings',
      'Reviews',
      'Saved Searches',
      'Recommendations',
    ]);
  });

  test('the dashboard lists the four books defaults', async ({ page }) => {
    await page.goto('/my/lists');

    await expect(page.getByRole('heading', { name: 'My Lists', level: 1 })).toBeVisible();
    const dashboard = page.getByTestId('my-lists-dashboard');
    await expect(dashboard.getByText('My Favorite Books')).toBeVisible();
    await expect(dashboard.getByText("Books I've Read")).toBeVisible();
    await expect(dashboard.getByText("Books I'm Reading")).toBeVisible();
    await expect(dashboard.getByText('Books I Want to Read')).toBeVisible();
  });

  test('the dashboard renders in the books theme', async ({ page }) => {
    await page.goto('/my/lists');

    await expect(page.locator('html')).toHaveAttribute('data-theme', 'books');
  });

  test('a list page offers Grid and Table only', async ({ page }) => {
    await page.goto('/my/lists');
    await page.getByTestId('my-lists-dashboard').getByText('My Favorite Books').click();

    const toolbar = page.getByTestId('list-toolbar');
    await expect(toolbar.getByRole('link', { name: 'Grid' })).toBeVisible();
    await expect(toolbar.getByRole('link', { name: 'Table' })).toBeVisible();
    await expect(toolbar.getByRole('link', { name: 'List' })).toHaveCount(0);
    await toolbar.getByRole('link', { name: 'Table' }).click();

    await expect(page).toHaveURL(/view_mode=table_view/);
  });

  test('creating a list from the dashboard lands on the new list', async ({ page }) => {
    // e2e:prepare removes lists with this prefix on the next run; there is no delete UI yet.
    const name = `E2E Created List ${Date.now()}`;
    await page.goto('/my/lists');
    await page.getByTestId('new-list-button').click();

    const dialog = page.getByRole('dialog').filter({ hasText: 'New list' });
    await dialog.getByLabel('Name').fill(name);
    await dialog.getByRole('button', { name: 'Create list' }).click();

    await expect(page).toHaveURL(/\/my\/lists\/\d+/);
    await expect(page.getByRole('heading', { name, level: 1 })).toBeVisible();

    // Back must restore the dashboard with the dialog closed, not the cached open dialog.
    await page.goBack();
    await expect(page).toHaveURL(/\/my\/lists$/);
    await expect(page.locator('#new-list-dialog')).not.toBeVisible();
    await expect(page.locator('#new-list-dialog')).not.toHaveAttribute('open', /.*/);
  });

  test('the favorites list explains that it counts toward the rankings', async ({ page }) => {
    await page.goto('/my/lists');
    const favorites = page.getByTestId('user-list-card').filter({ hasText: 'My Favorite Books' });
    await expect(favorites.getByText('Counts toward the site rankings')).toBeVisible();
    await favorites.click();

    await expect(page.getByTestId('favorites-rankings-note')).toContainText(
      'Your Favorites count toward the site rankings.',
    );
    await expect(page.getByTestId('favorites-rankings-note')).toContainText('the books near the top count for more');
  });

  test('Recently added puts the newest book first', async ({ page }) => {
    const publicListId = seed().lists.public_books;
    await page.goto(`/my/lists/${publicListId}?view_mode=table_view`);

    const titles = page.locator('#list_items tbody tr td:nth-child(2)');
    const inPositionOrder = (await titles.allInnerTexts()).map((title) => title.trim());
    expect(inPositionOrder.length).toBeGreaterThan(1);

    await page.getByTestId('list-toolbar').getByRole('link', { name: 'Recently added' }).click();
    await expect(page).toHaveURL(/sort=added/);

    // The seed adds the books in position order, so the last one is the newest.
    await expect(titles.first()).toHaveText(inPositionOrder[inPositionOrder.length - 1]);
  });

  test('a list page offers a CSV download', async ({ page }) => {
    await page.goto('/my/lists');
    await page.getByTestId('my-lists-dashboard').getByText('My Favorite Books').click();

    const link = page.getByTestId('download-csv');
    await expect(link).toBeVisible();

    const response = await page.request.get((await link.getAttribute('href'))!);
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toContain('text/csv');
  });
});

test.describe('Books My Lists mobile navigation', () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test('the My Books drawer group is inline and orders personal links', async ({ page }) => {
    await page.goto('/');
    await page.locator('#books-nav-drawer-button').click();

    const myBooks = page.locator('#books-nav-drawer-panel #navbar_my_books');
    await expect(myBooks).not.toHaveClass(/hidden/);
    await expect(myBooks.getByText('My Books', { exact: true })).toBeVisible();
    await expect(myBooks.locator('details, summary')).toHaveCount(0);
    await expect(myBooks.getByRole('link')).toHaveText([
      'Lists',
      'Reading Goals',
      'Import from Goodreads',
      'My Rankings',
      'Reviews',
      'Saved Searches',
      'Recommendations',
    ]);
  });
});

test.describe('Books My Lists item links', () => {
  // The list lives inside a #list_items Turbo Frame. Without target="_top" the
  // click is scoped to that frame, the book page has no such frame, and Turbo
  // writes "Content missing" instead of navigating.
  test('a book title in grid view navigates to the book page', async ({ page }) => {
    const publicListId = seed().lists.public_books;
    await page.goto(`/my/lists/${publicListId}?view_mode=grid_view`);

    const link = page.locator('#list_items a[href^="/book/"]').first();
    const title = (await link.innerText()).trim();
    await link.click();

    await expect(page).toHaveURL(/\/book\//);
    await expect(page.getByRole('heading', { level: 1 })).toHaveText(title);
    await expect(page.getByText('Content missing')).toHaveCount(0);
  });
});
