module Services
  module BooksMigration
    # Legacy `reviews` -> the global polymorphic `reviews` table (reviewable =
    # ::Books::Book, which preserves its legacy id, so no LegacyIdMap lookup is needed).
    # Legacy review ids and timestamps are preserved too.
    #
    # unique_by is nil ON PURPOSE. Preserved ids mean a re-run collides on BOTH
    # reviews_pkey and index_reviews_on_user_and_reviewable, and an arbiter naming only
    # one of them lets the other raise and abort the batch. Untargeted
    # ON CONFLICT DO NOTHING absorbs either.
    #
    # Dedup is done here in Ruby rather than with DISTINCT ON in the legacy query: every
    # migrator test stubs legacy_each, so a SQL-level filter could not be tested at all.
    # Rows arrive newest-first and @seen keeps the first occurrence of each natural key,
    # which is the newer row. 123 legacy pairs are affected; none has body text on either
    # side, and 41 disagree on rating, so "newer wins" has to be a stated rule rather
    # than whatever ON CONFLICT happens to keep.
    #
    # insert_all bypasses Review's before_validation AND its after_commit, so the body is
    # sanitized explicitly here and review_summaries is rebuilt afterwards by
    # SummaryRecalculator.backfill_all! (see the data_migration:reviews rake task).
    #
    # In data_migration:sync (spec §6) it overwrites instead, routes each book through
    # redirects, and deletes legacy-origin books reviews that legacy no longer has.
    # See flush.
    class ReviewMigrator < InsertOnlyMigrator
      # Same list BodySanitizer#render partitions spoiler-marker search scopes on --
      # see convert_spoiler_tag below for why a legacy <spoiler> wrapping one of these
      # needs different handling than the ordinary case.
      BLOCK_BOUNDARY_TAGS = Services::Reviews::BodySanitizer::SPOILER_SCOPE_BOUNDARY_TAGS

      private

      def legacy_model
        LegacyBooks::Review
      end

      def model_key
        "Review"
      end

      def target_model
        ::Review
      end

      # See the class comment. Not a mistake, not an omission.
      def unique_by
        nil
      end

      # Legacy created_at/updated_at are supplied in build_rows and must survive.
      def record_timestamps?
        false
      end

      def preload_context
        @book_ids = ::Books::Book.pluck(:id).to_set
        @user_ids = ::User.pluck(:id).to_set
        @seen = Set.new
        return unless sync

        @route = BookRoute.new(sync, book_ids_here: @book_ids)
        @here_ids = legacy_origin_reviews.pluck(:id).to_set
        @kept_ids = Set.new
        @written_keys = Set.new
        @stats = {inserted: 0, deleted: 0, dropped: 0, waiting: 0, collisions: 0, held_by_new_app: 0}
      end

      # insert_all with explicit ids never advances the sequence, so without this the
      # first review a real user writes collides with a migrated row -- and it must sit
      # at the reserved ceiling, not max + 1, or new reviews take ids legacy will use.
      # finalize runs outside without_search_indexing, so keep it callback-free.
      def finalize
        delete_reviews_legacy_lacks if sync
        Services::BooksMigration.bump_sequence_to_floor!("reviews")
      end

      def extra_result_data
        sync ? @stats : {}
      end

      # Newest-first so the dedup below keeps the newer of a duplicated pair.
      def legacy_each(&block)
        legacy_model.find_each(batch_size: BATCH_SIZE, order: :desc) do |record|
          block.call(record.attributes)
        end
      end

      def build_rows(attrs)
        Services::BooksMigration.raise_if_at_ceiling!("reviews", attrs["id"])

        book_id = sync ? routed_book_id(attrs) : attrs["book_id"]
        return [] if book_id.nil?

        # In sync mode the route has already placed the book, and flush locks it.
        unless sync || @book_ids.include?(book_id)
          raise "no migrated ::Books::Book for legacy reviews.book_id=#{book_id.inspect}"
        end

        user_id = attrs["user_id"]
        unless @user_ids.include?(user_id)
          raise "no migrated ::User for legacy reviews.user_id=#{user_id.inspect}"
        end

        # First occurrence wins, and rows arrive newest-first.
        unless @seen.add?([user_id, book_id])
          @stats[:collisions] += 1 if sync
          return []
        end

        [{
          id: attrs["id"],
          user_id: user_id,
          reviewable_type: "Books::Book",
          reviewable_id: book_id,
          title: attrs["title"]&.strip.presence,
          body: body_for(attrs),
          rating: attrs["rating"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end

      # nil drops the row; the reason is counted.
      def routed_book_id(attrs)
        book_id = @route.call(attrs["book_id"])
        case book_id
        when :deleted, :waiting
          @stats[(book_id == :deleted) ? :dropped : :waiting] += 1
          nil
        when :missing
          raise "legacy reviews.book_id=#{attrs["book_id"]} is neither here nor redirected (removed without callbacks)"
        else
          book_id
        end
      end

      # Sync mode overwrites (spec §6) instead of insert-only, keyed on the id. A
      # different legacy-origin review holding the same user and book (the older
      # side of a merge collision, or one a replay relink moved here) is deleted
      # first, so the unique index takes the winner. A new-app review holding it
      # wins instead, and the legacy row is skipped.
      def flush(rows)
        return super unless sync

        writable = []
        ::Review.transaction do
          attempts = 0
          until rows.empty? || @route.lock(rows.map { |row| row[:reviewable_id] })
            raise "reviews: books kept vanishing mid-run; re-run the sync" if (attempts += 1) > 3

            rows = reroute(rows)
          end

          holders = ::Review
            .where(reviewable_type: "Books::Book", user_id: rows.map { |row| row[:user_id] },
              reviewable_id: rows.map { |row| row[:reviewable_id] })
            .pluck(:user_id, :reviewable_id, :id)
            .to_h { |user_id, book_id, id| [[user_id, book_id], id] }
          ceiling = RESERVED_CEILINGS.fetch("reviews")
          stale = []
          writable = rows.select do |row|
            holder = holders[[row[:user_id], row[:reviewable_id]]]
            next true if holder.nil? || holder == row[:id]

            if holder >= ceiling
              @stats[:held_by_new_app] += 1
              next false
            end
            stale << holder
            true
          end

          ::Review.where(id: stale).delete_all if stale.any?
          ::Review.upsert_all(writable, unique_by: :id, record_timestamps: false) if writable.any?
        end
        @kept_ids.merge(writable.map { |row| row[:id] })
        @written_keys.merge(writable.map { |row| [row[:user_id], row[:reviewable_id]] })
        @count += writable.size
      end

      # A book merged or deleted after this run started (route.lock reloaded the
      # redirects): route each row again, drop rows on a deleted book, and keep
      # the first (newest) row per user and book. Rows arrive newest first, so a
      # pair an earlier batch already wrote holds the newer review: a row rerouted
      # onto it is a collision, not a replacement.
      def reroute(rows)
        batch_keys = Set.new
        rows.filter_map do |row|
          book_id = @route.call(row[:reviewable_id])
          if book_id == :deleted
            @stats[:dropped] += 1
            next
          end
          unless book_id.is_a?(Integer)
            raise "legacy reviews.id=#{row[:id]}: book #{row[:reviewable_id]} is neither here nor redirected"
          end
          key = [row[:user_id], book_id]
          if @written_keys.include?(key) || !batch_keys.add?(key)
            @stats[:collisions] += 1
            next
          end

          @seen << key
          row.merge(reviewable_id: book_id)
        end
      end

      # Every legacy-origin books review the run did not keep: legacy deleted it,
      # it lost a collision, or its book was deleted here. Counted against the
      # ids here at the start, as UserDataDiff counts them.
      def delete_reviews_legacy_lacks
        doomed = (@here_ids - @kept_ids).to_a.sort
        Services::BooksMigration.guard_deletion!("reviews", doomed.size, @here_ids.size)
        doomed.each_slice(1_000) { |ids| ::Review.where(id: ids).delete_all }
        @stats[:inserted] = (@kept_ids - @here_ids).size
        @stats[:deleted] = doomed.size
      end

      def legacy_origin_reviews
        ::Review.where(reviewable_type: "Books::Book", id: ...RESERVED_CEILINGS.fetch("reviews"))
      end

      # The cap runs AFTER sanitizing: <script> contents survive sanitizing as visible
      # text, so the 462KB fuzz paste is only over-length once cleaned. One legacy row
      # (101561) is affected; it imports as rating-only.
      def body_for(attrs)
        body = Services::Reviews::BodySanitizer.call(convert_legacy_spoilers(attrs["body"]))
        return nil if body.nil?

        if body.length > ::Review::MAX_BODY_LENGTH
          Rails.logger.warn(
            "ReviewMigrator: dropped body of legacy review id=#{attrs["id"]} " \
            "(#{body.length} chars after sanitizing, cap #{::Review::MAX_BODY_LENGTH})"
          )
          return nil
        end

        body
      end

      # Legacy stored a spoiler as a literal <spoiler> tag. BodySanitizer no longer
      # knows that tag -- spoilers are ||markers|| now -- so without this pre-pass the
      # sanitizer below would unwrap it like any other disallowed tag and publish
      # every legacy spoiler in the clear at the cutover (see BodySanitizer's header
      # for why `spoiler` and `span` are both deliberately absent from its allowlist).
      #
      # Parser-based, not string substitution: legacy bodies are untrusted HTML, and a
      # marker robust enough to survive naive replacement also survives inside a
      # quoted attribute value -- the exact failure BodySanitizer's own header
      # documents from this file's original write-time conversion.
      #
      # Mirrors Services::Reviews::SpoilerSpanConverter, which solved the identical
      # problem for stored <span class="review-spoiler">. Verified against the 118
      # legacy rows that actually contain a <spoiler> tag with a read-only runner
      # probe against the legacy DB (not a test -- no test may touch that database):
      # both of that converter's hard-won lessons are real here too, so this reuses
      # its two-path approach rather than the simpler "always flatten to .text" one.
      #
      # No pre-parse string fast path (e.g. checking body.include?("<spoiler")) before
      # the real Nokogiri parse below: `fragment.css("spoiler")` is case-insensitive by
      # construction (the HTML5 parser lowercases tag names on the way in), and a
      # string check narrow enough to mirror that exactly would just be a second,
      # harder-to-keep-in-sync copy of what css() already does correctly. A prior
      # version of this guard checked for the lowercase literal only and let an
      # uppercase `<SPOILER>` tag skip conversion entirely -- same input, unwrapped in
      # the clear instead of hidden.
      def convert_legacy_spoilers(body)
        return body if body.blank?

        fragment = Nokogiri::HTML5.fragment(body.to_s)
        spoilers = fragment.css("spoiler")
        return body if spoilers.empty?

        spoilers.each { |node| convert_spoiler_tag(node, fragment.document) }
        fragment.to_html
      end

      # Unwraps one <spoiler>: its children move out to where the tag was, sandwiched
      # between two literal "||" text nodes, so inline markup inside stays exactly
      # what it was -- only the <spoiler> wrapper is gone. 31 of the 118 legacy rows
      # wrap a <br> and 2 wrap an <i>; flattening to `.text` (the simpler approach)
      # would collapse those into a run-on string with the line breaks and formatting
      # silently gone.
      #
      # A <spoiler> with a block-level descendant (p or blockquote --
      # BLOCK_BOUNDARY_TAGS) cannot go through that path: a block element is a
      # spoiler SCOPE boundary at render time (BodySanitizer#convert_spoiler_scope),
      # so the "||" this would place before it and the "||" placed after it end up in
      # two different search scopes and never pair up -- everything after the block
      # child would render in the clear instead of inside a spoiler. Falls back to
      # flattening the whole node to `.text` instead: that loses this spoiler's
      # internal formatting, but the result is one text run with both markers in the
      # same scope, so it stays hidden. Reachable with real data: legacy review 88697
      # has two <blockquote>s nested inside its <spoiler>.
      #
      # Not handled: a legacy row whose <spoiler> text already contains "||" would
      # unbalance the marker pairing this inserts (see SpoilerSpanConverter's class
      # comment for the same caveat). Verified absent from all 118 real rows.
      #
      # Also not handled: a NESTED <spoiler> (one inside another) partially leaks.
      # fragment.css("spoiler") above yields both nodes in document order -- outer
      # first, then inner -- and this method is called once per node with no
      # awareness of the other call. Unwrapping the outer node first inserts "||"
      # around ALL of its text, inner tag included; unwrapping the inner node then
      # inserts a second "||" pair around just its own text, splitting what was one
      # marker pair into two adjacent ones. "<spoiler>a<spoiler>b</spoiler>c</spoiler>"
      # becomes "||a||b||c||", which BodySanitizer's non-greedy matching reads as two
      # spoilers ("a" and "c") with "b" sitting unmatched, in the clear, between them.
      # Verified absent from all 118 real rows -- none nests a <spoiler>.
      def convert_spoiler_tag(node, document)
        if node.css(BLOCK_BOUNDARY_TAGS.join(",")).any?
          node.replace(Nokogiri::XML::Text.new("||#{node.text}||", document))
          return
        end

        node.add_previous_sibling(Nokogiri::XML::Text.new("||", document))
        # .to_a snapshots the child list before mutating it -- add_previous_sibling
        # reparents each child as it runs, and each new insertion lands immediately
        # before the (still-present) node, i.e. right after the previous insertion,
        # so original child order is preserved.
        node.children.to_a.each { |child| node.add_previous_sibling(child) }
        node.add_previous_sibling(Nokogiri::XML::Text.new("||", document))
        node.remove
      end
    end
  end
end
