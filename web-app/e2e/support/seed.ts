import fs from 'node:fs';
import path from 'node:path';

export type SeedManifest = {
  generated_at: string;
  users: Record<'admin' | 'user' | 'member', { id: number; email: string }>;
  lists: { public_books: number; private_books: number };
};

const MANIFEST = path.join(__dirname, '..', '.auth', 'seed.json');

// Written by `bin/rails e2e:prepare` (the `seed` project). Read it inside a
// test or beforeAll, never at module top level: Playwright loads every spec
// file before any project runs, so a top-level read would throw on a fresh
// checkout before the seed project had a chance to write it.
export function seed(): SeedManifest {
  if (!fs.existsSync(MANIFEST)) {
    throw new Error(
      `${MANIFEST} is missing. The seed project writes it; yarn test:e2e runs that project automatically, ` +
        `and a single-file run still runs it because every project depends on it.`
    );
  }
  return JSON.parse(fs.readFileSync(MANIFEST, 'utf8')) as SeedManifest;
}
