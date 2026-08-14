# daisyUI v5 Migration Notes

## Overview

The app runs daisyUI 5.7.x. daisyUI 5 renamed or removed a set of classes that existed in v4, and
because the app's styles are Tailwind-generated utility classes (no Rails asset pipeline, no
build-time error for an unknown class), referencing a removed class is a **silent** failure: the
class is simply absent from the compiled CSS. No build warning, no runtime error — the markup
renders, just without the effect the class used to have. `test/lint/daisyui_v4_classes_test.rb`
guards against *new* occurrences of ten such classes creeping back in.

A separate sweep (see git history around "Remove every daisyUI class that v5 deleted") deleted all
1,053 existing occurrences of those ten class names across 112 templates. That sweep changed no
rendering — the byte-identical stylesheet check (rebuild `books.css`, `games.css`, `music.css` and
diff against a pre-sweep baseline) confirmed the compiled CSS was unchanged, because none of the
removed names were live to begin with. That check is the proof; it is not repeated here.

**This document is about three of those ten classes that had visible, deliberately-styled
counterparts in daisyUI 4** — `table-hover`, `tabs-boxed`, and `input-disabled`. Removing the dead
class name doesn't change anything (the effect was already gone), but it does make the loss easy to
forget, because after the sweep there is no dead code left pointing at where the styling used to be.
This is that pointer. Restoring the intended look is deliberate follow-up work, **not** part of the
sweep itself.

## What was already silently lost, and its v5 replacement

Counts below were confirmed against the commit immediately before the sweep
(`git grep -l "<class>" <pre-sweep-sha> -- app/views app/components`).

### `table-hover` — 13 files

Admin data tables (games companies/games/platforms/series, music ai_chats/albums/artists/
artists-ranking-configurations/songs, penalties, ranking_configurations, users) carried
`table-hover` on the `<table>` element expecting a row-highlight-on-hover affordance. daisyUI 5 has
no `table-hover` modifier, so every one of these tables has rendered with no hover highlight for as
long as the app has run on daisyUI 5 — rows currently look identical whether the mouse is over them
or not.

**v5 replacement:** there is no daisyUI table modifier for this; it has to be a Tailwind utility on
the row, e.g. `hover:bg-base-200` (or `hover:bg-base-300` for more contrast) on each `<tr>`.

Affected files (pre-sweep):

- `app/components/admin/lists/table_component.html.erb`
- `app/views/admin/games/companies/_table.html.erb`
- `app/views/admin/games/games/_table.html.erb`
- `app/views/admin/games/platforms/_table.html.erb`
- `app/views/admin/games/series/_table.html.erb`
- `app/views/admin/music/ai_chats/_table.html.erb`
- `app/views/admin/music/albums/_table.html.erb`
- `app/views/admin/music/artists/_table.html.erb`
- `app/views/admin/music/artists/ranking_configurations/_table.html.erb`
- `app/views/admin/music/songs/_table.html.erb`
- `app/views/admin/penalties/_table.html.erb`
- `app/views/admin/ranking_configurations/_table.html.erb`
- `app/views/admin/users/_table.html.erb`

### `tabs-boxed` — 2 files

The music and games filter-tabs components used `tabs-boxed` to render the tab strip as a filled,
segmented control (a "boxed" background behind the tab group). Since that modifier doesn't exist in
v5, both components have been rendering as an unstyled row of tab links with no boxed background.

**v5 replacement:** `tabs-box` (daisyUI 5 renamed the modifier, it didn't just remove it).

Affected files (pre-sweep):

- `app/components/games/filter_tabs_component.html.erb`
- `app/components/music/filter_tabs_component.html.erb`

### `input-disabled` — 11 files

Various admin forms (games companies/games show, music albums/artists/songs show and their
associated-list partials, the songs form, and the shared `autocomplete_component`) added
`input-disabled` alongside the HTML `disabled` attribute, expecting a distinct greyed-out visual
treatment for disabled text inputs. daisyUI 5 dropped the modifier because it's redundant with
native `:disabled` styling — but since the sweep only removes the class name and never touches the
`disabled` attribute itself, these inputs were already relying on the browser's native disabled
appearance before the sweep, and continue to after it.

**v5 replacement:** none needed — native `input:disabled` styling (which daisyUI's base `input`
class already accounts for) covers this. No follow-up work is required for this one specifically;
it's listed here for completeness since it was one of the ten swept classes.

Affected files (pre-sweep):

- `app/components/autocomplete_component.html.erb`
- `app/views/admin/games/games/_companies_list.html.erb`
- `app/views/admin/games/games/show.html.erb`
- `app/views/admin/music/albums/_artists_list.html.erb`
- `app/views/admin/music/albums/show.html.erb`
- `app/views/admin/music/artists/_albums_list.html.erb`
- `app/views/admin/music/artists/_songs_list.html.erb`
- `app/views/admin/music/artists/show.html.erb`
- `app/views/admin/music/songs/_artists_list.html.erb`
- `app/views/admin/music/songs/_form.html.erb`
- `app/views/admin/music/songs/show.html.erb`

> Note: the originating spec for this sweep estimated 10 files for `input-disabled`. A direct
> `git grep` against the pre-sweep commit found 11 (the eleventh being
> `app/components/autocomplete_component.html.erb`, which applied the class conditionally via ERB
> interpolation rather than as a plain literal). The number above is the confirmed count.

## Follow-up work (not part of this change)

- Add a `hover:` background utility to the 13 admin table partials/components listed above.
- Swap `tabs-boxed` → `tabs-box` in the 2 filter-tabs components listed above.
- No action needed for `input-disabled` — native `:disabled` styling already applies.

None of this is bundled into the v4-class-name sweep. The sweep's only job was proving the class
names were dead and removing them without changing rendering; restoring the intended `table-hover`
and `tabs-boxed` looks is separate, visible, designer-reviewable UI work.
