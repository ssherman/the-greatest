import { test as setup } from '@playwright/test';
import path from 'path';
import { credentials, signInAndSave } from '../support/sign-in';

setup('sign in the admin on books', async ({ page }) => {
  await signInAndSave(page, credentials('ADMIN'), path.join(__dirname, '..', '.auth', 'books-user.json'));
});
