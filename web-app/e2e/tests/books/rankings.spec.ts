import { test, expect } from '@playwright/test';

// Books nav_links (app/views/books/shared/_nav_links.html.erb) renders TWICE --
// once for the desktop bar (.navbar-center) and once for the mobile drawer
// (.drawer-side) -- and its "Lists" submenu is itself a <details> containing a
// link with the exact text "The Global Canon" (books_global_canon_path). Both
// copies sit outside <main>, so locators below that care about page-body
// content are scoped to `main` to avoid matching those nav copies instead.
test.describe('Books rankings explainer', () => {
  test('the page loads and renders its heading', async ({ page }) => {
    const response = await page.goto('/rankings');

    expect(response?.status()).toBe(200);
    await expect(page.getByRole('heading', { name: 'How Our Rankings Work', level: 1 })).toBeVisible();
  });

  test('the footer links to it from another page', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('link', { name: 'Ranking Details' }).click();

    await expect(page).toHaveURL(/\/rankings$/);
  });

  test('the western tilt section is present and links to the Global Canon', async ({ page }) => {
    await page.goto('/rankings');

    await expect(page.getByRole('heading', { name: /why the list still skews western/i, level: 2 })).toBeVisible();

    // Scoped to <main>: the nav's "Lists" dropdown (rendered twice in the
    // layout) also contains a link with this exact text, and an unscoped
    // getByRole here would be a strict-mode violation across three matches.
    await page.locator('main').getByRole('link', { name: 'The Global Canon', exact: true }).click();
    await expect(page).toHaveURL(/\/global-canon$/);
  });

  test('a penalty group expands to reveal its table', async ({ page }) => {
    await page.goto('/rankings');

    // Scoped to <main>: the books layout's nav renders a "Lists" <details>
    // dropdown twice (desktop + mobile), both outside <main> and both before
    // the penalty table in DOM order, so an unscoped `details` locator would
    // grab the nav dropdown instead of the first penalty group.
    const firstGroup = page.locator('main').locator('details').first();
    await expect(firstGroup.locator('table')).toBeHidden();

    await firstGroup.locator('summary').click();

    await expect(firstGroup.locator('table')).toBeVisible();
  });

  test('both open source repositories are linked', async ({ page }) => {
    await page.goto('/rankings');

    await expect(page.locator('a[href="https://github.com/ssherman/weighted_list_rank"]').first()).toBeVisible();
    await expect(page.locator('a[href="https://github.com/ssherman/the-greatest/"]').first()).toBeVisible();
  });
});
