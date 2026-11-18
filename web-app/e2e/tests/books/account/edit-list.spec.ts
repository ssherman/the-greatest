import { test, expect, type Locator, type Page } from '@playwright/test';

// The seeded list (bin/rails e2e:prepare) has 12 books: more than ten, with the count heading above the rows.
// It is recreated with a new id on every run: look it up by name, never by id.
const EDIT_LIST = 'E2E Edit Books';
const READ_LIST = "Books I've Read";
const FAVORITES = 'My Favorite Books';
const MIN_ITEMS = 11;

function rows(page: Page): Locator {
  return page.locator("#edit-list-rows [data-item-id][tabindex='-1']");
}

async function titles(page: Page): Promise<string[]> {
  return (await rows(page).locator('p.font-bold').allInnerTexts()).map((title) => title.trim());
}

// Title of the row holding focus, or null when focus is anywhere else (e.g. <body>).
async function activeItemTitle(page: Page): Promise<string | null> {
  return page.evaluate(() => {
    const el = document.activeElement as HTMLElement | null;
    if (!el?.matches("[data-item-id][tabindex='-1']")) return null;
    return el.querySelector('p.font-bold')?.textContent?.trim() ?? null;
  });
}

// data-item-id of the row holding focus, or null when focus is anywhere else.
async function activeItemId(page: Page): Promise<string | null> {
  return page.evaluate(() => {
    const el = document.activeElement as HTMLElement | null;
    if (!el?.matches("[data-item-id][tabindex='-1']")) return null;
    return el.dataset.itemId ?? null;
  });
}

async function itemCount(page: Page): Promise<number> {
  const text = await page.getByTestId('item-count').innerText();
  return Number(text.match(/^(\d+) books?$/)![1]);
}

async function openEditPage(page: Page, listName: string): Promise<void> {
  await page.goto('/my/lists');
  await page.getByTestId('my-lists-dashboard').getByTestId('user-list-card').filter({ hasText: listName }).click();
  await expect(page.getByRole('heading', { name: listName, level: 1 })).toBeVisible();
  await page.getByTestId('edit-list').click();
  await expect(page.locator('#list-name-heading')).toHaveText(listName);
}

// e2e:prepare removes lists with this prefix on the next run.
async function createList(page: Page, label: string): Promise<string> {
  const name = `E2E Created List ${label} ${Date.now()}`;
  await page.goto('/my/lists');
  await page.getByTestId('new-list-button').click();
  const dialog = page.getByRole('dialog').filter({ hasText: 'New list' });
  await dialog.getByLabel('Name').fill(name);
  await dialog.getByRole('button', { name: 'Create list' }).click();
  await expect(page.getByRole('heading', { name, level: 1 })).toBeVisible();
  return name;
}

function expectedAfterMove(order: string[], from: number, to: number): string[] {
  const next = [...order];
  const [moved] = next.splice(from, 1);
  next.splice(to, 0, moved);
  return next;
}

// SortableJS reacts to pointer movement, so the drag needs real intermediate moves.
async function dragRow(page: Page, from: number, to: number): Promise<void> {
  const list = rows(page);
  const handle = await list.nth(from).locator('[data-sortable-handle]').boundingBox();
  expect(handle).not.toBeNull();

  const x = handle!.x + handle!.width / 2;
  const y = handle!.y + handle!.height / 2;
  const saved = page.waitForResponse((r) => r.request().method() === 'PATCH' && r.url().includes('/position'));
  await page.mouse.move(x, y);
  await page.mouse.down();
  await page.mouse.move(x, y + (to < from ? -8 : 8), { steps: 5 });
  // Visit each row on the way: Sortable ignores a row that is still animating, so a single fast
  // sweep can stop one row short.
  const step = to < from ? -1 : 1;
  for (let i = from + step; i !== to + step; i += step) {
    const box = await list.nth(i).boundingBox();
    await page.mouse.move(x, box!.y + box!.height / 2, { steps: 8 });
    await page.waitForTimeout(250);
  }
  await page.mouse.up();
  expect((await saved).status()).toBe(200);
}

async function openRowMenu(page: Page, title: string): Promise<void> {
  const button = page.getByRole('button', { name: `Actions for ${title}`, exact: true });
  await button.scrollIntoViewIfNeeded();
  await button.click();
}

test.describe('Books Edit list page', () => {
  test('drag reorders on a list of more than ten books, survives a reload, and a second drag still works', async ({ page }) => {
    // Tall enough that every row is on screen: the mouse can only grab what is visible.
    await page.setViewportSize({ width: 1280, height: 1600 });
    await openEditPage(page, EDIT_LIST);
    const total = await itemCount(page);
    expect(total).toBeGreaterThanOrEqual(MIN_ITEMS);
    await expect(rows(page)).toHaveCount(total);

    const original = await titles(page);
    await dragRow(page, 2, 0);
    const afterFirst = expectedAfterMove(original, 2, 0);
    await expect.poll(() => titles(page)).toEqual(afterFirst);

    await page.reload();
    await expect(rows(page)).toHaveCount(total);
    expect(await titles(page)).toEqual(afterFirst);

    await dragRow(page, 1, 5);
    const afterSecond = expectedAfterMove(afterFirst, 1, 5);
    await expect.poll(() => titles(page)).toEqual(afterSecond);

    await page.reload();
    expect(await titles(page)).toEqual(afterSecond);
  });

  test('Move to position moves a book without scrolling or navigating', async ({ page }) => {
    await openEditPage(page, EDIT_LIST);
    const before = await titles(page);
    const moving = before[7];

    await openRowMenu(page, moving);
    await page.evaluate(() => window.scrollBy(0, 150));
    const scrollBefore = await page.evaluate(() => window.scrollY);
    expect(scrollBefore).toBeGreaterThan(0);
    const urlBefore = page.url();

    await rows(page).filter({ hasText: moving }).getByRole('button', { name: 'Move to position…' }).click();
    const dialog = page.locator('dialog#position-dialog');
    await expect(dialog).toBeVisible();
    await dialog.getByLabel(/New position/).fill('2');
    await dialog.getByRole('button', { name: 'Move', exact: true }).click();
    await expect(dialog).toBeHidden();

    await expect.poll(() => titles(page)).toEqual(expectedAfterMove(before, 7, 1));
    expect(page.url()).toBe(urlBefore);
    expect(await page.evaluate(() => window.scrollY)).toBe(scrollBefore);
  });

  test('Move to top from the menu moves the book', async ({ page }) => {
    await openEditPage(page, EDIT_LIST);
    const before = await titles(page);
    const moving = before[4];

    await openRowMenu(page, moving);
    await rows(page).nth(4).getByRole('button', { name: 'Move to top' }).click();
    await expect.poll(() => titles(page)).toEqual(expectedAfterMove(before, 4, 0));
    // The menu must close, not follow the moved row.
    await expect(rows(page).first().getByRole('button', { name: 'Move to top' })).toBeHidden();
    // Focus lands on the moved row, not <body>.
    await expect.poll(() => activeItemTitle(page)).toBe(moving);
  });

  test('menu buttons show a pointer cursor', async ({ page }) => {
    await openEditPage(page, EDIT_LIST);
    const moving = (await titles(page))[2];
    await openRowMenu(page, moving);
    const button = rows(page).nth(2).getByRole('button', { name: 'Move to top' });
    expect(await button.evaluate((el) => getComputedStyle(el).cursor)).toBe('pointer');
  });

  for (const dismiss of ['Escape', 'Cancel']) {
    test(`${dismiss} closes the position dialog without moving, and focus returns to the row`, async ({ page }) => {
      await openEditPage(page, EDIT_LIST);
      const before = await titles(page);
      const moving = before[5];
      const movingId = await rows(page).nth(5).getAttribute('data-item-id');
      const positionPatches: string[] = [];
      page.on('request', (r) => {
        if (r.method() === 'PATCH' && r.url().includes('/position')) positionPatches.push(r.url());
      });

      await openRowMenu(page, moving);
      await rows(page).nth(5).getByRole('button', { name: 'Move to position…' }).click();
      const dialog = page.locator('dialog#position-dialog');
      await expect(dialog).toBeVisible();
      await dialog.getByLabel(/New position/).fill('1');

      if (dismiss === 'Escape') await page.keyboard.press('Escape');
      else await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();

      await expect(dialog).toBeHidden();
      await expect.poll(() => activeItemId(page)).toBe(movingId);
      expect(positionPatches).toEqual([]);
      expect(await titles(page)).toEqual(before);
    });
  }

  test('Remove then Undo returns the book to its place and the count to what it was', async ({ page }) => {
    await openEditPage(page, EDIT_LIST);
    const original = await titles(page);
    const count = await itemCount(page);
    const removed = original[3];

    await page.getByRole('button', { name: `Remove ${removed}`, exact: true }).click();
    await expect(page.getByRole('status').filter({ hasText: `Removed ${removed}` })).toBeVisible();
    await expect.poll(() => itemCount(page)).toBe(count - 1);
    expect(await titles(page)).not.toContain(removed);

    await page.getByRole('status').filter({ hasText: `Removed ${removed}` }).getByRole('button', { name: 'Undo' }).click();
    await expect(page.getByRole('status').filter({ hasText: `Restored ${removed}` })).toBeVisible();
    await expect.poll(() => itemCount(page)).toBe(count);
    expect(await titles(page)).toEqual(original);
  });

  test('Set finished date from the menu on the Read list updates the row in place', async ({ page }) => {
    const book = { path: '/book/headlong-hall', title: 'Headlong Hall' };
    await page.goto(book.path);
    await page.getByRole('button', { name: /^(Add to list|On \d+ lists?)$/ }).first().click();
    const widget = page.getByRole('dialog').filter({ hasText: 'Your lists' });
    const checkbox = widget.getByRole('checkbox', { name: READ_LIST, exact: true });
    await expect(checkbox).toBeVisible();
    await checkbox.check();
    await expect(checkbox).toBeEnabled();
    await expect(checkbox).toBeChecked();

    try {
      await openEditPage(page, READ_LIST);
      const row = rows(page).filter({ hasText: book.title });
      await expect(row).toHaveCount(1);
      const urlBefore = page.url();

      await openRowMenu(page, book.title);
      await row.getByRole('button', { name: /^Set finished date/ }).click();
      const dialog = page.getByRole('dialog', { name: `Edit completion date for ${book.title}` });
      await expect(dialog).toBeVisible();
      await dialog.getByLabel('Completion date').fill('2024-03-05');
      await dialog.getByRole('button', { name: 'Save', exact: true }).click();

      await expect(dialog).not.toBeVisible();
      await expect(row).toContainText(/Mar(ch)? 5, 2024/);
      expect(page.url()).toBe(urlBefore);
    } finally {
      // Leave the account as we found it.
      await openEditPage(page, READ_LIST);
      const leftover = page.getByRole('button', { name: `Remove ${book.title}`, exact: true });
      if (await leftover.count()) await leftover.click();
      await expect(leftover).toHaveCount(0);
    }
  });

  test('renaming a custom list saves', async ({ page }) => {
    const name = await createList(page, 'rename');
    const renamed = `${name} renamed`;
    await page.getByTestId('edit-list').click();

    await page.getByLabel('Name', { exact: true }).fill(renamed);
    await page.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(page.getByRole('status').filter({ hasText: 'Saved' })).toBeVisible();

    await page.reload();
    await expect(page.getByLabel('Name', { exact: true })).toHaveValue(renamed);
  });

  test('a built-in list name is not editable and has no Delete', async ({ page }) => {
    await openEditPage(page, FAVORITES);

    await expect(page.getByLabel('Name', { exact: true })).toBeDisabled();
    await expect(page.getByText('Built-in lists keep their names.')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Delete list' })).toHaveCount(0);
  });

  test('deleting a custom list returns to the dashboard without it', async ({ page }) => {
    const name = await createList(page, 'delete');
    await page.getByTestId('edit-list').click();

    page.once('dialog', (dialog) => dialog.accept());
    await page.getByRole('button', { name: 'Delete list' }).click();

    await expect(page).toHaveURL(/\/my\/lists$/);
    await expect(page.getByTestId('my-lists-dashboard')).toBeVisible();
    await expect(page.getByTestId('my-lists-dashboard').getByText(name)).toHaveCount(0);
  });
});

test.describe('Books Edit list page on a phone', () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true });

  test('shows a drag handle and Move to top works from the menu', async ({ page }) => {
    await openEditPage(page, EDIT_LIST);
    await expect(rows(page).first().locator('[data-sortable-handle]')).toBeVisible();

    const before = await titles(page);
    await openRowMenu(page, before[3]);
    await rows(page).nth(3).getByRole('button', { name: 'Move to top' }).tap();
    await expect.poll(() => titles(page)).toEqual(expectedAfterMove(before, 3, 0));
    // Touch dragging itself is not exercised: Playwright has no touch-drag primitive for SortableJS.
  });

  test('the finished date stays fully visible on a Read-list row', async ({ page }) => {
    const book = { path: '/book/headlong-hall', title: 'Headlong Hall' };
    await page.goto(book.path);
    await page.getByRole('button', { name: /^(Add to list|On \d+ lists?)$/ }).first().click();
    const widget = page.getByRole('dialog').filter({ hasText: 'Your lists' });
    const checkbox = widget.getByRole('checkbox', { name: READ_LIST, exact: true });
    await expect(checkbox).toBeVisible();
    await checkbox.check();
    await expect(checkbox).toBeEnabled();
    await expect(checkbox).toBeChecked();

    try {
      await openEditPage(page, READ_LIST);
      const row = rows(page).filter({ hasText: book.title });
      await expect(row).toHaveCount(1);
      await openRowMenu(page, book.title);
      await row.getByRole('button', { name: /^Set finished date/ }).tap();
      const dialog = page.getByRole('dialog', { name: `Edit completion date for ${book.title}` });
      await dialog.getByLabel('Completion date').fill('2024-03-05');
      await dialog.getByRole('button', { name: 'Save', exact: true }).tap();
      await expect(dialog).not.toBeVisible();

      const date = row.getByText(/Mar(ch)? 5, 2024/);
      await expect(date).toBeVisible();
      await expect(date).toBeInViewport({ ratio: 1 });
      // Not clipped by its own by-line: the text is not wider than the box that holds it.
      const clipped = await date.evaluate((el) => el.parentElement!.scrollWidth > el.parentElement!.clientWidth);
      expect(clipped).toBe(false);
    } finally {
      await openEditPage(page, READ_LIST);
      const leftover = page.getByRole('button', { name: `Remove ${book.title}`, exact: true });
      if (await leftover.count()) await leftover.tap();
      await expect(leftover).toHaveCount(0);
    }
  });
});
