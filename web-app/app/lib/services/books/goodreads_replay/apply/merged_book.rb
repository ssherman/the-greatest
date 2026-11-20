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
        # must not send readers there. Chains are followed. Merges run before
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

            # A pair names no direction, so a half whose redirect points at this id was folded into it: this id
            # survived that merge, and following the pair would walk back to a gone book (a deleted mixed book
            # that had absorbed duplicates then loops, and Leftovers never reaches its own redirect).
            others = ::DuplicateCandidate.merged.where(item_type: "Books::Book")
              .where("item_a_id = :id OR item_b_id = :id", id: id).order(id: :desc)
              .pluck(:item_a_id, :item_b_id).map { |a, b| (a == id) ? b : a }
            folded_in = ::RecordRedirect.where(item_type: "Books::Book", from_id: others, to_id: id).pluck(:from_id).to_set
            others.find { |other| !folded_in.include?(other) }
          end

          def self.redirect_target(id)
            return nil if ::Books::RepairVerdict.reimport_mixed.where("payload->>'book_id' = ?", id.to_s).exists?

            ::RecordRedirect.where(item_type: "Books::Book", from_id: id).where.not(to_id: nil).pick(:to_id)
          end
          private_class_method :redirect_target
        end
      end
    end
  end
end
