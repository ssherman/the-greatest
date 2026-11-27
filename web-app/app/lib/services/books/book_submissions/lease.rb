# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # What every review service shares: the result shape, the lease rules, the
      # input rules and the acting reviewer.
      #
      # A lease lives on the submission row (lease_token, lease_expires_at,
      # claimed_by_id). Through the API (`via: "api"`) every write needs the live
      # matching token; the admin page (`via: "admin_ui"`) needs none, because an
      # admin may act on a row an agent holds or on one flagged needs_human.
      #
      # Check order, as in Services::EnrichmentQueue::Submit: state and lease are
      # judged first (:conflict), input second (:invalid). A caller with a stale
      # token therefore always hears "conflict", even when its note is also bad.
      # Every final write is then one conditional UPDATE that repeats the lease
      # condition (`guard`), so two callers cannot both win.
      module Lease
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        DURATION = 30.minutes
        VIAS = %w[api admin_ui].freeze
        ADMIN_ROW_REFUSAL = "This book was requested by an admin agent; only that agent re-requests it."
        MAX_NOTE = 1_000
        MAX_SOURCES = 20
        MAX_URL = 2_000
        # Rows an admin or an agent may still decide: what `reviewable` selects,
        # minus the status half, which is for the claim.
        OPEN_REVIEWS = %w[pending needs_human].freeze

        module_function

        def success(data = {}) = Result.new(success?: true, data: data, errors: [])

        def failure(code, detail) = Result.new(success?: false, data: nil, errors: [{code: code, detail: detail}])

        def via!(via)
          via = via.to_s
          raise ArgumentError, "via must be one of #{VIAS.join(", ")}" unless VIAS.include?(via)

          via
        end

        # Sets Current's reviewer for the call, so the merger's and the
        # promotion's own closing of other readers' rows is attributed, and puts
        # back what was there afterwards.
        def acting(user, via)
          previous = [Current.acting_user, Current.acting_via]
          Current.acting_user = user
          Current.acting_via = via
          yield
        ensure
          Current.acting_user, Current.acting_via = previous
        end

        # nil when the caller may write; otherwise a :conflict result.
        def lease_failure(row, token, via)
          return nil unless via == "api"
          return failure(:conflict, "the lease token does not match this submission") unless token_matches?(row, token)
          return failure(:conflict, "the lease has expired") unless row.lease_expires_at && row.lease_expires_at > Time.current

          nil
        end

        def token_matches?(row, token)
          token.is_a?(String) && row.lease_token.present? && ActiveSupport::SecurityUtils.secure_compare(row.lease_token, token)
        end

        # The write's own lease condition, so a lease lost since the read loses.
        def guard(scope, token, via)
          return scope unless via == "api"

          scope.where(lease_token: token.to_s).where("lease_expires_at > ?", Time.current)
        end

        # The columns a decision stamps on the row it closes.
        def closing(review_status, user:, via:, note:, sources:)
          {review_status: review_status, reviewed_by_id: user.id, reviewed_via: via, reviewed_at: Time.current,
           review_note: note, review_sources: sources, lease_token: nil, lease_expires_at: nil, updated_at: Time.current}
        end

        # nil when the note (and, if required, the sources) are usable. Everything
        # that will be written is checked here, before anything permanent: text
        # with a NUL or invalid UTF-8 would raise at the write, and in Merge
        # that is after the merge.
        def input_failure(note:, sources:, sources_required: false)
          unless note.is_a?(String) && clean?(note) && note.strip.present? && note.length <= MAX_NOTE
            return failure(:invalid, "note must be 1 to #{MAX_NOTE} characters of valid text")
          end
          sources = [] if sources.nil?
          unless sources.is_a?(Array) && sources.size <= MAX_SOURCES
            return failure(:invalid, "sources must be a list of at most #{MAX_SOURCES} urls")
          end
          return failure(:invalid, "sources must name at least one url") if sources_required && sources.empty?
          return nil if sources.all? { |source| url?(source) }

          failure(:invalid, "every one of sources must be an http or https url of at most #{MAX_URL} characters")
        end

        def clean?(text) = text.dup.force_encoding(Encoding::UTF_8).valid_encoding? && !text.include?("\u0000")

        def url?(source)
          return false unless source.is_a?(String) && clean?(source) && source.length <= MAX_URL

          uri = URI.parse(source)
          uri.is_a?(URI::HTTP) && uri.host.present?
        rescue URI::InvalidURIError
          false
        end
      end
    end
  end
end
