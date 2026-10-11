import { expect, type Page } from '@playwright/test';

export type Credentials = { email: string; password: string };
export type Account = 'ADMIN' | 'USER' | 'MEMBER';

export function credentials(account: Account): Credentials {
  const email = process.env[`PLAYWRIGHT_${account}_EMAIL`];
  const password = process.env[`PLAYWRIGHT_${account}_PASSWORD`];
  if (!email || !password) {
    throw new Error(
      `PLAYWRIGHT_${account}_EMAIL and PLAYWRIGHT_${account}_PASSWORD must be set in e2e/.env (see e2e/.env.example)`
    );
  }
  return { email, password };
}

// Drives the login modal, then waits for the one signal that means Rails has
// issued a session: both the tg_uid and _the_greatest_session cookies exist.
// The navbar label reads "Logout" as soon as Firebase resolves client-side,
// ~100ms before Rails answers POST /auth/sign_in, and networkidle fires in the
// quiet window BEFORE that POST is sent. Capturing storage state on either of
// those signals saved a state with no session, which made every admin spec
// fail as "element not found" on the public homepage.
export async function signIn(page: Page, { email, password }: Credentials): Promise<void> {
  await page.goto('/');
  await page.locator('#navbar_login_button').click();

  const modal = page.locator('#login_modal');
  await expect(modal).toBeVisible();

  await modal.getByPlaceholder('Email address').first().fill(email);
  await modal.getByRole('button', { name: 'Continue' }).click();

  const passwordInput = modal.getByPlaceholder('Password');
  await expect(passwordInput).toBeVisible();
  await passwordInput.fill(password);
  await modal.getByRole('button', { name: 'Sign In' }).click();

  await expect
    .poll(
      async () => {
        const names = (await page.context().cookies()).map((cookie) => cookie.name);
        return names.includes('tg_uid') && names.includes('_the_greatest_session');
      },
      { timeout: 15_000, message: 'Rails never issued a session after the Firebase sign-in' }
    )
    .toBe(true);
}

export async function signInAndSave(page: Page, creds: Credentials, authFile: string): Promise<void> {
  await signIn(page, creds);
  await page.context().storageState({ path: authFile });
}
