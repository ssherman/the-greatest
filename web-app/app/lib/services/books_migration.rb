# frozen_string_literal: true

module Services
  # Reserves the low primary-key ID range on `users`, `user_lists`, and `lists`
  # for the future Greatest Books migration. Books rows are imported preserving
  # their original auto-increment IDs in `[1, ceiling)`; every new-app row lives
  # at `>= ceiling`. See docs/specs/completed/books-migration-01-id-range-reservation.md.
  module BooksMigration
    # Per-table reserved ceilings: books rows keep their original IDs below the
    # ceiling; new-app rows are relocated to and minted at `>= ceiling`. Sized
    # with headroom over the legacy books site's current MAX(id) (user_lists
    # ~604k, users ~69k as of 2026-06). These are deliberately tight — re-confirm
    # the legacy MAX(id) is still well under each ceiling before the books import,
    # and raise a ceiling if needed (cost is zero on a bigint PK).
    RESERVED_CEILINGS = {
      "users" => 150_000,
      "user_lists" => 1_000_000,
      "lists" => 10_000
    }.freeze

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
    #   "lists"      <- list_items.list_id, list_penalties.list_id,
    #                   ranked_lists.list_id, ranking_configurations.primary_mapped_list_id,
    #                   ranking_configurations.secondary_mapped_list_id
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
      ],
      "lists" => [
        ["list_items", "list_id"],
        ["list_penalties", "list_id"],
        ["ranked_lists", "list_id"],
        ["ranking_configurations", "primary_mapped_list_id"],
        ["ranking_configurations", "secondary_mapped_list_id"]
      ]
    }.freeze

    # Polymorphic references have no DB FK. Rails stores the STI *base* class
    # name in the `_type` column, so every list's ai_chat is `parent_type = "List"`.
    # Format: [child_table, id_column, type_column, type_value].
    POLYMORPHIC_FOREIGN_KEYS = {
      "lists" => [
        ["ai_chats", "parent_id", "parent_type", "List"]
      ]
    }.freeze
  end
end
