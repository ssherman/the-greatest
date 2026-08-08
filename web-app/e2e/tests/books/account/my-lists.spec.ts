import { test, expect } from '@playwright/test';

const publicListId = process.env.PLAYWRIGHT_PUBLIC_BOOKS_LIST_ID!;

test.describe('Books My Lists', () => {
  test('the My Lists nav link is revealed when signed in', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#navbar_my_lists').first()).not.toHaveClass(/hidden/);
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

  test('a list page offers all three view modes and switches between them', async ({ page }) => {
    await page.goto('/my/lists');
    await page.getByTestId('my-lists-dashboard').getByText('My Favorite Books').click();

    const toolbar = page.getByTestId('list-toolbar');
    await expect(toolbar.getByRole('link', { name: 'Grid' })).toBeVisible();
    await expect(toolbar.getByRole('link', { name: 'Table' })).toBeVisible();
    await toolbar.getByRole('link', { name: 'List' }).click();

    await expect(page).toHaveURL(/view_mode=list_view/);
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

test.describe('Books My Lists item links', () => {
  // The list lives inside a #list_items Turbo Frame. Without target="_top" the
  // click is scoped to that frame, the book page has no such frame, and Turbo
  // writes "Content missing" instead of navigating.
  for (const [label, viewMode] of [['grid', 'grid_view'], ['list', 'list_view']] as const) {
    test(`a book title in ${label} view navigates to the book page`, async ({ page }) => {
      await page.goto(`/my/lists/${publicListId}?view_mode=${viewMode}`);

      const link = page.locator('#list_items a[href^="/book/"]').first();
      const title = (await link.innerText()).trim();
      await link.click();

      await expect(page).toHaveURL(/\/book\//);
      await expect(page.getByRole('heading', { level: 1 })).toHaveText(title);
      await expect(page.getByText('Content missing')).toHaveCount(0);
    });
  }
});
