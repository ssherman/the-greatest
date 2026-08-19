import { test, expect } from '@playwright/test';

// Signed-in coverage, matched by the `books-account` project (storageState
// from books-auth.setup.ts) -- see e2e/playwright.config.ts.
//
// Deliberately NOT covered here: the members'-area view for an actual member.
// The e2e user is not a member, and comping it from a spec would leave shared
// dev-database state behind that later runs depend on. That case is covered
// by MembersControllerTest, where a fixture makes the membership exact. Do
// not "fix" this by granting the e2e user membership.

test.describe('Books membership, signed in', () => {
  test('a signed-in non-member is redirected away from the members area', async ({ page }) => {
    await page.goto('/members');

    await expect(page).toHaveURL(/\/membership$/);
    await expect(page.getByText(/That page is for members/i)).toBeVisible();
  });

  test('joining redirects to Stripe checkout', async ({ page }) => {
    await page.goto('/membership');
    await page.getByTestId('join-monthly').click();

    await expect(page).toHaveURL(/checkout\.stripe\.com/, { timeout: 20_000 });
  });

  test('the thanks page renders without granting anything', async ({ page }) => {
    await page.goto('/membership/thanks');

    await expect(page.getByRole('heading', { level: 1, name: /Thank you/i })).toBeVisible();

    // The E2E form of "hitting /membership/thanks directly grants nothing":
    // the non-member is still turned away from the members area afterwards.
    await page.goto('/members');
    await expect(page).toHaveURL(/\/membership$/);
  });
});
