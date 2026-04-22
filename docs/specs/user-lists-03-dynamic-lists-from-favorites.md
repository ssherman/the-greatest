# User Lists — Part 3: Dynamic Community Lists From User Favorites

## Status
- **Status**: Placeholder — to be rewritten when Parts 1 & 2 are complete
- **Priority**: Medium
- **Created**: 2026-04-20
- **Started**:
- **Completed**:
- **Developer**:

> **This is a placeholder spec.** It captures intent and pre-agreed decisions so whoever fills it out later has full context. It is **not** ready for agent hand-off — rewrite against the finished Parts 1 & 2 before implementation.

## Overview

Aggregate every user's `favorites` `UserList` across each item type into a single "dynamic community list" per item type (e.g. *"The Greatest Music Albums — Users' Favorites"*). These dynamic lists feed into the existing ranking system as weighted sources, so user-voted picks influence the site-wide rankings alongside editorial lists.

**Depends on:**
- `user-lists-01-data-model.md` (`UserList`, `UserListItem`, the `favorites` `list_type` per subclass).
- `user-lists-02-ui-and-cached-page-integration.md` (optional — the UI may surface "Appears on community favorites list" badges on item show pages).

## Pre-agreed Decisions (from discovery phase)

1. **Integration point:** the existing `List` / `RankingConfiguration` / `WeightedListRank` ranking system — do **not** invent a parallel scoring pipeline.
2. **One community list per item type**, per the existing STI pattern:
   - `Music::Albums::List` record: "Music Albums — Users' Favorites"
   - `Music::Songs::List` record: "Music Songs — Users' Favorites"
   - `Games::List` record: "Games — Users' Favorites"
   - `Movies::List` record: "Movies — Users' Favorites"
   - `Books::List` record: "Books — Users' Favorites"
3. **Aggregation algorithm** (from old site `app/lib/generate_ranked_users_list.rb`):
   - For each user's `favorites` `UserList` of size N: each item at position P contributes `score = N - P + 1` (item at position 1 gets the highest score).
   - Sum scores across all users' favorites lists for the same item.
   - Sort by total score descending.
   - Populate the community `List`'s `list_items` in rank order (position 1 = highest-scored item).
4. **Triggering:** on-write is the old-site pattern (Sidekiq job fires whenever a `UserListItem` is added/removed/repositioned in a favorites list). This is cheap at small scale but can get noisy. Likely better for the new site: **debounced / scheduled** (e.g., Sidekiq-Cron every N minutes, or a debounce lock keyed on the community list).
5. **Ranking integration:** the community list is added to the relevant `RankingConfiguration` as a `RankedList` with a tunable weight, exactly like any editorial list. Admins can tune the weight without code changes.

## Architectural Notes

### Reference implementation from old site
- `../the-greatest-books/admin/app/lib/generate_ranked_users_list.rb` — the algorithm
- `../the-greatest-books/admin/app/sidekiq/generate_ranked_users_list_job.rb` — the job trigger
- Old site re-ran the job on every `UserListBook` create/destroy/position-change in a favorite list. No Redis deduplication lock — concurrent runs were possible.

### Key questions for the rewrite

1. **Trigger cadence** — on-write vs. scheduled vs. debounced?
   - On-write: simplest, most responsive, but fires many jobs for active users.
   - Scheduled (e.g. every 15 min via Sidekiq-Cron): predictable load, worst-case lag is the interval.
   - Debounced: `perform_in(5.minutes, …)` with a Redis lock per community list so rapid writes collapse into one recompute. Best of both but more code.
   - Likely start with **scheduled every 15 min** for simplicity, upgrade later if needed.

2. **Deduplication** — a lock around the job body so concurrent runs can't corrupt positions. At minimum, wrap the DB updates in a transaction and use `SELECT ... FOR UPDATE` or a lightweight Redis mutex keyed on the community list id.

3. **How many items should the community list contain?**
   Old site had both a "Top 100" and an "Honorable Mention" (101+) list. Do we want:
   - a single list of the top N (100? 500?),
   - a hard cap (drop anything below some score threshold),
   - or keep all items with non-zero scores?
   Cap to avoid unbounded growth.

4. **Minimum vote threshold** — exclude items favorited by < X users to prevent one person's quirky favorite from appearing high in the community list? Old site had no such filter. Worth adding.

5. **RankingConfiguration wiring** — each domain's default `RankingConfiguration` needs to be updated to include the new community list with a chosen weight. Who decides the initial weight? (Almost certainly: low weight at first, tune based on results.)

6. **Do we regenerate rank when a user toggles public/private?** Favorites lists are personal regardless of the `public` flag — the aggregation should include all users' favorites whether or not the list itself is public. Confirm.

7. **Idempotency** — if the job is killed mid-run, can it safely resume? Prefer `upsert_all` / full replacement inside a transaction over per-row updates.

8. **How to surface this on the site?**
   - The community list shows up naturally on each domain's `/lists` index page (it's just another `List`).
   - Item show pages already render an "Appears On These Lists" card — the community list would appear there.
   - Maybe surface "Top 100 Users' Favorites" explicitly in homepage / rankings navigation.
   Deferred to UI work in Part 2 or a follow-up.

### Rough job skeleton (non-authoritative, reference only — ≤40 lines)

```ruby
# reference only — do not implement from this
class GenerateCommunityFavoritesJob
  include Sidekiq::Job

  # Runs per-domain-per-item-type
  def perform(user_list_subclass_name)
    subclass = user_list_subclass_name.constantize
    listable_class = subclass.listable_class

    scores = Hash.new(0)
    subclass.where(list_type: :favorites).includes(:user_list_items).find_each do |ul|
      items = ul.user_list_items.order(:position).to_a
      n = items.size
      next if n.zero?
      items.each do |item|
        scores[item.listable_id] += (n - item.position + 1)
      end
    end

    community_list = find_or_create_community_list_for(subclass)
    ranked = scores.sort_by { |_, score| -score }.first(500) # cap

    ActiveRecord::Base.transaction do
      community_list.list_items.delete_all
      ranked.each_with_index do |(listable_id, _score), idx|
        community_list.list_items.create!(
          listable_type: listable_class.name,
          listable_id: listable_id,
          position: idx + 1,
          verified: true
        )
      end
    end

    # Trigger re-rank of whatever RankingConfiguration(s) include this list
  end
end
```

## Interfaces & Contracts — to be finalized

- Job class: `GenerateCommunityFavoritesJob` (or better-named) — takes a `user_list_subclass_name` or runs for all subclasses.
- Scheduled via Sidekiq-Cron in `config/sidekiq.yml` or equivalent.
- New community `List` record per domain/item type, created once (probably via a seed/data migration).
- Admin ability to tune the weight via the existing `RankingConfiguration` → `RankedList` edit UI — likely no new UI needed.

## Agent Hand-Off

**Not ready for hand-off.** Before giving this to an agent:
1. Complete Parts 1 and 2 so the data model exists and can be queried.
2. Decide on trigger cadence, vote threshold, and list size cap.
3. Seed the community `List` records and wire them into the default `RankingConfiguration`s.
4. Rewrite this spec with concrete acceptance criteria, golden examples, and endpoint table (if admin-facing).

## Related Research

- Old-site implementation: `../the-greatest-books/admin/app/lib/generate_ranked_users_list.rb`
- Old-site doc: `docs/old_site/user-lists-feature.md` §"Community Ranked List Algorithm"
- New-site ranking system: `web-app/app/models/ranking_configuration.rb`, `web-app/app/lib/item_rankings/calculator.rb`, `web-app/app/lib/rankings/weight_calculator.rb`
- New-site `RankedList` join: weight lives on this join, not on the `List` itself.

## Documentation Updated
- [ ] Filled out properly before implementation
