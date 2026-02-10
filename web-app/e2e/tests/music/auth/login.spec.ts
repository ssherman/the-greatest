import { test, expect } from '@playwright/test';

// This test exercises the full login flow directly (not using saved storageState)
test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Login Flow', () => {
  test('can log in via Firebase email/password', async ({ page }) => {
    await page.goto('/');

    // Verify we start as logged out
    const loginButton = page.locator('#navbar_login_button');
    await expect(loginButton).toHaveText('Login');

    // Open the auth modal
    await loginButton.click();

    const modal = page.locator('#login_modal');
    await expect(modal).toBeVisible();
    await expect(modal.getByRole('heading', { name: 'Sign In' })).toBeVisible();

    // Step 1: Enter email
    await modal.getByPlaceholder('Email address').first().fill(process.env.PLAYWRIGHT_ADMIN_EMAIL!);
    await modal.getByRole('button', { name: 'Continue' }).click();

    // Step 2: Wait for password step, enter password, and submit
    const passwordInput = modal.getByPlaceholder('Password');
    await expect(passwordInput).toBeVisible();
    await passwordInput.fill(process.env.PLAYWRIGHT_ADMIN_PASSWORD!);
    await modal.getByRole('button', { name: 'Sign In' }).click();

    // Wait for reload and Firebase auth state propagation
    await page.waitForLoadState('networkidle');
    await expect(loginButton).toHaveText('Logout', { timeout: 15000 });
  });

  test('shows auth modal with email and password steps', async ({ page }) => {
    await page.goto('/');

    // Open modal
    await page.locator('#navbar_login_button').click();

    const modal = page.locator('#login_modal');
    await expect(modal).toBeVisible();

    // Verify step 1 elements
    await expect(modal.getByRole('button', { name: 'Sign in with Google' })).toBeVisible();
    await expect(modal.getByPlaceholder('Email address').first()).toBeVisible();
    await expect(modal.getByRole('button', { name: 'Continue' })).toBeVisible();

    // Verify step 2 is hidden initially
    await expect(modal.getByPlaceholder('Password')).toBeHidden();
  });

  test('can close the auth modal', async ({ page }) => {
    await page.goto('/');

    await page.locator('#navbar_login_button').click();

    const modal = page.locator('#login_modal');
    await expect(modal).toBeVisible();

    await modal.locator('.modal-box').getByRole('button', { name: 'Close' }).click();
    await expect(modal).toBeHidden();
  });
});
