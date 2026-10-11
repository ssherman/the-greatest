import { test as setup } from '@playwright/test';
import path from 'path';
import { credentials, signInAndSave } from '../support/sign-in';

// The normal user: signed in, never an admin, never a member. Drives the
// books-account project. e2e:prepare enforces both "nevers" on every run.
setup('sign in the normal user on books', async ({ page }) => {
  await signInAndSave(page, credentials('USER'), path.join(__dirname, '..', '.auth', 'books-normal-user.json'));
});
