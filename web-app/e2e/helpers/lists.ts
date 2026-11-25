import { Page } from '@playwright/test';

// A list nothing lowers has no breakdown to open, so walk the lists index and
// stop on the first list that has one.
export async function openListWithBreakdown(page: Page) {
  await page.goto('/lists');

  const hrefs = await page.locator('.card h3 a').evaluateAll((links) =>
    links.map((a) => (a as HTMLAnchorElement).getAttribute('href')).filter(Boolean) as string[]
  );

  for (const href of hrefs) {
    await page.goto(href);
    if (await page.getByText('See how this was worked out').isVisible()) return;
  }

  throw new Error(`No list on /lists had a breakdown to open (checked ${hrefs.length})`);
}
