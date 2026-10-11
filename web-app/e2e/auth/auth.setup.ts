import { test as setup } from '@playwright/test';
import path from 'path';
import { credentials, signInAndSave } from '../support/sign-in';

setup('sign in the admin on music', async ({ page }) => {
  await signInAndSave(page, credentials('ADMIN'), path.join(__dirname, '..', '.auth', 'user.json'));
});
