# frozen_string_literal: true

module Api
  # What the member's-own-lists endpoints share: whose lists they are, how a
  # `{list}` path value resolves, and the per-page lookups.
  #
  # Every model reference is root-anchored (::Books::…, ::UserList…): inside
  # Api::V1 a bare Books:: resolves to Api::V1::Books:: and raises NameError.
  module Library
    extend ActiveSupport::Concern

    # `/my/lists` order: the four defaults by list_type, then custom lists by
    # name. id breaks ties so paging is stable.
    LISTS_ORDER = "(user_lists.list_type = 4), user_lists.list_type, LOWER(user_lists.name), user_lists.id"

    private

    def library_user = current_principal.user

    # The caller's own books list for a `{list}` value: a numeric id, or one of
    # the default list names (favorites, read, reading, want_to_read), which
    # exist for every member once EnsureDefaults has run. Anything else --
    # including an id that is another member's or another site's -- is the same
    # 404, so a list's existence is never confirmed to a non-owner.
    def find_my_list!(raw)
      raw = raw.to_s
      lists = library_user.user_lists.where(type: "Books::UserList")

      list = if /\A\d+\z/.match?(raw)
        lists.find_by(id: raw.to_i)
      elsif ::Books::UserList.default_list_types.map(&:to_s).include?(raw)
        ::Services::UserLists::EnsureDefaults
          .call(user: library_user, domain: :books, existing: lists.to_a)
          .find { |candidate| candidate.list_type == raw }
      end

      render_problem(::Api::Problem.new(:not_found, detail: "No list at that address")) if list.nil?
      list
    end

    # {list_id => Integer} of catalogue books on each list, one grouped query.
    # catalog_items, so the count matches the rows the list serves.
    def book_count_for(lists)
      ::Books::UserList.catalog_items(::UserListItem.where(user_list_id: lists.map(&:id)))
        .group(:user_list_id).count
    end

    # {book_id => rank} on the primary configuration in one query; {} when
    # there is no primary or the page is empty. The key is always passed to
    # BookResource (nil for an unranked book) so it never falls back to the
    # per-row primary_ranked_item lookup.
    def ranks_for(book_ids)
      primary = ::Books::RankingConfiguration.default_primary
      return {} if primary.nil? || book_ids.empty?

      ::RankedItem.where(ranking_configuration_id: primary.id, item_type: "Books::Book", item_id: book_ids)
        .pluck(:item_id, :rank).to_h
    end

    def iso_date(value) = value&.iso8601
  end
end
