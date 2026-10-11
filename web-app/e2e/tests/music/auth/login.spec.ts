import { test, expect } from '@playwright/test';
import { credentials, signIn } from '../../../support/sign-in';

// This test exercises the full login flow directly (not using saved storageState)
test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Login Flow', () => {
  test('can log in via Firebase email/password', async ({ page }) => {
    await page.goto('/');

    // Verify we start as logged out
    const loginButton = page.locator('#navbar_login_button');
    await expect(loginButton).toHaveText('Login');

    await signIn(page, credentials('ADMIN'));
    await expect(loginButton).toHaveAttribute('data-auth-state', 'signed-in', { timeout: 15_000 });
    await expect(loginButton).toHaveText('Logout');
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
