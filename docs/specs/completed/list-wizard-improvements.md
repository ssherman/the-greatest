# List Wizard & Ranking Configuration Improvements

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-02-24
- **Started**: 2026-02-24
- **Completed**: 2026-02-24
- **Developer**: Claude

## Overview

Four targeted improvements to the list wizard and ranking configuration system:

1. **Fix verify button greyed out** - The "Verify" menu item inside the dots-menu dropdown appears greyed out on the review step, even though it functions when clicked. Affects all domains (songs, albums, games).
2. **Add breadcrumbs to wizard** - Add breadcrumb navigation linking back to the list show page from within the wizard.
3. **Editor permissions for ranking operations** - Global editors should be able to add/remove ranked lists, recalculate weights, refresh rankings, and flush Cloudflare cache.
4. **Wizard restart deletes list_items** - Restarting the wizard should automatically delete all list_items with a confirmation dialog warning.

**Non-goals**: No changes to wizard step flow, no new wizard steps, no changes to editor access for creating/editing/deleting ranking configurations.

## Context & Links
- List Wizard infrastructure: `docs/features/list-wizard.md`
- Spec instructions: `docs/spec-instructions.md`

## Issue 1: Fix Verify Button Greyed Out in Review Step

### Root Cause Analysis

The verify menu item uses `button_to` (which renders `<form><button>`) inside a DaisyUI `.menu` `<ul>`. DaisyUI menus style `<a>` elements but not `<form>/<button>` elements, causing the verify button to appear unstyled/greyed out. Other menu items (Edit Metadata, Link, Search) use `link_to` which renders `<a>` tags and receive proper menu styling.

**File**: `app/components/admin/music/wizard/item_row_component.html.erb`, lines 49-54

The `:verify` case uses `button_to` with `class: "text-success"`, but DaisyUI `.menu li` styles override or don't apply to `<button>` elements inside forms.

Additionally, the verify option is hidden when `item.verified?` is true (line 50: `unless item.verified?`). Per the user's request, verify should **always** be visible and clickable, even for already-verified items (allowing re-verification or toggling).

### Behaviors

- **Precondition**: Item exists in the review step list.
- **Postcondition**: Verify menu item is always visible, properly styled (not greyed out), and clickable.
- **Edge case**: Clicking verify on an already-verified item should still succeed (idempotent update).

### Acceptance Criteria

- [ ] Verify menu item in dots-menu dropdown is never greyed out / unstyled
- [ ] Verify menu item is always visible regardless of `item.verified?` status
- [ ] Verify action remains functional and idempotent for all three domains (songs, albums, games)
- [ ] Verify menu item styling matches other menu items (proper DaisyUI menu styling)

### Key Files to Modify
- `app/components/admin/music/wizard/item_row_component.html.erb` - Remove `unless item.verified?` guard on `:verify` case; fix button styling to match DaisyUI menu conventions

---

## Issue 2: Add Breadcrumbs to Wizard

### Design

Add a breadcrumb trail above the wizard header in each domain's `show_step.html.erb` view. No existing breadcrumb pattern exists in the app, so we'll use DaisyUI's `breadcrumbs` component.

Breadcrumb trail: `Lists > {List Name} > Wizard`

Where:
- "Lists" links to the domain's lists index (`admin_{domain}_lists_path`)
- "{List Name}" links to the list show page (`admin_{domain}_list_path(@list)`)
- "Wizard" is the current page (no link)

### Behaviors

- **Precondition**: `@list` is loaded (guaranteed by `set_wizard_entity` before_action).
- **Postcondition**: Breadcrumb renders on every wizard step for all three domains.
- **Edge case**: Long list names should truncate gracefully via CSS.

### Acceptance Criteria

- [ ] Breadcrumb trail appears above wizard header on all wizard steps
- [ ] "Lists" link navigates to domain-specific lists index
- [ ] List name link navigates to the specific list's show page
- [ ] Breadcrumbs render correctly for games, songs, and albums wizards
- [ ] Uses DaisyUI `breadcrumbs` component styling

### Key Files to Modify
- `app/views/admin/games/list_wizard/show_step.html.erb`
- `app/views/admin/music/songs/list_wizard/show_step.html.erb`
- `app/views/admin/music/albums/list_wizard/show_step.html.erb`

### Optional Reference Snippet (<=40 lines, non-authoritative)
```erb
<!-- reference only - breadcrumb inside wizard.with_header -->
<div class="breadcrumbs text-sm mb-2">
  <ul>
    <li><%= link_to "Lists", admin_games_lists_path %></li>
    <li><%= link_to @list.name, admin_games_list_path(@list) %></li>
    <li>Wizard</li>
  </ul>
</div>
```

---

## Issue 3: Editor Permissions for Ranking Operations

### Current State

| Action | Global Editor | Source |
|---|---|---|
| View ranking config (show/index) | YES | `ApplicationPolicy#show?` → `global_role?` |
| Add/remove ranked lists | YES | `RankedListsController` → `RankingConfigurationDomainAuth` (no Pundit) |
| Execute actions (Recalculate/Refresh) | **NO** | `RankingConfigurationPolicy#execute_action?` → `manage?` (admin-only) |
| Edit ranking config | NO | `RankingConfigurationPolicy#update?` → `manage?` |
| Delete ranking config | NO | `RankingConfigurationPolicy#destroy?` → `manage?` |
| Flush Cloudflare cache | **NO** | `CloudflareController#require_admin_role!` (admin-only) |

### Target State

| Action | Global Editor | Change |
|---|---|---|
| View ranking config (show/index) | YES | No change |
| Add/remove ranked lists | YES | No change |
| Execute actions (Recalculate/Refresh) | **YES** | Change `execute_action?` policy |
| Edit ranking config | NO | No change |
| Delete ranking config | NO | No change |
| Flush Cloudflare cache | **YES** | Change `require_admin_role!` |

### Behaviors

- **Precondition**: User has global `editor` role (`User.role == :editor`).
- **Postcondition**: Editor can execute ranking actions and flush Cloudflare cache.
- **Edge case**: Domain-level editors (via `DomainRole`) should also be able to execute actions and flush cache for their domain.

### UI: Hide Unauthorized Buttons

The ranking configuration show page (`app/views/admin/ranking_configurations/show.html.erb`) currently shows all action buttons regardless of permission. Wrap unauthorized actions with Pundit `policy` checks:

- **Edit button** (line 29): Show only if `policy(@ranking_configuration).edit?`
- **Actions dropdown** (lines 36-58): Show only if `policy(@ranking_configuration).execute_action?`
- **Delete button** (lines 61-69): Show only if `policy(@ranking_configuration).destroy?`

### Acceptance Criteria

- [ ] Global editors can execute "Recalculate List Weights" action
- [ ] Global editors can execute "Refresh Rankings" action
- [ ] Global editors can flush Cloudflare cache
- [ ] Global editors cannot edit ranking configurations
- [ ] Global editors cannot delete ranking configurations
- [ ] Domain editors (DomainRole with editor permission_level) can execute ranking actions for their domain
- [ ] Edit button hidden from users without `update?` permission
- [ ] Actions dropdown hidden from users without `execute_action?` permission
- [ ] Delete button hidden from users without `destroy?` permission
- [ ] Admin users retain full access (no regression)

### Key Files to Modify
- `app/policies/games/ranking_configuration_policy.rb` - Change `execute_action?` to allow editors
- `app/policies/music/ranking_configuration_policy.rb` - Change `execute_action?` to allow editors
- `app/controllers/admin/cloudflare_controller.rb` - Change `require_admin_role!` to allow editors
- `app/views/admin/ranking_configurations/show.html.erb` - Conditionally hide buttons based on policy

### Optional Reference Snippet (<=40 lines, non-authoritative)
```ruby
# reference only - policy change for execute_action?
def execute_action?
  global_admin? || global_editor? || domain_role&.can_write?
end
```

```erb
<!-- reference only - conditional button visibility -->
<% if policy(@ranking_configuration).edit? %>
  <%= link_to edit_ranking_configuration_path(@ranking_configuration), class: "btn btn-primary" do %>
    <span>Edit</span>
  <% end %>
<% end %>
```

---

## Issue 4: Wizard Restart Deletes List Items

### Current Behavior

The restart action (`WizardController#restart`, line 137-140) calls `wizard_entity.wizard_manager.reset!` which clears wizard state JSON but **does not** delete list items. The existing confirmation message is: "Are you sure you want to restart the wizard? This will reset all progress."

### Target Behavior

On restart:
1. Show confirmation: **"Are you sure you want to restart the wizard? This will delete all list items and reset all progress."**
2. Delete all list items for the list (`@list.list_items.destroy_all`)
3. Reset wizard state (`wizard_manager.reset!`)

### Behaviors

- **Precondition**: Wizard is in progress with list items present.
- **Postcondition**: All list_items are destroyed, wizard_state is reset, user is redirected to step 1.
- **Edge case**: Restart with no list items should still succeed (no-op for deletion).
- **Edge case**: Restart should use `destroy_all` (not `delete_all`) to trigger any callbacks/dependent destroys.

### Acceptance Criteria

- [ ] Restart confirmation message warns about list item deletion
- [ ] All list items are deleted when wizard is restarted
- [ ] Wizard state is fully reset after restart
- [ ] Restart works correctly for all three domains (songs, albums, games)
- [ ] Restart with zero list items does not error
- [ ] User is redirected to step 1 after restart

### Key Files to Modify
- `app/controllers/concerns/wizard_controller.rb` - Add `wizard_entity.list_items.destroy_all` in `restart` action
- `app/components/wizard/navigation_component.html.erb` - Update `turbo_confirm` text

---

## Non-Functionals

- No N+1 queries introduced
- No new migrations required
- All changes backward compatible
- Performance: `list_items.destroy_all` may be slow for very large lists (1000+ items) - acceptable for admin wizard context

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests for the Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder -> collect comparable patterns (DaisyUI breadcrumbs, policy checks in views, button_to styling)
2) codebase-analyzer -> verify data flow & integration points (restart flow, policy enforcement)
3) technical-writer -> update docs and cross-refs

### Test Seed / Fixtures
- Existing user fixtures with admin/editor roles
- Existing list fixtures with list_items
- Existing ranking_configuration fixtures

---

## Implementation Notes (living)
- **Issue 1**: Changed `button_to` to `link_to` with `data: { turbo_method: :post }` for verify menu item. This renders an `<a>` tag instead of `<form><button>`, matching DaisyUI menu styling. Removed `unless item.verified?` guard.
- **Issue 2**: Added DaisyUI breadcrumbs component directly in each `show_step.html.erb` view inside the `wizard.with_header` slot.
- **Issue 3**: Used `ranking_configuration_policy` helper method (exposed via `helper_method`) instead of Pundit's `policy()` because STI models (e.g., `Music::Songs::RankingConfiguration`) don't auto-resolve to the parent policy (`Music::RankingConfigurationPolicy`).
- **Issue 4**: Added `wizard_entity.list_items.destroy_all` before `wizard_manager.reset!` in the restart action.

### Key Files Touched (paths only)
- `app/components/admin/music/wizard/item_row_component.html.erb`
- `app/views/admin/games/list_wizard/show_step.html.erb`
- `app/views/admin/music/songs/list_wizard/show_step.html.erb`
- `app/views/admin/music/albums/list_wizard/show_step.html.erb`
- `app/policies/games/ranking_configuration_policy.rb`
- `app/policies/music/ranking_configuration_policy.rb`
- `app/controllers/admin/cloudflare_controller.rb`
- `app/controllers/admin/ranking_configurations_controller.rb`
- `app/views/admin/ranking_configurations/show.html.erb`
- `app/controllers/concerns/wizard_controller.rb`
- `app/components/wizard/navigation_component.html.erb`
- `test/controllers/admin/games/list_wizard_controller_test.rb`
- `test/controllers/admin/music/songs/list_wizard_controller_test.rb`
- `test/controllers/admin/music/albums/list_wizard_controller_test.rb`
- `test/controllers/admin/games/ranking_configurations_controller_test.rb`
- `test/controllers/admin/music/songs/ranking_configurations_controller_test.rb`
- `test/controllers/admin/music/albums/ranking_configurations_controller_test.rb`
- `test/controllers/admin/cloudflare_controller_test.rb`

### Challenges & Resolutions
- Pundit `policy()` helper doesn't resolve STI models to parent policies. Fixed by creating a `ranking_configuration_policy` helper method that uses the controller's `policy_class` directly.

### Deviations From Plan
- Added `ranking_configuration_policy` helper method to `Admin::RankingConfigurationsController` instead of using Pundit's `policy()` view helper (Pundit can't resolve STI → parent policy for `Music::Songs::` and `Music::Albums::` models).

## Acceptance Results
- Date, verifier, artifacts (screenshots/links):

## Future Improvements
- Extract breadcrumbs into a shared ViewComponent if adopted in more admin pages
- Consider adding `delete_all` instead of `destroy_all` for large lists if performance becomes an issue

## Related PRs
-

## Documentation Updated
- [ ] `documentation.md`
- [ ] Class docs
