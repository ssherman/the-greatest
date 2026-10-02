import { test, expect } from '@playwright/test';

// Matched by `books-account`: PLAYWRIGHT_ADMIN_EMAIL, signed in, NOT a member.
// This is the first feature gate (as opposed to the members' area itself), so
// the non-member side is worth its own check. Do not comp this account; the
// member flow uses the separate PLAYWRIGHT_MEMBER_EMAIL account.
test.describe('Books API token page, signed in as a non-member', () => {
  test('is redirected to the membership page with the members-only message', async ({ page }) => {
    await page.goto('/developers/tokens');

    await expect(page).toHaveURL(/\/membership$/);
    await expect(page.getByText(/That page is for members/i)).toBeVisible();
  });

  test('can still read the documentation', async ({ page }) => {
    await page.goto('/developers');

    await expect(page.getByRole('heading', { level: 1, name: /API/ })).toBeVisible();
    // .first(): the docs page links to the token page from two sentences.
    await expect(page.locator('article#developers').getByRole('link', { name: '/developers/tokens' }).first()).toBeVisible();
  });
});
