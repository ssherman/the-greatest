import type { Page, Request } from '@playwright/test';

const STATE_PATHS = ['/user_list_state', '/membership_state', '/review_state'];

export type StateRequests = {
  // Number of requests seen so far, optionally narrowed to one path.
  get(path?: string): number;
  requests(path?: string): Request[];
};

// Records requests to the Rails per-user state endpoints from the moment it is
// attached. Matches on pathname so a query string cannot hide a request.
export function countStateRequests(page: Page): StateRequests {
  const seen: Request[] = [];
  page.on('request', (request) => {
    if (STATE_PATHS.includes(new URL(request.url()).pathname)) seen.push(request);
  });
  const select = (path?: string) => (path ? seen.filter((r) => new URL(r.url()).pathname === path) : seen);
  return { get: (path) => select(path).length, requests: (path) => [...select(path)] };
}

// Rewrites the cached entry's checkedAt so the next page load sees it as `ms`
// old. Fails loudly when there is no entry, so a test cannot "age" nothing.
export async function ageCache(page: Page, ms: number): Promise<void> {
  const aged = await page.evaluate((age) => {
    const key = Object.keys(localStorage).find((k) => k.startsWith('tg:user_list_state:'));
    if (!key) return false;
    const entry = JSON.parse(localStorage.getItem(key)!);
    entry.checkedAt = Date.now() - age;
    localStorage.setItem(key, JSON.stringify(entry));
    return true;
  }, ms);
  if (!aged) throw new Error('ageCache: no tg:user_list_state entry in localStorage');
}

// The cached entry, or null.
export async function cachedEntry(page: Page): Promise<Record<string, any> | null> {
  return page.evaluate(() => {
    const key = Object.keys(localStorage).find((k) => k.startsWith('tg:user_list_state:'));
    return key ? JSON.parse(localStorage.getItem(key)!) : null;
  });
}

// Lets in-flight requests finish so a count read afterwards is final, not a
// snapshot taken while a state request was still about to be sent.
export async function settle(page: Page): Promise<void> {
  await page.waitForLoadState('networkidle');
}
