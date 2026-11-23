import { test, expect } from "@playwright/test";

test.describe("Books admin — lists", () => {
  test("lists index and links to New List", async ({ page }) => {
    await page.goto("/admin/lists");
    await expect(page.getByRole("heading", { name: "Book Lists", level: 1 })).toBeVisible();
  });

  test("creates a list and shows its Launch Wizard link", async ({ page }) => {
    const name = `E2E List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: /Launch Wizard/ })).toHaveAttribute("href", /\/admin\/lists\/\d+\/wizard$/);
  });

  test("edits a list name", async ({ page }) => {
    const name = `E2E Edit List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    await page.getByRole("link", { name: "Edit" }).click();
    await expect(page).toHaveURL(/\/edit/);
    const updated = `E2E Updated List ${Date.now()}`;
    await page.locator('input[name="books_list[name]"]').fill(updated);
    await page.getByRole("button", { name: "Update Book List" }).click();
    await expect(page.getByRole("heading", { name: updated, level: 1 })).toBeVisible();
  });

  test("deletes a list", async ({ page }) => {
    const name = `E2E Delete List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    await expect(page).toHaveURL(/\/admin\/lists$/);
  });

  test("flags a list as needing item revision, filters on it, clears it through the form", async ({ page }) => {
    const name = `E2E Revision List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByLabel("Items Need Revision").check();
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    await expect(page.getByTestId("items-need-revision-badge")).toBeVisible();
    const id = page.url().match(/\/admin\/lists\/(\d+)/)?.[1];
    try {
      expect(id).toBeTruthy();
      await page.goto(`/admin/lists?items_need_revision=1&q=${encodeURIComponent(name)}&status=all`);
      await expect(page.getByRole("link", { name })).toBeVisible();

      await page.goto(`/admin/lists/${id}/edit`);
      await page.getByLabel("Items Need Revision").uncheck();
      await page.getByRole("button", { name: "Update Book List" }).click();
      await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
      await expect(page.getByTestId("items-need-revision-badge")).toHaveCount(0);

      await page.goto(`/admin/lists?items_need_revision=1&q=${encodeURIComponent(name)}&status=all`);
      await expect(page.getByRole("link", { name })).toHaveCount(0);
    } finally {
      if (id) {
        await page.goto(`/admin/lists/${id}`);
        page.on("dialog", (d) => d.accept());
        await page.getByRole("button", { name: "Delete" }).click();
        await expect(page).toHaveURL(/\/admin\/lists$/);
      }
    }
  });

  test("attaches and detaches a penalty via the modal", async ({ page }) => {
    const name = `E2E Penalty List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    await page.getByRole("button", { name: "+ Attach Penalty" }).click();
    const modal = page.locator("#attach_penalty_modal_dialog");
    await expect(modal).toBeVisible();
    const select = modal.locator('select[name="list_penalty[penalty_id]"]');
    const firstText = await select.locator('option:not([value=""])').first().innerText();
    await select.selectOption({ index: 1 });
    await modal.getByRole("button", { name: "Attach Penalty" }).click();

    const frame = page.locator("turbo-frame#list_penalties_list");
    await expect(frame.getByText(firstText)).toBeVisible({ timeout: 10000 });

    page.on("dialog", (d) => d.accept());
    await frame.getByRole("button", { name: "Delete" }).click();
    await expect(frame.getByText("No penalties attached to this list yet.")).toBeVisible({ timeout: 10000 });
  });

  test("records who voted and shows it on the admin and public list pages", async ({ page }) => {
    const name = `E2E Voters List ${Date.now()}`;
    // Over 600 characters, so the public page folds it into a disclosure.
    const roster = Array.from({ length: 40 }, (_, i) => `Voter ${i + 1}, critic`).join("\n");
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.locator('textarea[name="books_list[voter_details]"]').fill(roster);
    await page.locator('select[name="books_list[status]"]').selectOption("active");
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    await expect(page.getByTestId("admin-list-voter-details")).toContainText("Voter 40, critic");
    const id = page.url().match(/\/admin\/lists\/(\d+)/)?.[1];
    expect(id).toBeTruthy();

    try {
      await page.goto(`/lists/${id}`);
      const section = page.getByTestId("list-voter-details");
      await expect(section.getByRole("heading", { name: "Who voted" })).toBeVisible();
      await expect(section.getByText("Voter 40, critic")).toBeHidden();
      await section.getByText("Show voters and how they were chosen").click();
      await expect(section.getByText("Voter 40, critic")).toBeVisible();
    } finally {
      await page.goto(`/admin/lists/${id}`);
      page.on("dialog", (d) => d.accept());
      await page.getByRole("button", { name: "Delete" }).click();
      await expect(page).toHaveURL(/\/admin\/lists$/);
    }
  });
});
