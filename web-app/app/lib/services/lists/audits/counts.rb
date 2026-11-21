module Services
  module Lists
    module Audits
      class Counts
        def self.call
          books = ::ListAudit.joins(:list).where(lists: {type: "Books::List"})
          {
            not_audited: Queue.remaining,
            verified: books.finished.verified.count,
            unverifiable: books.finished.unverifiable.count,
            in_progress: books.in_progress.count
          }
        end
      end
    end
  end
end
