import { test, expect } from '@playwright/test';
import { credentials, signIn } from '../../../support/sign-in';

// Fresh login per test: storageState does not capture Firebase's IndexedDB.
test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Logout Flow', () => {
  test('can log out via navbar button', async ({ page }) => {
    await signIn(page, credentials('ADMIN'));

    // Sign-in reloads the page once Rails has a session. Navigating again here
    // collapses that race into a known fresh page (page.reload() is aborted by
    // the page's own reload), on which the button is
    // wired only when data-auth-state appears. Clicking on the "Logout" label
    // alone used to open the login modal: the hint paints the label before
    // Firebase rewires the inline onclick.
    await page.goto('/');
    const button = page.locator('#navbar_login_button');
    await expect(button).toHaveAttribute('data-auth-state', 'signed-in', { timeout: 15_000 });
    await expect(button).toHaveText('Logout');

    await button.click();

    await expect(button).toHaveAttribute('data-auth-state', 'signed-out', { timeout: 10_000 });
    await expect(button).toHaveText('Login');
  });
});
