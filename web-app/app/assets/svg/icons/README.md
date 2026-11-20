# Vendored Icons

Icons used by the `rails_icons` gem (`helpers.icon "name", library: "lucide"`).

## Curation policy

We **do not** ship the full Lucide library (~1,700 icons / ~1.7 MB). The gem's
default `rails generate rails_icons:sync --libraries=lucide` clones the entire
upstream repo into this directory. Lucide files are inlined as SVG at server
render time (they don't ship to the client), but the file count slows git
operations and bloats every PR diff that touches the icon plumbing.

Only icons actually referenced in the codebase live here. Currently:

| Icon | Used by |
|------|---------|
| `bookmark` | `UserList::list_type_icons` (want_to_listen / want_to_watch / want_to_play) |
| `book-open` | `Books::UserList.list_type_icons[:reading]` |
| `check` | `Games::UserList.list_type_icons[:played]` |
| `download` | `CsvExports::DownloadButtonComponent` button |
| `eye` | `Movies::UserList.list_type_icons[:watched]` |
| `arrow-down-to-line` | `UserLists::Edit::RowComponent` ⋯ menu |
| `arrow-up-to-line` | `UserLists::Edit::RowComponent` ⋯ menu |
| `calendar` | `UserLists::Edit::RowComponent` ⋯ menu |
| `gamepad-2` | `Games::UserList.list_type_icons[:currently_playing]` |
| `headphones` | `Music::Albums::UserList.list_type_icons[:listened]` |
| `hash` | `UserLists::Edit::RowComponent` ⋯ menu |
| `heart` | `*::UserList.list_type_icons[:favorites]` |
| `lock` | `my_lists/edit` Built-in badge |
| `plus` | `UserLists::CardWidgetComponent` button |
| `star` | `Reviews::StarsComponent` and `Reviews::HistogramComponent` |
| `trophy` | `Games::UserList.list_type_icons[:beaten]` |
| `user` | `Books::Profiles::HeaderComponent` avatar when the reader has no name |

## Adding a new icon

1. Pick a name from <https://lucide.dev/icons/>.
2. Either:
   - Run `bin/rails generate rails_icons:sync --libraries=lucide`, then `git add` only the file you want and `git restore .` the rest, **or**
   - Download the single SVG from the Lucide site and drop it in `lucide/outline/`.
3. If it's used client-side (cloned from the hidden `<template>` by the
   widget's Stimulus controller), add the name to
   `app/views/shared/_user_list_icon_template.html.erb`.
4. Update the table above so the next person knows what's referenced.
