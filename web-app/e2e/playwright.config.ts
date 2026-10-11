import { defineConfig, devices } from '@playwright/test';
import dotenv from 'dotenv';
import path from 'path';

dotenv.config({ path: path.resolve(__dirname, '.env') });

const BOOKS = 'https://dev-new.thegreatestbooks.org';
const MUSIC = 'https://dev.thegreatestmusic.org';
const GAMES = 'https://dev.thegreatest.games';

const auth = (file: string) => path.join(__dirname, '.auth', file);
const musicAdmin = auth('user.json');
const gamesAdmin = auth('games-user.json');
const booksAdmin = auth('books-user.json');
const booksUser = auth('books-normal-user.json');
const booksMember = auth('books-member.json');

// Every test project depends on `seed`, and `seed` depends on the five
// sign-ins, so a run always goes: sign in (creates the User rows) ->
// bin/rails e2e:prepare (roles, membership, seed data, manifest) -> tests.
// Playwright runs a project's dependencies even when a single spec file is
// named on the command line, so nothing ever runs against unprepared state.
const SIGN_INS = ['setup', 'games-setup', 'books-setup', 'books-user-setup', 'books-member-setup'];

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
    { name: 'setup', testDir: './auth', testMatch: 'auth.setup.ts', use: { baseURL: MUSIC } },
    { name: 'games-setup', testDir: './auth', testMatch: 'games-auth.setup.ts', use: { baseURL: GAMES } },
    { name: 'books-setup', testDir: './auth', testMatch: 'books-auth.setup.ts', use: { baseURL: BOOKS } },
    { name: 'books-user-setup', testDir: './auth', testMatch: 'books-user-auth.setup.ts', use: { baseURL: BOOKS } },
    { name: 'books-member-setup', testDir: './auth', testMatch: 'books-member-auth.setup.ts', use: { baseURL: BOOKS } },
    { name: 'seed', testDir: './auth', testMatch: 'seed.setup.ts', dependencies: SIGN_INS },
    {
      // Music. Not renamed: docs and memory refer to --project=chromium.
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], baseURL: MUSIC, storageState: musicAdmin },
      testMatch: /music\/.*/,
      dependencies: ['seed'],
    },
    {
      name: 'games',
      use: { ...devices['Desktop Chrome'], baseURL: GAMES, storageState: gamesAdmin },
      testMatch: /games\/.*/,
      dependencies: ['seed'],
    },
    {
      name: 'books',
      use: { ...devices['Desktop Chrome'], baseURL: BOOKS },
      testMatch: /books\/(?!admin\/)(?!account\/)(?!member\/).*/,
      dependencies: ['seed'],
    },
    {
      name: 'books-admin',
      use: { ...devices['Desktop Chrome'], baseURL: BOOKS, storageState: booksAdmin },
      testMatch: /books\/admin\/.*/,
      dependencies: ['seed'],
    },
    {
      name: 'books-account',
      use: { ...devices['Desktop Chrome'], baseURL: BOOKS, storageState: booksUser },
      testMatch: /books\/account\/.*/,
      dependencies: ['seed'],
    },
    {
      name: 'books-member',
      use: { ...devices['Desktop Chrome'], baseURL: BOOKS, storageState: booksMember },
      testMatch: /books\/member\/.*/,
      dependencies: ['seed'],
    },
  ],
});
