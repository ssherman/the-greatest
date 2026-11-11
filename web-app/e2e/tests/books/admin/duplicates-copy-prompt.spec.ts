import { test, expect } from "@playwright/test";

test.describe("Books admin — duplicates Copy prompt", () => {
  test("the Copy prompt button puts the agent prompt on the clipboard", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await page.goto("/admin/duplicate_candidates");

    await page.getByTestId("copy-agent-prompt").click();
    await expect(page.getByTestId("copy-agent-prompt")).toHaveText("Copied!");

    const text = await page.evaluate(() => navigator.clipboard.readText());
    expect(text).toContain("/api/mcp/admin");
    expect(text).toContain("list_duplicate_candidates");
  });
});
