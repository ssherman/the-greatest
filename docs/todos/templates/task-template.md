# [NNN] - [Concise Task Title]

## Status
- **Status**: Not Started | In Progress | Completed
- **Priority**: High | Medium | Low
- **Created**: YYYY-MM-DD
- **Started**: YYYY-MM-DD
- **Completed**: YYYY-MM-DD
- **Developer**: [Name/Handle]

## Overview
1–3 sentences: goal, scope, non-goals.

## Context & Links
- Related tasks/phases: …
- Source files (authoritative): …
- External docs (official first): …

## Interfaces & Contracts

### Domain Model (diffs only)
- Fields/constraints/indexes to add
- Migration file name(s)/path(s) (no full code)

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
|  |  |  |  |  |
> Source of truth: `config/routes.rb` (do not paste large blocks).

### Schemas (JSON)
```json
{
  "type": "object",
  "required": [],
  "properties": {},
  "additionalProperties": false
}
```

### Behaviors (pre/postconditions)
- Preconditions: …
- Postconditions/effects: …
- Edge cases & failure modes: …

### Non-Functionals
- Performance budgets (e.g., p95 latency, query limits, no N+1)
- Security/roles (admin/editor/guest)
- Responsiveness/UX constraints

## Acceptance Criteria
- [ ] …
- [ ] …
- [ ] …

### Golden Examples
```text
Input: …
Output: …
```

### Optional Reference Snippet (≤40 lines, non-authoritative)
```ruby
# reference only
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in “Key Files Touched”).
- Passing tests demonstrating Acceptance Criteria.
- Updated: “Implementation Notes”, “Deviations”, “Documentation Updated”.

### Sub-Agent Plan
1) codebase-pattern-finder → collect comparable patterns  
2) codebase-analyzer → verify data flow & integration points  
3) web-search-researcher → external docs if needed (official first)  
4) technical-writer → update docs and cross-refs  

### Test Seed / Fixtures
- Minimal fixtures only; list names/paths here.

---

## Implementation Notes (living)
- Approach taken:
- Important decisions:

### Key Files Touched (paths only)
- `app/...`
- `config/...`
- `app/lib/...`

### Challenges & Resolutions
- …

### Deviations From Plan
- …

## Acceptance Results
- Date, verifier, artifacts (screenshots/links):

## Future Improvements
- …

## Related PRs
- #…

## Documentation Updated
- [ ] `documentation.md`
- [ ] Class docs
- [ ] `todo.md`
