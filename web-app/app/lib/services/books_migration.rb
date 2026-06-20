# frozen_string_literal: true

module Services
  # Reserves the low primary-key ID range on `users` and `user_lists` for the
  # future Greatest Books migration. Books rows are imported preserving their
  # original auto-increment IDs in `[1, ID_CEILING)`; every new-app row lives at
  # `>= ID_CEILING`. See docs/specs/completed/books-migration-01-id-range-reservation.md.
  module BooksMigration
    # Reserved ceiling: ~3,700x the current book max (~265k) — ample headroom
    # before migration, and trivial for a bigint PK (range ~9.2e18).
    ID_CEILING = 1_000_000_000

    # Reserved table => the FK columns that must be remapped when one of its rows
    # is relocated out of the reserved range. Verified against db/schema.rb
    # (version 2026_04_22_040533). Any FK added before this migration ships must
    # be added here.
    #
    #   "users"      <- ai_chats.user_id, domain_roles.user_id,
    #                   external_links.submitted_by_id, lists.submitted_by_id,
    #                   penalties.user_id, ranking_configurations.user_id,
    #                   user_lists.user_id
    #   "user_lists" <- user_list_items.user_list_id
    FOREIGN_KEYS = {
      "users" => [
        ["ai_chats", "user_id"],
        ["domain_roles", "user_id"],
        ["external_links", "submitted_by_id"],
        ["lists", "submitted_by_id"],
        ["penalties", "user_id"],
        ["ranking_configurations", "user_id"],
        ["user_lists", "user_id"]
      ],
      "user_lists" => [
        ["user_list_items", "user_list_id"]
      ]
    }.freeze
  end
end
