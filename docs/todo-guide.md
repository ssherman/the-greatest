# The Greatest — Task & Spec Guide (Agent-Ready)

> This guide defines how we write tasks/specs so AI agents (and humans) can build fast and correctly. It favors **contracts and tests** over long implementation code.

---

## Core Principles

1. **Contracts > Code**
   - Put JSON schemas, endpoint tables, pre/postconditions, invariants, and acceptance tests in the spec.
   - Keep long implementation code in the repo and **link to it** (file paths), not pasted.

2. **Single Source of Truth**
   - Specs name files/classes and constraints; the **authoritative code lives in the repo**.
   - Any snippet in a spec is **reference-only** and must be ≤40 lines.

3. **Determinism**
   - Specify inputs/outputs, edge cases, failure modes, auth/roles, and perf budgets.
   - Use “golden examples” (1–2 canonical cases) to pin behavior.

4. **Small, Linked, Testable**
   - Prefer endpoint tables, JSON schemas, and Gherkin or checklist acceptance criteria.
   - Every nontrivial reference has a **path** (e.g., `app/lib/music/song/merger.rb`).

---

## Repository Structure

**Main list**
```
todo.md           # Priority-sorted links to task files
```

**Tasks**
```
docs/todos/
  075-custom-admin-phase-4-songs.md
  completed/
    000-project-setup.md
  templates/
    task-template.md
```

**References**
```
docs/
  sub-agents.md
  AGENTS.md
  dev-core-values.md
  documentation.md
  testing.md
```

---

## `todo.md` Format

Keep it short and link to tasks.

```markdown
# The Greatest — Todo

## High
1. [Custom Admin Interface – Phase 4: Songs](docs/todos/075-custom-admin-phase-4-songs.md)

## Medium
2. [OpenSearch Integration](docs/todos/005-opensearch-integration.md)

## Low
3. [Recommendation Engine MVP](docs/todos/004-recommendation-engine.md)

## Completed
- ✅ [2025-11-10] [Phase 4: Songs](docs/todos/completed/075-custom-admin-phase-4-songs.md)
```

---

## Task Lifecycle

**Create → Implement → Record → Close**

1. Add to `todo.md` (priority section + link).
2. Create task file from the template (see `docs/todos/templates/task-template.md`).
3. While building, update **Implementation Notes** and **Deviations** in the task file.
4. On completion:
   - Fill **Acceptance Results**.
   - Update status to “Completed” with date.
   - Move link to “Completed” in `todo.md`.
   - Optionally move task file into `docs/todos/completed/`.

---

## What Goes Into a Task Spec

### Include (in the spec)
- **Interfaces & Contracts**
  - Endpoint table (verb, path, purpose, params/body, auth).
  - JSON schemas for requests/responses.
  - Event/Stimulus contracts, search contracts (fields/boosts).
- **Behavioral rules**
  - Preconditions & postconditions, invariants, edge cases.
- **Non-functionals**
  - Performance budgets, N+1 guardrails, auth/roles, responsiveness.
- **Acceptance criteria**
  - Checklists, pseudo-tests, or Gherkin.
- **Golden examples**
  - 1–2 canonical examples per feature (good/boundary).

### Link (do *not* paste)
- Full controllers, services, views.
- Large routing blocks and migrations.
- Anything >40 lines (unless truly unavoidable; mark as “reference, non-authoritative”).

---

## Agent Hand-Off Block (include in every task)

```markdown
## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines per snippet).
- Do not duplicate authoritative code; **link to files by path**.

### Required Outputs
- Updated files (paths must be listed in “Key Files Touched”).
- Passing tests for the Acceptance Criteria.
- Updated sections: “Implementation Notes”, “Deviations”, “Documentation Updated”.

### Sub-Agent Plan
1) codebase-pattern-finder → collect comparable patterns
2) codebase-analyzer → verify data flow & integration points
3) web-search-researcher → external docs if needed (official first)
4) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- Provide minimal fixtures (names & paths) if needed; keep small and focused.
```

---

## Sub-Agents (quick reference)

See `docs/sub-agents.md` for full details.

**When to use**
- **codebase-locator**: find *where* code lives.
- **codebase-analyzer**: understand *how* code works.
- **codebase-pattern-finder**: find patterns to model new work after.
- **web-search-researcher**: current info from the web; cite official docs.
- **technical-writer**: update docs, cross-refs, and task files.

**Conventions**
- Descriptive, not prescriptive; file:line references when quoting.
- Structured outputs for AI consumption.
- No critique unless requested.

---

## Definition of Done (DoD)

- [ ] All Acceptance Criteria demonstrably pass (tests/screenshots).
- [ ] No N+1 on listed pages; sort whitelist enforced where applicable.
- [ ] Docs updated (task file, `todo.md`, touched class docs).
- [ ] Links to authoritative code present; no large code dumps in the spec.
- [ ] Security/auth reviewed for new/changed paths and actions.
- [ ] Performance constraints noted or measured.

---

## Useful Blocks (copy as needed)

**Endpoint table**
```markdown
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| POST | /admin/songs/:id/execute_action | single-record action | action_name, fields | admin |
```

**Gherkin acceptance (optional)**
```gherkin
Scenario: Autocomplete returns top matches quickly
  Given 10k songs indexed
  When I GET /admin/songs/search?q=teen
  Then I receive ≤ 10 items in ≤ 300ms p95
  And the top result matches exact title prefixes first
```

**Error contract (example)**
```json
{
  "error": {
    "code": "invalid_sort",
    "message": "Sort parameter not allowed",
    "allowed": ["title","release_year","duration_secs","created_at"]
  }
}
```

**Reference helper (non-authoritative, ≤40 lines)**
```ruby
# reference only
def format_duration(seconds)
  return "—" if seconds.nil? || seconds.zero?
  h, r = seconds.divmod(3600)
  m, s = r.divmod(60)
  h.positive? ? "%d:%02d:%02d" % [h, m, s] : "%d:%02d" % [m, s]
end
```

---

## FAQ

**Can I paste a full controller into a spec?**  
No. Summarize responsibilities & contracts and link to the file path.

**When is a code snippet OK?**  
If it’s a small, tricky helper that encodes an invariant and won’t drift (≤40 lines), clearly labeled “reference only”.

**How do I keep agents fast/cheap?**  
Keep specs concise, front-load contracts and acceptance tests, link to code, and avoid large pasted blocks.
