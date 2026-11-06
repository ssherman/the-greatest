import { test, expect } from '@playwright/test';

test.describe('Books mobile menu, signed in', () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test('My Books gets a divider on each side and a heading that does not look disabled', async ({ page }) => {
    await page.goto('/');
    // Not expectSignedIn: it wants My Books visible, and on a phone that is only
    // true once the drawer is open.
    await expect(page.locator('#navbar_login_button')).toHaveAttribute('data-auth-state', 'signed-in', {
      timeout: 15_000,
    });
    await page.locator('#books-nav-drawer-button').click();

    const panel = page.locator('#books-nav-drawer-panel');
    // My Books is revealed client-side, so wait for it before counting dividers.
    const heading = panel.locator('#navbar_my_books .menu-title');
    await expect(heading).toBeVisible();
    await expect(panel.locator('li:empty:visible')).toHaveCount(2);

    // daisyUI's default is 40% of the text colour, which is what read as disabled.
    const color = await heading.evaluate((el) => getComputedStyle(el).color);
    expect(color).not.toMatch(/ 0\.4\)$/);
  });
});
