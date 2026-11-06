import { test, expect } from '@playwright/test';
import { credentials, signIn } from '../../../support/sign-in';
import { firebaseUserCount } from '../../../support/sign-in-state';

// A fresh sign-in, not the project's shared admin storage state: logging out
// destroys this browser's session row, and the other books-admin specs reuse
// theirs.
test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Admin logout', () => {
  // The admin layout navigates to / after logout, once the best-effort Firebase
  // sign-out has settled (auth:signout-settled). Locally that sign-out is fast
  // enough that navigating early on auth:signout still passes here, so the
  // ordering itself is pinned by test/lint/refused_identity_ui_state_test.rb;
  // this checks the end state of an admin logout.
  test('signs out of Rails and Firebase before leaving admin', async ({ page }) => {
    await signIn(page, credentials('ADMIN'));
    expect(await firebaseUserCount(page)).toBeGreaterThan(0);

    await page.goto('/admin');
    await page.getByTitle('Sign out').click();

    await page.waitForURL((url) => url.pathname === '/');
    const names = (await page.context().cookies()).map((cookie) => cookie.name);
    expect(names).not.toContain('tg_session');
    expect(names).not.toContain('tg_uid');
    expect(await firebaseUserCount(page)).toBe(0);
  });
});
