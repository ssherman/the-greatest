import { defineConfig, devices } from '@playwright/test';
import dotenv from 'dotenv';
import path from 'path';

dotenv.config({ path: path.resolve(__dirname, '.env') });

const musicAuthFile = path.join(__dirname, '.auth', 'user.json');
const gamesAuthFile = path.join(__dirname, '.auth', 'games-user.json');
const booksAuthFile = path.join(__dirname, '.auth', 'books-user.json');

export default defineConfig({
  testDir: './tests',
  fullyParallel: false,
  retries: 0,
  workers: 1,
  reporter: 'html',
  use: {
    ignoreHTTPSErrors: true,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: { mode: 'retain-on-failure' },
  },
  projects: [
    { name: 'setup', testDir: './auth', testMatch: 'auth.setup.ts', use: { baseURL: 'https://dev.thegreatestmusic.org' } },
    { name: 'games-setup', testDir: './auth', testMatch: 'games-auth.setup.ts' },
    { name: 'books-setup', testDir: './auth', testMatch: 'books-auth.setup.ts' },
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        baseURL: 'https://dev.thegreatestmusic.org',
        storageState: musicAuthFile,
      },
      testMatch: /music\/.*/,
      dependencies: ['setup'],
    },
    {
      name: 'games',
      use: {
        ...devices['Desktop Chrome'],
        baseURL: 'https://dev.thegreatest.games',
        storageState: gamesAuthFile,
      },
      testMatch: /games\/.*/,
      dependencies: ['games-setup'],
    },
    {
      name: 'books',
      use: {
        ...devices['Desktop Chrome'],
        baseURL: 'https://dev-new.thegreatestbooks.org',
      },
      testMatch: /books\/(?!admin\/).*/,
    },
    {
      name: 'books-admin',
      use: {
        ...devices['Desktop Chrome'],
        baseURL: 'https://dev-new.thegreatestbooks.org',
        storageState: booksAuthFile,
      },
      testMatch: /books\/admin\/.*/,
      dependencies: ['books-setup'],
    },
  ],
});
