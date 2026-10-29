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
    // menu) and membership_state_controller.js toggles both via
    // querySelectorAll -- .first() avoids a strict-mode violation, not a
    // narrowing of what's checked.
    //
    // The link is hidden by default, so asserting on it straight after load would
    // pass even if the controller never ran. Membership now rides in the cached
    // user_list_state entry, so wait for that entry to exist (it is filled by a
    // request on the first load, or already present) before asserting.
    await page.goto('/');
    await expect
      .poll(() => page.evaluate(() => {
        const key = Object.keys(localStorage).find((k) => k.startsWith('tg:user_list_state:'));
        return key ? JSON.parse(localStorage.getItem(key)!).membership?.member : undefined;
      }))
      .toBe(false);

    await expect(page.locator('#navbar_members').first()).toHaveClass(/hidden/);
  });
});
