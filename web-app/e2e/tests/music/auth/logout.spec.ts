import { test, expect } from '@playwright/test';

// Logout test needs fresh login since storageState doesn't capture Firebase IndexedDB
test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Logout Flow', () => {
  test('can log out via navbar button', async ({ page }) => {
    await page.goto('/');

    // First, log in
    const loginButton = page.locator('#navbar_login_button');
    await loginButton.click();

    const modal = page.locator('#login_modal');
    await modal.getByPlaceholder('Email address').first().fill(process.env.PLAYWRIGHT_ADMIN_EMAIL!);
    await modal.getByRole('button', { name: 'Continue' }).click();

    const passwordInput = modal.getByPlaceholder('Password');
    await expect(passwordInput).toBeVisible();
    await passwordInput.fill(process.env.PLAYWRIGHT_ADMIN_PASSWORD!);
    await modal.getByRole('button', { name: 'Sign In' }).click();

    // Wait for login to complete
    await page.waitForLoadState('networkidle');
    await expect(loginButton).toHaveText('Logout', { timeout: 15000 });

    // Now test logout
    await loginButton.click();

    // Wait for Firebase auth state propagation and button update
    await expect(loginButton).toHaveText('Login', { timeout: 10000 });
  });
});
