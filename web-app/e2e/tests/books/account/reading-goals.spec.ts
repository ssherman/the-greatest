import { test, expect, type Locator, type Page } from '@playwright/test';

const BASE_URL = 'https://dev-new.thegreatestbooks.org';
const READING_LIST = "Books I'm Reading";
const READ_LIST = "Books I've Read";
const FIRST_BOOK = { path: '/book/nightmare-abbey', title: 'Nightmare Abbey' };
const SECOND_BOOK = { path: '/book/war-and-peace', title: 'War and Peace' };
const TARGET_COUNT = 5;

const runId = Date.now();
const publicGoalName = `E2E reading goal ${runId}`;
const privateGoalName = `E2E private goal ${runId}`;
const publicDescription = 'A public E2E goal projected from completed Read-list books.';

let publicGoalId: string;
let privateGoalId: string;
let baselineCount: number;

function isoDate(offsetDays: number): string {
  const date = new Date();
  date.setUTCDate(date.getUTCDate() + offsetDays);
  return date.toISOString().slice(0, 10);
}

function longDate(value: string): string {
  return new Intl.DateTimeFormat('en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    timeZone: 'UTC',
  }).format(new Date(`${value}T00:00:00Z`));
}

const today = isoDate(0);
const inRangeDate = isoDate(-1);
const outOfRangeDate = isoDate(-2);
const currentYear = today.slice(0, 4);
const initialStart = `${currentYear}-01-01`;
const initialEnd = `${currentYear}-12-31`;

function goalCard(page: Page, name: string): Locator {
  return page.getByRole('article').filter({ hasText: name });
}

async function progressCount(scope: Page | Locator): Promise<number> {
  const text = await scope.getByText(/\d+ of \d+ books/).first().innerText();
  const match = text.match(/^(\d+) of \d+ books$/);
  expect(match, `expected a progress count in ${JSON.stringify(text)}`).not.toBeNull();
  return Number(match![1]);
}

async function openListDialog(page: Page, book: { path: string; title: string }): Promise<Locator> {
  await page.goto(book.path);
  await page.getByRole('button', { name: /^(Add to list|On \d+ lists)$/ }).first().click();

  const dialog = page.getByRole('dialog').filter({ hasText: 'Your lists' });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByText(book.title, { exact: true })).toBeVisible();
  await expect(dialog.getByLabel('Completion date')).toHaveCount(0);
  return dialog;
}

async function setListMembership(
  page: Page,
  dialog: Locator,
  listName: string,
  checked: boolean,
  expectedMessage: string,
): Promise<void> {
  const checkbox = dialog.getByRole('checkbox', { name: listName, exact: true });
  await expect(checkbox).toBeVisible();
  await checkbox.setChecked(checked);
  await expect(checkbox).toBeEnabled();
  await expect(page.getByRole('status').filter({ hasText: expectedMessage })).toBeVisible();
  await expect(checkbox).toBeChecked({ checked });
}

async function visitReadList(page: Page): Promise<void> {
  await page.goto('/my/lists');
  const dashboard = page.getByTestId('my-lists-dashboard');
  await dashboard.getByTestId('user-list-card').filter({ hasText: READ_LIST }).click();
  await expect(page.getByRole('heading', { name: READ_LIST, level: 1 })).toBeVisible();
}

async function completionDialog(page: Page, title: string): Promise<{ dialog: Locator; trigger: Locator; input: Locator }> {
  const trigger = page.getByRole('button', { name: `Edit completion date for ${title}`, exact: true });
  await trigger.click();

  const dialog = page.getByRole('dialog', { name: `Edit completion date for ${title}` });
  const input = dialog.getByLabel('Completion date');
  await expect(dialog).toBeVisible();
  await expect(input).toBeFocused();
  return { dialog, trigger, input };
}

async function submitCompletionDate(page: Page, title: string, completedOn: string | null): Promise<void> {
  const { dialog, input } = await completionDialog(page, title);
  const response = page.waitForResponse(
    (candidate) => candidate.request().method() === 'PATCH' && candidate.url().includes('/user_list_items/'),
  );

  if (completedOn === null) {
    await dialog.getByRole('button', { name: 'Clear date', exact: true }).click();
  } else {
    await input.fill(completedOn);
    await dialog.getByRole('button', { name: 'Save', exact: true }).click();
  }

  expect((await response).status()).toBe(303);
  await expect(page.getByRole('heading', { name: READ_LIST, level: 1 })).toBeVisible();
  await expect(dialog).not.toBeVisible();
}

async function expectGoalProjection(
  page: Page,
  count: number,
  bookTitle: string,
  completedOn: string | null,
): Promise<void> {
  await page.goto(`/reading_goals/${publicGoalId}`);
  await expect(page.getByText(`${count} of ${TARGET_COUNT} books`, { exact: true })).toBeVisible();

  const bookLink = page.getByRole('link', { name: bookTitle, exact: true });
  if (completedOn === null) {
    await expect(bookLink).toHaveCount(0);
  } else {
    await expect(bookLink).toBeVisible();
    await expect(page.getByText(`Completed ${longDate(completedOn)}`, { exact: true })).toBeVisible();
  }
}

async function deleteGoal(page: Page, name: string): Promise<void> {
  const card = goalCard(page, name);
  await expect(card).toBeVisible();
  page.once('dialog', async (dialog) => {
    expect(dialog.message()).toBe('Delete this reading goal? This cannot be undone.');
    await dialog.accept();
  });
  await card.getByRole('button', { name: 'Delete', exact: true }).click();
  await expect(goalCard(page, name)).toHaveCount(0);
}

test.describe.serial('Books reading goals lifecycle', () => {
  test('an owner manages a goal through canonical Read-list completion dates', async ({ page }) => {
    await page.goto('/');
    const mainNavigation = page.getByRole('navigation', { name: 'Main' });
    await mainNavigation.getByText('My Books', { exact: true }).click();
    await mainNavigation.getByRole('link', { name: 'Reading Goals', exact: true }).click();

    await expect(page.getByRole('heading', { name: 'Reading Goals', level: 1 })).toBeVisible();
    await page.getByRole('link', { name: 'New Reading Goal', exact: true }).click();
    await expect(page.getByRole('heading', { name: 'New Reading Goal', level: 1 })).toBeVisible();

    await page.getByLabel('Name').fill(publicGoalName);
    await page.getByLabel('Description').fill('A private current-year E2E goal.');
    await page.getByLabel('Target books').fill('4');
    await expect(page.getByLabel('Start date')).toHaveValue(initialStart);
    await expect(page.getByLabel('End date')).toHaveValue(initialEnd);
    await expect(page.getByLabel('Public')).not.toBeChecked();
    await page.getByRole('button', { name: 'Create Reading Goal', exact: true }).click();

    await expect(page.getByRole('heading', { name: 'Active goals', level: 2 })).toBeVisible();
    let card = goalCard(page, publicGoalName);
    await expect(card).toBeVisible();
    await expect(card.getByText('Private', { exact: true })).toBeVisible();
    await expect(card.getByText(`${longDate(initialStart)} – ${longDate(initialEnd)}`, { exact: true })).toBeVisible();

    const publicHref = await card.getByRole('link', { name: publicGoalName, exact: true }).getAttribute('href');
    const publicIdMatch = publicHref?.match(/^\/reading_goals\/(\d+)$/);
    expect(publicIdMatch).not.toBeNull();
    publicGoalId = publicIdMatch![1];

    await card.getByRole('link', { name: 'Edit', exact: true }).click();
    await page.getByLabel('Description').fill(publicDescription);
    await page.getByLabel('Target books').fill(String(TARGET_COUNT));
    await page.getByLabel('Start date').fill(inRangeDate);
    await page.getByLabel('End date').fill(today);
    await page.getByLabel('Public').check();
    await page.getByRole('button', { name: 'Save Changes', exact: true }).click();

    card = goalCard(page, publicGoalName);
    await expect(card.getByText('Public', { exact: true })).toBeVisible();
    await expect(card.getByText(`${longDate(inRangeDate)} – ${longDate(today)}`, { exact: true })).toBeVisible();
    baselineCount = await progressCount(card);

    const shareSource = card.getByLabel('Share link');
    await expect(shareSource).toHaveValue(`${BASE_URL}/reading_goals/${publicGoalId}`);
    await card.getByRole('button', { name: 'Copy Share Link', exact: true }).click();
    await expect(card.getByRole('button', { name: 'Copied!', exact: true })).toBeFocused();

    let listDialog = await openListDialog(page, FIRST_BOOK);
    const reading = listDialog.getByRole('checkbox', { name: READING_LIST, exact: true });
    const read = listDialog.getByRole('checkbox', { name: READ_LIST, exact: true });
    await expect(reading).not.toBeChecked();
    await expect(read).not.toBeChecked();

    await setListMembership(page, listDialog, READING_LIST, true, `Added to ${READING_LIST}`);
    await expect(reading).toBeChecked();
    await expect(read).not.toBeChecked();

    await setListMembership(
      page,
      listDialog,
      READ_LIST,
      true,
      `Moved to ${READ_LIST} and marked completed today`,
    );
    await expect(reading).not.toBeChecked();
    await expect(read).toBeChecked();
    await page.keyboard.press('Escape');
    await expect(listDialog).not.toBeVisible();

    await expectGoalProjection(page, baselineCount + 1, FIRST_BOOK.title, today);
    await expect(page.getByRole('link', { name: 'Manage', exact: true })).toHaveAttribute(
      'href',
      `/my/reading-goals/${publicGoalId}/edit`,
    );

    await visitReadList(page);
    let completion = await completionDialog(page, FIRST_BOOK.title);
    await expect(completion.input).toHaveValue(today);
    await page.keyboard.press('Escape');
    await expect(completion.dialog).not.toBeVisible();
    await expect(completion.trigger).toBeFocused();

    completion = await completionDialog(page, FIRST_BOOK.title);
    await completion.dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
    await expect(completion.dialog).not.toBeVisible();
    await expect(completion.trigger).toBeFocused();

    await submitCompletionDate(page, FIRST_BOOK.title, inRangeDate);
    await expectGoalProjection(page, baselineCount + 1, FIRST_BOOK.title, inRangeDate);

    await visitReadList(page);
    await submitCompletionDate(page, FIRST_BOOK.title, outOfRangeDate);
    await expectGoalProjection(page, baselineCount, FIRST_BOOK.title, null);

    await visitReadList(page);
    await submitCompletionDate(page, FIRST_BOOK.title, null);
    await expectGoalProjection(page, baselineCount, FIRST_BOOK.title, null);

    await visitReadList(page);
    await submitCompletionDate(page, FIRST_BOOK.title, inRangeDate);
    await expectGoalProjection(page, baselineCount + 1, FIRST_BOOK.title, inRangeDate);

    listDialog = await openListDialog(page, FIRST_BOOK);
    await setListMembership(page, listDialog, READ_LIST, false, `Removed from ${READ_LIST}`);
    await page.keyboard.press('Escape');
    await expectGoalProjection(page, baselineCount, FIRST_BOOK.title, null);

    listDialog = await openListDialog(page, SECOND_BOOK);
    await expect(listDialog.getByRole('checkbox', { name: READING_LIST, exact: true })).not.toBeChecked();
    await expect(listDialog.getByRole('checkbox', { name: READ_LIST, exact: true })).not.toBeChecked();
    await setListMembership(
      page,
      listDialog,
      READ_LIST,
      true,
      `Added to ${READ_LIST}. Mark it completed to make it count toward your reading goals.`,
    );
    await page.keyboard.press('Escape');

    await visitReadList(page);
    completion = await completionDialog(page, SECOND_BOOK.title);
    await expect(completion.input).toHaveValue('');
    await completion.input.fill(inRangeDate);
    const completionResponse = page.waitForResponse(
      (candidate) => candidate.request().method() === 'PATCH' && candidate.url().includes('/user_list_items/'),
    );
    await completion.dialog.getByRole('button', { name: 'Save', exact: true }).click();
    expect((await completionResponse).status()).toBe(303);
    await expectGoalProjection(page, baselineCount + 1, SECOND_BOOK.title, inRangeDate);

    await page.goto('/my/reading-goals/new');
    await page.getByLabel('Name').fill(privateGoalName);
    await page.getByRole('button', { name: 'Create Reading Goal', exact: true }).click();

    const privateCard = goalCard(page, privateGoalName);
    await expect(privateCard.getByText('Private', { exact: true })).toBeVisible();
    const privateHref = await privateCard.getByRole('link', { name: privateGoalName, exact: true }).getAttribute('href');
    const privateIdMatch = privateHref?.match(/^\/reading_goals\/(\d+)$/);
    expect(privateIdMatch).not.toBeNull();
    privateGoalId = privateIdMatch![1];
  });

  test('anonymous visibility, responsive My Books navigation, and cleanup are correct', async ({ page, browser }) => {
    expect(publicGoalId).toMatch(/^\d+$/);
    expect(privateGoalId).toMatch(/^\d+$/);

    const anonymous = await browser.newContext({ baseURL: BASE_URL, ignoreHTTPSErrors: true });
    const anonymousPage = await anonymous.newPage();
    try {
      const publicResponse = await anonymousPage.goto(`/reading_goals/${publicGoalId}`);
      expect(publicResponse?.status()).toBe(200);
      await expect(anonymousPage.getByRole('heading', { name: publicGoalName, level: 1 })).toBeVisible();
      await expect(anonymousPage.getByText(/^A reading goal by .+$/)).toBeVisible();
      await expect(anonymousPage.getByText(publicDescription, { exact: true })).toBeVisible();
      await expect(
        anonymousPage.getByText(`${longDate(inRangeDate)} – ${longDate(today)}`, { exact: true }),
      ).toBeVisible();
      await expect(
        anonymousPage.getByText(`${baselineCount + 1} of ${TARGET_COUNT} books`, { exact: true }),
      ).toBeVisible();
      await expect(anonymousPage.getByRole('link', { name: SECOND_BOOK.title, exact: true })).toBeVisible();
      await expect(
        anonymousPage.getByText(`Completed ${longDate(inRangeDate)}`, { exact: true }),
      ).toBeVisible();
      await expect(anonymousPage.getByRole('link', { name: 'Manage', exact: true })).toHaveCount(0);

      const privateResponse = await anonymousPage.goto(`/reading_goals/${privateGoalId}`);
      expect(privateResponse?.status()).toBe(404);
    } finally {
      await anonymous.close();
    }

    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto('/');
    const mainNavigation = page.getByRole('navigation', { name: 'Main' });
    await mainNavigation.getByText('My Books', { exact: true }).click();
    await expect(
      mainNavigation.getByRole('link', { name: /^(Lists|Reading Goals|Reviews|Saved Searches)$/ }),
    ).toHaveText(['Lists', 'Reading Goals', 'Reviews', 'Saved Searches']);

    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/');
    await page.getByLabel('Open navigation menu').click();
    const mobileMyBooks = page.getByRole('listitem')
      .filter({ has: page.getByText('My Books', { exact: true }), visible: true })
      .filter({ has: page.getByRole('link', { name: 'Reading Goals', exact: true }) });
    await expect(mobileMyBooks.getByText('My Books', { exact: true })).toBeVisible();
    await expect(mobileMyBooks.getByRole('button', { name: 'My Books', exact: true })).toHaveCount(0);
    await expect(
      mobileMyBooks.getByRole('link', { name: /^(Lists|Reading Goals|Reviews|Saved Searches)$/ }),
    ).toHaveText(['Lists', 'Reading Goals', 'Reviews', 'Saved Searches']);

    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto('/my/reading-goals');
    await deleteGoal(page, publicGoalName);
    await deleteGoal(page, privateGoalName);

    const cleanupDialog = await openListDialog(page, SECOND_BOOK);
    await setListMembership(page, cleanupDialog, READ_LIST, false, `Removed from ${READ_LIST}`);
    await page.keyboard.press('Escape');
    await expect(cleanupDialog).not.toBeVisible();

    const firstBookDialog = await openListDialog(page, FIRST_BOOK);
    await expect(firstBookDialog.getByRole('checkbox', { name: READING_LIST, exact: true })).not.toBeChecked();
    await expect(firstBookDialog.getByRole('checkbox', { name: READ_LIST, exact: true })).not.toBeChecked();
    await page.keyboard.press('Escape');
  });
});
