import { test, expect } from "@playwright/test";

// Read-only: copies prompts and looks at pages. It never starts, finishes or
// releases an audit, and never edits a list.
test.describe("Books admin — list audits", () => {
  test("the queue page Copy prompt puts the queue prompt on the clipboard", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await page.goto("/admin/list_audits");

    await page.getByTestId("copy-agent-prompt").click();
    await expect(page.getByTestId("copy-agent-prompt")).toHaveText("Copied!");

    const text = await page.evaluate(() => navigator.clipboard.readText());
    expect(text).toContain("/api/mcp/admin");
    expect(text).toContain("start_list_audit");
  });

  test("a list's admin page copies a prompt naming that list", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await page.goto("/admin/lists");
    const link = page.locator("tbody tr td:nth-child(3) a").first();
    const name = (await link.innerText()).trim();
    await link.click();

    await page.getByTestId("copy-list-audit-prompt").click();
    await expect(page.getByTestId("copy-list-audit-prompt")).toHaveText("Copied!");

    const text = await page.evaluate(() => navigator.clipboard.readText());
    expect(text).toContain("start_list_audit");
    expect(text).toContain(name);
  });
});
