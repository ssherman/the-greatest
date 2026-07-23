# Admin shared-mutation write-gating — Design

**Status:** design approved 2026-07-23, pending plan.
**Why now:** Codex flagged this as P1 on both PR #174 (6a) and PR #175 (6b), and the owner deliberately
deferred it to its own PR (books-admin-ui design decision 6b-4). This is that PR.

## Problem

Four shared, cross-domain admin controllers gate on domain **access** only — not write — and their show
pages render Add/clear/destroy affordances unconditionally. So a domain **viewer** can mutate data they
should only be able to read:

| Controller | Auth today | Mutating actions |
|---|---|---|
| `Admin::RankedListsController` | `include DomainScopedAuth`; `domain_for_auth` → RC's domain (`domain_with_ranking_configuration_admin_for`) | `create`, `destroy` |
| `Admin::PenaltyApplicationsController` | same (RC-based `DomainScopedAuth`) | `create`, `update`, `destroy` |
| `Admin::ListItemsController` | hand-rolled `authenticate_admin!` → `list.type.split("::")` string-split, `can_access_domain?` | `create`, `update`, `destroy`, `destroy_all`, `clear_positions` |
| `Admin::ListPenaltiesController` | identical hand-rolled string-split | `create`, `destroy` |

`can_access_domain?` is true for any domain role including `viewer` (`user.rb:99`), and none of these
controllers has a Pundit layer or a write check. This is **pre-existing for music/games**; the books admin
(6a/6b) newly exposed it for books. `Admin::RankedItemsController` is index-only (read) — no gating needed.

## Scope

**In:** gate every mutating action on the four controllers on domain **write** (global admin/editor
bypass; else `can_write_in_domain?(parent_domain)`), across **all domains**; and guard the corresponding
Add/clear/destroy/edit buttons in the views on `current_user_can_write?`. Also removes the last two
copies of the duplicated hand-rolled list auth (a real de-dup).

**Out:** no change to read/index access (behavior-preserving); no new Pundit policies; no schema change;
`ranked_items` (read-only) untouched. Not touching `Admin::ImagesController` / `Admin::CategoryItemsController`
(already write-gated in 6a).

## Decisions

| # | Decision | Rationale |
|---|---|---|
| WG-1 | Gate all mutations on **write**, not delete. | Managing a list's items/penalties or an RC's ranked-lists/penalties is association-editing (like the 6a category/image decision, the inline-assoc pattern, and `ApplicationPolicy#update?`) — so editors keep add *and* remove; only viewers are blocked. Includes `destroy_all`/`clear_positions` (bulk writes). |
| WG-2 | **Unify all four controllers on `DomainScopedAuth#require_domain_write!`** rather than adding a second local check beside the hand-rolled auth. | The RC controllers already use `DomainScopedAuth`; migrating the two list controllers' identical hand-rolled auth into it adds the write gate *and* deletes the duplication in one move. |
| WG-3 | The list controllers keep their **string-split** domain resolution (moved into `domain_for_auth`), not the `DomainRouting` registry. | Behavior-preserving for the access check; avoids depending on the `LISTS` registry covering every list type (the inc-1/6a caveat). |
| WG-4 | Guard the view buttons on `current_user_can_write?` (the existing `current_domain`-based helper). | Matches how entity show pages already guard their buttons; these views render on the domain host, so `current_domain` equals the record's domain. Defense-in-depth + don't show a viewer buttons they can't use. |

## Design

### Controllers

**`RankedListsController`, `PenaltyApplicationsController`** (already `DomainScopedAuth`, `domain_for_auth`
overridden): add one `before_action`:
```ruby
before_action :require_domain_write!, only: [:create, :destroy]           # ranked_lists
before_action :require_domain_write!, only: [:create, :update, :destroy]  # penalty_applications
```
`require_domain_write!` (added to the concern in 6a) calls `domain_for_auth`, which already resolves the
RC's domain — so this reuses the exact resolution the access check uses, now gating on
`can_write_in_domain?`.

**`ListItemsController`, `ListPenaltiesController`** (hand-rolled string-split): migrate onto the concern.
- `include Admin::DomainScopedAuth`.
- Define `domain_for_auth` reproducing the existing list resolution + string-split:
  ```ruby
  def domain_for_auth
    list = if params[:list_id].present?
      List.find_by(id: params[:list_id])
    elsif params[:id].present?
      ListItem.find_by(id: params[:id])&.list      # ListPenalty in ListPenaltiesController
    end
    list&.type&.split("::")&.first&.downcase
  end
  ```
- **Remove** the hand-rolled `authenticate_admin!` — `DomainScopedAuth`'s version (`can_access_domain?
  (domain_for_auth)`, global admin/editor bypass, redirect to `domain_root_path`) is behaviorally
  identical to the current access check.
- Add the write gate:
  ```ruby
  before_action :require_domain_write!, only: [:create, :update, :destroy, :destroy_all, :clear_positions]  # list_items
  before_action :require_domain_write!, only: [:create, :destroy]                                            # list_penalties
  ```

Net: all four controllers gate reads on `can_access_domain?` (unchanged) and writes on
`can_write_in_domain?` (new), via one shared concern.

### Views

Guard each mutation affordance on `helpers.current_user_can_write?` (component) / `current_user_can_write?`
(ERB), rendering nothing for a viewer:
- **`Admin::Lists::ShowComponent`** (`show_component.html.erb`): "+ Add" item, "Clear positions",
  "Destroy all", "Attach penalty" buttons.
- **List-items frame** (`admin/list_items/index` and the per-row edit/remove) and the **`EditListItemModalComponent`** trigger.
- **`Admin::AddItemToListModalComponent`**, **`Admin::AddListToConfigurationModalComponent`**, and the
  list-penalty attach/detach affordances (render the modal + trigger only for writers).
- **RC show page** (`admin/ranking_configurations/show.html.erb`): add-list-to-config, remove ranked_list,
  add/edit/remove penalty-application buttons.

(The plan enumerates each exact file:line. The controller gate is the security boundary; the view guards
are UX + defense-in-depth.)

## Testing

- **Controller tests** for all four: a domain **viewer** is **denied** each mutation (redirect to
  `domain_root_path`, no record delta); a domain **editor** is **allowed**; a global admin allowed. Prove
  the list-based path (`list_items`/`list_penalties`) and the RC-based path (`ranked_lists`/
  `penalty_applications`) independently, in ≥2 domains.
- **Behavior-preserving read check:** a domain viewer can still `index`/read on the list controllers (the
  migration off the hand-rolled auth must not change access).
- No existing test should need editing except where one currently asserts a viewer *can* mutate (there
  should be none — the prior denial tests were read GETs).

## Risks

| Risk | Mitigation |
|---|---|
| Migrating the list controllers off hand-rolled auth changes the *access* check | The concern's `authenticate_admin!` + the string-split `domain_for_auth` reproduce the current logic exactly; a read-access regression test pins it. |
| `require_domain_write!` resolves the wrong domain for a shallow member action | It reuses `domain_for_auth`, which each controller already uses for the (working) access check — same resolution, same params handling. |
| A missed view button lets a viewer see (but not use) an affordance | The controller gate is the real boundary (returns 302, no mutation). View guards are defense-in-depth; a missed one is cosmetic, not a security hole. |
