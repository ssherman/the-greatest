import { test, expect } from '@playwright/test';

// Signed-out coverage. This spec is matched by the `books` project, which has
// no storageState -- see e2e/playwright.config.ts. Signed-in coverage for the
// same page lives in e2e/tests/books/account/membership.spec.ts.

test.describe('Books membership page', () => {
  test('the page renders with both plans', async ({ page }) => {
    await page.goto('/membership');

    await expect(page.getByRole('heading', { level: 1, name: /Support The Greatest Books/i })).toBeVisible();
    await expect(page.getByTestId('join-monthly')).toBeVisible();
    await expect(page.getByTestId('join-yearly')).toBeVisible();
  });

  test('the books story is the one that renders', async ({ page }) => {
    await page.goto('/membership');

    await expect(page.getByText(/In 2009/)).toBeVisible();
  });

  test('a signed-out visitor gets the sign-in modal instead of checkout', async ({ page }) => {
    await page.goto('/membership');

    // <dialog> without an open attribute renders nothing, so this also proves
    // the click actually ran the onclick handler rather than the modal simply
    // always being present.
    await expect(page.locator('#login_modal')).toBeHidden();

    await page.getByTestId('join-monthly').click();

    await expect(page).toHaveURL(/\/membership$/);
    await expect(page.locator('#login_modal')).toBeVisible();
  });

  test('the members area redirects a signed-out visitor to the membership page', async ({ page }) => {
    await page.goto('/members');

    await expect(page).toHaveURL(/\/membership$/);
    await expect(page.getByText(/Sign in to your membership/i)).toBeVisible();
  });

  test('the legacy support url lands on the membership page', async ({ page }) => {
    await page.goto('/support');

    await expect(page).toHaveURL(/\/membership$/);
  });

  test('a donation can be started without an account', async ({ page }) => {
    await page.goto('/membership');
    await page.getByTestId('donate').click();

    await expect(page).toHaveURL(/checkout\.stripe\.com/, { timeout: 20_000 });
  });
});
