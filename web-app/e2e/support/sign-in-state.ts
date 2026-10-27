import { expect, type Page } from '@playwright/test';

// Every visible sign-in indicator must agree, so each assertion checks the
// navbar button's state attribute AND the signed-in nav link. Books renders its
// link twice (desktop nav and drawer), hence the :visible filter and counts.
async function myLink(page: Page): Promise<string> {
  return (await page.locator('#navbar_my_books').count()) > 0 ? '#navbar_my_books' : '#navbar_my_lists';
}

export async function expectSignedIn(page: Page): Promise<void> {
  const button = page.locator('#navbar_login_button');
  await expect(button).toHaveAttribute('data-auth-state', 'signed-in', { timeout: 15_000 });
  await expect(page.locator(`${await myLink(page)}:visible`)).not.toHaveCount(0);
}

export async function expectSignedOut(page: Page): Promise<void> {
  const button = page.locator('#navbar_login_button');
  await expect(button).toHaveAttribute('data-auth-state', 'signed-out', { timeout: 15_000 });
  await expect(page.locator(`${await myLink(page)}:visible`)).toHaveCount(0);
}

// Counts the users Firebase remembers in this browser (IndexedDB is not part of
// Playwright's storage state, so it only exists after a real sign-in).
export async function firebaseUserCount(page: Page): Promise<number> {
  return page.evaluate(
    () =>
      new Promise<number>((resolve) => {
        const open = indexedDB.open('firebaseLocalStorageDb');
        open.onerror = () => resolve(0);
        open.onsuccess = () => {
          const db = open.result;
          if (!db.objectStoreNames.contains('firebaseLocalStorage')) {
            db.close();
            resolve(0);
            return;
          }
          const count = db.transaction('firebaseLocalStorage').objectStore('firebaseLocalStorage').count();
          count.onsuccess = () => {
            db.close();
            resolve(count.result);
          };
          count.onerror = () => {
            db.close();
            resolve(0);
          };
        };
      })
  );
}
