# User Lists — Part 2 (Index / Split)

## Status
- **Status**: Split into sub-specs — see below
- **Created**: 2026-04-20
- **Updated**: 2026-05-05

## Why this is now an index

The original Part 2 placeholder bundled the entire user-facing surface into one spec — widget on cached pages, `/my/lists` dashboard, public list show pages, drag-and-drop, view modes, `completed_on` editing, consumed badges, public discovery — and it was too big to land safely. The work has been broken into smaller, independently shippable specs.

## Sub-specs

| Spec | Status | Scope |
|---|---|---|
| [`user-lists-02a-add-to-list-widget.md`](./user-lists-02a-add-to-list-widget.md) | Not Started | The "Add to List" widget that appears on any page with an item context (cached index pages, item show pages). Modal with existing-list checkboxes + inline new-list create. Per-list-type icon strip on each card. Anonymous → login modal. JSON state endpoint + mutation endpoints. |
| `user-lists-02c-my-lists-and-list-show.md` (placeholder) | Not Started | `/my/lists` dashboard, per-list show page with view modes (default/table/grid), pagination for 1000+ item lists, drag-and-drop reorder (SortableJS), custom-list edit/delete, `completed_on` inline editing. |
| `user-lists-02d-discovery-and-badges.md` (placeholder) | Not Started | Public-list discovery / index, optional CDN caching for public lists, "consumed" badge upgrades beyond the per-list-type icon strip. May fold into 02c. |

## Pre-agreed decisions that apply to all sub-specs

These were settled during 02a's discovery phase and apply to the whole Part 2 work:

1. **Cache safety**: cached pages render an identical anonymous shell. Per-user state is loaded client-side via JSON + `localStorage`.
2. **Routes**: mutation + state endpoints are global (non-domain-constrained) like `auth/sign_in`. The state endpoint scopes its response to `Current.domain`.
3. **Versioning**: `UserListItem` and `UserList` add `after_commit :touch_user` so `user.updated_at.to_i` becomes a monotonic version per user.
4. **Visual indicator**: per-default-list-type icons declared via `self.list_type_icons` on each STI subclass. Custom lists collapse into a "+N" pill.
5. **Anonymous interaction**: any "Add to list" affordance click while signed out triggers `<dialog id="login_modal">`.
6. **Books**: still excluded everywhere (no `Books::Book` model). When books lands, `Books::UserList` plus its `list_type_icons` plug into all three sub-specs without further changes.
7. **Movies**: data + dashboard work proceed normally. Cached-page integration (widget on movie cards) is moot until movie pages exist.

## Related Documentation

- `docs/specs/completed/user-lists-01-data-model.md` — Part 1 (data model)
- `docs/features/user-lists.md` — feature doc, kept current with each sub-spec
- `docs/old_site/user-lists-feature.md` — old-site reference (different stack, same UX intent)
