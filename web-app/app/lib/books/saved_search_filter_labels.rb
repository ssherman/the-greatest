# frozen_string_literal: true

module Books
  # A saved search's criteria as display-ready groups for the show page's
  # active-filters card.
  #
  # This exists because Books::SavedSearch#summary deliberately cannot do it:
  # summary renders once per row on the index page, so naming categories,
  # languages and countries there would be an N+1. Here there is exactly one
  # search on the page, so three queries -- one per taxonomy, include and
  # exclude ids unioned -- is the right trade.
  #
  # An id with no matching record renders as "Unknown (#id)" rather than
  # disappearing. BookAdvanced matches nothing on it, and a card that silently
  # omitted it would leave a zero-result page looking unexplained.
  class SavedSearchFilterLabels
    Group = Struct.new(:label, :values, :note, keyword_init: true)

    ANY_NOTE = "Books must have at least one of these genres"
    ALL_NOTE = "Books must have all of these genres"
    UNREADABLE_NOTE = "This search matches no books until it is edited"

    def self.call(criteria)
      new(criteria).call
    end

    def initialize(criteria)
      @criteria = criteria
    end

    def call
      [
        book_type_group,
        book_length_group,
        ranked_group,
        max_position_group,
        year_group,
        category_group("Including genres", criteria.included_category_ids, genre_note),
        category_group("Excluding genres", criteria.excluded_category_ids, nil),
        language_group("Including languages", criteria.included_language_ids),
        language_group("Excluding languages", criteria.excluded_language_ids),
        country_group("Including origins", criteria.included_country_ids),
        country_group("Excluding origins", criteria.excluded_country_ids),
        hide_read_group,
        unreadable_group
      ].compact
    end

    private

    attr_reader :criteria

    def book_type_group
      label = ::Books::BookType.label(criteria.book_type)
      return nil if label.nil?

      Group.new(label: "Book type", values: [label])
    end

    def book_length_group
      lengths = criteria.book_length
      return nil if lengths.empty?

      Group.new(
        label: "Book length",
        values: lengths.map { |value| ::Books::Book.book_lengths.key(value).to_s.titleize }
      )
    end

    def ranked_group
      value =
        case criteria.ranked
        when :ranked then "Only ranked books"
        when :unranked then "Only unranked books"
        end
      return nil if value.nil?

      Group.new(label: "Ranking status", values: [value])
    end

    def max_position_group
      position = criteria.max_ranked_position
      return nil if position.nil?

      Group.new(label: "Ranking limit", values: ["Top #{position}"])
    end

    def year_group
      gt = criteria.first_year_published_gt
      lt = criteria.first_year_published_lt
      return nil if gt.nil? && lt.nil?

      value =
        if gt && lt then "Between #{gt} and #{lt}"
        elsif gt then "After #{gt}"
        else "Before #{lt}"
        end

      Group.new(label: "Published", values: [value])
    end

    def hide_read_group
      return nil unless criteria.hide_read

      # "the owner", not "you": hide_read filters against the search's owner
      # even when a stranger is reading a public search (spec §6).
      Group.new(label: "Read books", values: ["Hiding books the owner has read"])
    end

    def unreadable_group
      keys = ::Books::SavedSearchCriteria::UNPARSEABLE_KEYS
        .select { |key| criteria.unparseable?(key) }
      return nil if keys.empty?

      Group.new(
        label: "Unreadable filter",
        values: keys.map { |key| key.humanize },
        note: UNREADABLE_NOTE
      )
    end

    def genre_note
      (criteria.genre_match_mode == :all) ? ALL_NOTE : ANY_NOTE
    end

    def category_group(label, ids, note)
      build_group(label, ids, category_names, note)
    end

    def language_group(label, ids)
      build_group(label, ids, language_names, nil)
    end

    def country_group(label, ids)
      build_group(label, ids, country_names, nil)
    end

    def build_group(label, ids, names, note)
      return nil if ids.empty?

      Group.new(label: label, values: ids.map { |id| names[id] || "Unknown (##{id})" }, note: note)
    end

    # One query per taxonomy, unioning the include and exclude ids -- memoized
    # so the include group and the exclude group share it. `|| {}` guards the
    # memo against a legitimately empty result re-querying.
    def category_names
      @category_names ||= name_map(
        ::Category, criteria.included_category_ids | criteria.excluded_category_ids
      )
    end

    def language_names
      @language_names ||= name_map(
        ::Language, criteria.included_language_ids | criteria.excluded_language_ids
      )
    end

    def country_names
      @country_names ||= name_map(
        ::Books::Country, criteria.included_country_ids | criteria.excluded_country_ids
      )
    end

    def name_map(klass, ids)
      return {} if ids.empty?

      klass.where(id: ids).pluck(:id, :name).to_h
    end
  end
end
