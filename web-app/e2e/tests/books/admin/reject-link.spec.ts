import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Spec §12: seed a placeholder author holding one Wikidata link, reject the
// link from its decision page, and check what the reject removed. The author
// is a placeholder (exclude_from_rankings), so the Wikidata run the reject
// queues skips it without calling Wikidata, VIAF or a model. The rake tasks
// run from web-app, like import-finder-audit.spec.ts; the seed is idempotent.
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const rails = (task: string) => execSync(`bin/rails ${task}`, { cwd: WEB_APP, encoding: "utf8" });
const lastJson = (output: string) => {
  const lines = output.trim().split("\n");
  return JSON.parse(lines[lines.length - 1]);
};

let decisionId: number;

test.describe("Books admin — reject a Wikidata link", () => {
  test.describe.configure({ mode: "serial" });

  test.beforeAll(() => {
    decisionId = lastJson(rails("e2e:reject_link_seed")).decision_id;
  });

  test.afterAll(() => {
    rails("e2e:reject_link_cleanup");
  });

  test("rejecting the link removes what it wrote and marks the decision rejected", async ({ page }) => {
    expect(lastJson(rails("e2e:reject_link_state"))).toEqual({
      wikidata_qids: ["Q4115189"],
      birth_year: 1901,
      links: ["https://en.wikipedia.org/wiki/Wikipedia:Sandbox"],
    });

    await page.goto(`/admin/match_decisions/${decisionId}`);
    const reject = page.getByRole("button", { name: "Reject link" });
    await expect(reject).toBeVisible();

    page.once("dialog", (dialog) => dialog.accept());
    await reject.click();

    await expect(page.getByRole("alert")).toContainText("Link rejected.");
    await expect(page.getByTestId("decision-verdict")).toContainText("rejected");
    await expect(page.getByRole("button", { name: "Reject link" })).toHaveCount(0);

    expect(lastJson(rails("e2e:reject_link_state"))).toEqual({ wikidata_qids: [], birth_year: null, links: [] });
  });
});
