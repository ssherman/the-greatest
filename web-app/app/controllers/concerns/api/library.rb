# frozen_string_literal: true

module Api
  # What the member's-own-lists endpoints share: whose lists they are, how a
  # `{list}` path value resolves, and the per-page lookups.
  #
  # Every model reference is root-anchored (::Books::…, ::UserList…): inside
  # Api::V1 a bare Books:: resolves to Api::V1::Books:: and raises NameError.
  module Library
    extend ActiveSupport::Concern
    include ::Api::JsonBody

    COMPLETED_ON_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/

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

    # The unique, stripped slugs of a write: an Array (JSON body) or a
    # comma-separated String (query). Renders the 400 and returns nil unless
    # there are 1..library_batch_max of them.
    def book_slugs!(raw)
      max = Rails.application.config.x.api.library_batch_max
      list = case raw
      when Array then raw
      when String then raw.split(",")
      end

      unless list&.all? { |slug| slug.is_a?(String) && !slug.include?("\u0000") }
        bad_body("books must hold book slug strings, as an array or a comma-separated string")
        return nil
      end

      slugs = list.map(&:strip).reject(&:empty?).uniq
      unless slugs.size.between?(1, max)
        bad_body("books must name between 1 and #{max} different books")
        return nil
      end

      slugs
    end

    # The catalogue books for `slugs`, in slug order. One 404 naming every
    # unknown slug (a provisional book is unknown), so a retry can fix them all.
    def catalog_books!(slugs)
      found = ::Books::Book.catalog.where(slug: slugs).index_by(&:slug)
      unknown = slugs - found.keys
      if unknown.any?
        render_problem(::Api::Problem.new(:not_found,
          detail: "Unknown book#{"s" if unknown.size > 1}: #{unknown.join(", ")}"))
        return nil
      end

      found.values_at(*slugs)
    end

    # A Date; nil for an allowed null; :absent when the caller passed :absent
    # (`body.fetch("completed_on", :absent)`). Anything else renders a 400 and
    # returns nil, so callers follow it with `return if performed?`.
    # Future dates are refused so a guessed date cannot be written.
    def completed_on!(raw, allow_nil:)
      return :absent if raw == :absent
      return nil if raw.nil? && allow_nil

      date = begin
        Date.strptime(raw, "%Y-%m-%d") if raw.is_a?(String) && COMPLETED_ON_FORMAT.match?(raw)
      rescue Date::Error
        nil
      end

      if date.nil? || date > latest_allowed_date
        bad_body("completed_on must be a date as YYYY-MM-DD, no later than today's date anywhere (UTC+14)#{" (or null)" if allow_nil}")
        return nil
      end

      date
    end

    # The date it already is in the furthest-ahead zone, so a member east of UTC
    # can record their own today.
    def latest_allowed_date
      Time.current.in_time_zone("Pacific/Kiritimati").to_date
    end

    # Reserves `count` book changes for today, yields, and gives them back
    # unless the block rendered a 2xx (or raised). `now` is read once so the
    # release lands in the same UTC day as the reservation.
    def with_budget(count)
      @library_now = Time.current
      reservation = ::Services::Api::LibraryBudget.reserve(library_user, count, now: @library_now)
      return render_budget_refused(reservation, @library_now) unless reservation.ok?

      kept = false
      begin
        yield
        kept = response.status.between?(200, 299)
      ensure
        ::Services::Api::LibraryBudget.release(library_user, count, now: @library_now) unless kept
      end
    end

    def render_budget_refused(reservation, now)
      seconds = [(reservation.reset_at - now).ceil, 1].max
      response.headers["Retry-After"] = seconds.to_s
      render_problem(::Api::Problem.new(:rate_limited,
        detail: "Daily library limit of #{reservation.limit} book changes reached; #{reservation.remaining} remaining. Retry after #{seconds} seconds."))
    end

    # The batch response: one {book: slug, outcome:} per named book in request
    # order, the list as it now stands, and what is left of today's budget.
    def write_result(list, outcomes, status: :ok)
      list.reload
      count = book_count_for([list]).fetch(list.id, 0)
      render status: status, json: {
        data: outcomes.map { |outcome| {book: outcome[:listable].slug, outcome: outcome[:outcome]} },
        meta: {
          list: ::Api::V1::Books::UserListResource.new(list, params: {book_count: count}).to_h,
          library_changes_remaining: ::Services::Api::LibraryBudget.remaining(library_user, now: @library_now || Time.current)
        }
      }
    end
  end
end
