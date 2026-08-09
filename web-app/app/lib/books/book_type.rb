# frozen_string_literal: true

module Books
  # The four legacy book_type values (fiction/nonfiction/religious/poetry).
  # book_type has no column of its own: the values are category data, so a
  # criterion resolves to a category at query time.
  #
  # Single source for all three things the app asks of a book_type -- its
  # display label, its LEGACY category id, and its category id in THIS
  # database. Before this class the first two lived in two unrelated constants
  # keyed on the same 0-3 integers, and the query layer was about to add a third.
  #
  # The current-database id is resolved through LegacyIdMap rather than
  # hardcoded: `categories` is shared across domains and its ids were NOT
  # preserved by the migration, so the new id is a per-database fact. (Measured
  # 2026-08-09: dev and production happen to agree, which is exactly what would
  # make a hardcoded id look correct and stay fragile.)
  class BookType
    LABELS = {
      0 => "Fiction",
      1 => "Nonfiction",
      2 => "Religion & Spirituality",
      3 => "Poetry"
    }.freeze

    # Legacy `categories` ids. religious (2) maps to the "Religion &
    # Spirituality" GENRE, not the near-empty "Religious" subject category,
    # which held 9 items against 1,899 typed books.
    LEGACY_CATEGORY_IDS = {
      0 => 40348,
      1 => 41013,
      2 => 47008,
      3 => 40876
    }.freeze

    # "Religion & Spirituality" is a deliberate copy change from legacy's
    # "Religious"; the underlying value (2) is unchanged.
    def self.label(value)
      LABELS[value]
    end

    def self.legacy_category_id(value)
      LEGACY_CATEGORY_IDS[value]
    end

    # This database's category id, or nil when the value is unknown or the
    # categories migration has not run here. Memoized per process because the
    # mapping is immutable once that migration has run; reset_category_ids!
    # exists for tests, which create mappings after boot.
    def self.category_id(value)
      legacy_id = LEGACY_CATEGORY_IDS[value]
      return nil if legacy_id.nil?

      category_ids[legacy_id]
    end

    def self.reset_category_ids!
      @category_ids = nil
    end

    def self.category_ids
      @category_ids ||= LegacyIdMap
        .where(model: "Books::Category", legacy_id: LEGACY_CATEGORY_IDS.values)
        .pluck(:legacy_id, :new_id)
        .to_h
    end
    private_class_method :category_ids
  end
end
