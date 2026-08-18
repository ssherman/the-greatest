import { test, expect } from '@playwright/test';

// This project (games) is always signed in -- see e2e/playwright.config.ts.

test.describe('Games membership page', () => {
  test('the page renders with the games story and both plans', async ({ page }) => {
    await page.goto('/membership');

    await expect(page.getByRole('heading', { level: 1, name: /Support The Greatest Games/i })).toBeVisible();
    // NOT /spreadsheet/i: that word appears in two separate <p> elements in
    // _story_games.html.erb ("began as a spreadsheet" and, in the next
    // paragraph, "That spreadsheet became this site"), so it is a guaranteed
    // strict-mode violation -- getByText resolves to 2 elements and
    // toBeVisible() throws rather than passing or failing meaningfully. This
    // longer phrase occurs exactly once in the partial.
    await expect(page.getByText(/began as a spreadsheet/i)).toBeVisible();
    await expect(page.getByTestId('join-monthly')).toBeVisible();
    await expect(page.getByTestId('join-yearly')).toBeVisible();
  });

  test('the members link is not shown to a non-member', async ({ page }) => {
    // The layout renders #navbar_members twice (mobile dropdown + desktop
    // menu) and membership_state_controller.js reveals both via
    // querySelectorAll -- .first() avoids a strict-mode violation, not a
    // narrowing of what's checked.
    const stateResponse = page.waitForResponse((res) => res.url().includes('/membership_state'));
    await page.goto('/');
    // Wait for the client-side membership check to actually complete rather
    // than asserting on the pre-JS server-rendered state, which would pass
    // even if the controller never ran at all.
    await stateResponse;

    await expect(page.locator('#navbar_members').first()).toHaveClass(/hidden/);
  });
});
