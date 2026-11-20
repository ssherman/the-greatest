# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # The book a verdict's id names now. It is the book itself, or, when the
        # book was merged away, the book it ended up merged into. The merge is
        # found through an approved merge_books verdict (which records the
        # direction), else through the record_redirects row every merge writes,
        # else through a merged duplicate pair, where the other half is the
        # target. The redirect is the only edge an admin merge of two books that
        # were never a duplicate pair leaves (merge_book in the admin UI, API or
        # MCP). A deleted mixed book's redirect is the exception: it points at a
        # guess (the book most of its readers moved to), and moves and copies
        # must not send readers there. So are the redirects its delete passed on
        # from books merged into it earlier. Chains are followed. Merges run before
        # relinks in ApplyVerdicts, and admins merge between passes, so without
        # this a relink naming a merged book would no-op on every pass.
        class MergedBook
          MAX_HOPS = 10

          def self.call(id)
            seen = []
            MAX_HOPS.times do
              return nil if id.nil? || seen.include?(id)

              book = ::Books::Book.find_by(id: id)
              return book if book

              seen << id
              id = merge_target(id)
            end
            nil
          end

          # The id one merge hop from `id`, or nil. Public for Reimport::Apply::Leftovers, which walks the same edges
          # plus a deleted mixed book's redirect.
          def self.merge_target(id)
            target = ::Books::RepairVerdict.merge_books.approved.where("payload->>'source_id' = ?", id.to_s)
              .order(:id).pick(Arel.sql("payload->>'target_id'"))
            return target.to_i if target

            # The redirect before the pair: a redirect has a direction and is repointed when its target is merged
            # in turn, while a pair only names both halves. A pair's survivor that was later merged away again
            # would otherwise be sent back to the half that was folded into it, which is gone, and loop.
            redirected = redirect_target(id)
            return redirected if redirected

            # A pair names no direction, so a half that was folded into this id must not be followed: this id
            # survived that merge, and following the pair would walk back to a gone book (a deleted mixed book
            # that had absorbed duplicates then loops, and Leftovers never reaches its own redirect). A folded-in
            # half either redirects here, or (a merge from before redirects were recorded) is gone and leads
            # nowhere but back through this same pair. An approved merge_books verdict into this id says so too,
            # even after deleting this id blanked the half's redirect.
            others = ::DuplicateCandidate.merged.where(item_type: "Books::Book")
              .where("item_a_id = :id OR item_b_id = :id", id: id).order(id: :desc)
              .pluck(:item_a_id, :item_b_id).map { |a, b| (a == id) ? b : a }
            folded_in = ::RecordRedirect.where(item_type: "Books::Book", from_id: others, to_id: id).pluck(:from_id).to_set
            folded_in.merge(::Books::RepairVerdict.merge_books.approved.where("payload->>'target_id' = ?", id.to_s)
              .where("payload->>'source_id' IN (?)", others.map(&:to_s).presence || [""]).pluck(Arel.sql("payload->>'source_id'")).map(&:to_i))
            others.find { |other| !folded_in.include?(other) && leads_on?(other, id) }
          end

          # Does the pair's other half lead anywhere but back to `id`: it is live, or some other merge edge leaves it?
          def self.leads_on?(other, id)
            return true if ::Books::Book.exists?(other)
            return true if ::Books::RepairVerdict.merge_books.approved.where("payload->>'source_id' = ?", other.to_s).exists?
            return true if redirect_target(other)

            ::DuplicateCandidate.merged.where(item_type: "Books::Book").where("item_a_id = :o OR item_b_id = :o", o: other)
              .where.not("item_a_id = :id OR item_b_id = :id", id: id).exists?
          end

          # A deleted mixed book's redirect is not followed, nor the redirects of books once merged into it, which
          # the delete passed on to the same guess (Reimport::Apply::Mixed records them as redirected_here).
          def self.redirect_target(id)
            return nil if ::Books::RepairVerdict.reimport_mixed.where("payload->>'book_id' = ?", id.to_s).exists?
            return nil if ::Books::RepairVerdict.reimport_mixed.where("payload->'redirected_here' @> ?::jsonb", [id].to_json).exists?

            ::RecordRedirect.where(item_type: "Books::Book", from_id: id).where.not(to_id: nil).pick(:to_id)
          end
          private_class_method :redirect_target, :leads_on?
        end
      end
    end
  end
end
