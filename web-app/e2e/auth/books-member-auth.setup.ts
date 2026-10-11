import { test as setup } from '@playwright/test';
import path from 'path';
import { credentials, signInAndSave } from '../support/sign-in';

// The member: a plain user that e2e:prepare comps on every run. Drives the
// books-member project.
setup('sign in the member on books', async ({ page }) => {
  await signInAndSave(page, credentials('MEMBER'), path.join(__dirname, '..', '.auth', 'books-member.json'));
});
