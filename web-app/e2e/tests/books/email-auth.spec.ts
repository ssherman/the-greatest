import { test, expect } from '@playwright/test';

// Sign-in and the error paths only. Deliberately NOT sign-up: a real signup
// creates a live Firebase account in the shared production project on every run.
test.use({ baseURL: 'https://dev-new.thegreatestbooks.org', storageState: { cookies: [], origins: [] } });

test.describe('email/password authentication', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Login' }).click();
    await expect(page.locator('#login_modal')).toBeVisible();
  });

  test('signs in with a valid email and password', async ({ page }) => {
    const modal = page.locator('#login_modal');
    const emailStep = modal.locator('[data-authentication-target="emailStep"]');

    await emailStep.getByPlaceholder('Email address').fill(process.env.PLAYWRIGHT_ADMIN_EMAIL!);
    await emailStep.getByRole('button', { name: 'Continue' }).click();

    const password = modal.getByPlaceholder('Password');
    await expect(password).toBeVisible();
    await password.fill(process.env.PLAYWRIGHT_ADMIN_PASSWORD!);
    await modal.getByRole('button', { name: 'Sign In' }).click();

    await expect(page.getByRole('button', { name: 'Logout' })).toBeVisible({ timeout: 15000 });
  });

  test('shows the create-account guidance on a wrong password', async ({ page }) => {
    const modal = page.locator('#login_modal');
    const emailStep = modal.locator('[data-authentication-target="emailStep"]');

    await emailStep.getByPlaceholder('Email address').fill(process.env.PLAYWRIGHT_ADMIN_EMAIL!);
    await emailStep.getByRole('button', { name: 'Continue' }).click();
    await modal.getByPlaceholder('Password').fill('definitely-not-the-password');
    await modal.getByRole('button', { name: 'Sign In' }).click();

    await expect(modal.getByText(/Invalid email or password/)).toBeVisible({ timeout: 15000 });
    // The migration-specific half: users with no password set here are stranded
    // unless the failure points them at Create account.
    await expect(modal.getByText(/choose Create account with this address/)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Logout' })).toHaveCount(0);
  });

  test('the forgot-password form does not reveal whether an account exists', async ({ page }) => {
    // submitForgotPassword shows the SAME message on success and on failure, by
    // design, so the DOM alone cannot distinguish "reset sent" from "Firebase
    // threw". Watching console.error is what makes this test able to fail --
    // in particular on auth/unauthorized-continue-uri, which is what a domain
    // missing from Firebase's authorized-domains list produces once
    // actionCodeSettings is in play. Without this the assertion below would
    // pass just as happily against a completely broken reset.
    const authErrors: string[] = [];
    page.on('console', (msg) => {
      if (msg.type() === 'error' && /reset|auth\//i.test(msg.text())) authErrors.push(msg.text());
    });

    const modal = page.locator('#login_modal');
    const emailStep = modal.locator('[data-authentication-target="emailStep"]');
    const forgotForm = modal.locator('[data-authentication-target="forgotPasswordForm"]');

    await emailStep.getByPlaceholder('Email address').fill('nobody-has-this-address@example.com');
    await emailStep.getByRole('button', { name: 'Continue' }).click();
    await modal.getByRole('link', { name: 'Forgot password?' }).click();

    // The reset form carries its OWN required email input and showForgotPassword
    // does not prefill it, so submitting without this is a no-op: the required
    // attribute blocks it, and submitForgotPassword early-returns on a blank value.
    await expect(forgotForm).toBeVisible();
    await forgotForm.getByPlaceholder('Email address').fill('nobody-has-this-address@example.com');
    await forgotForm.getByRole('button', { name: 'Send Reset Link' }).click();

    await expect(modal.getByText(/If an account exists with this email/)).toBeVisible({ timeout: 15000 });

    const unauthorized = authErrors.filter((e) => /unauthorized-continue-uri/.test(e));
    expect(
      unauthorized,
      'actionCodeSettings sent a continue URL for a host that is not on Firebase\'s ' +
        'authorized-domains list, so no reset email was sent -- and the UI showed success anyway'
    ).toEqual([]);
  });
});
