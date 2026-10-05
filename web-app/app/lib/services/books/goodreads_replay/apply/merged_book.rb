# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # The book a verdict's id names now. It is the book itself, or, when the
        # book was merged away, the book it ended up merged into. The merge is
        # found through an approved merge_books verdict (which records the
        # direction), else through a merged duplicate pair, where the other half
        # is the target. Chains are followed. Merges run before relinks in
        # ApplyVerdicts, and admins merge between passes, so without this a
        # relink naming a merged book would no-op on every pass.
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

          def self.merge_target(id)
            target = ::Books::RepairVerdict.merge_books.approved.where("payload->>'source_id' = ?", id.to_s)
              .order(:id).pick(Arel.sql("payload->>'target_id'"))
            return target.to_i if target

            pair = ::DuplicateCandidate.merged.where(item_type: "Books::Book")
              .where("item_a_id = :id OR item_b_id = :id", id: id).order(id: :desc).first
            pair && ((pair.item_a_id == id) ? pair.item_b_id : pair.item_a_id)
          end

          private_class_method :merge_target
        end
      end
    end
  end
end
