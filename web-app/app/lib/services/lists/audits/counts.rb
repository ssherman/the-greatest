module Services
  module Lists
    module Audits
      # Agrees with the index filters: a list counts by its latest finished audit,
      # and in_progress means an unexpired open audit.
      class Counts
        def self.call
          books = ::ListAudit.joins(:list).where(lists: {type: "Books::List"})
          latest = books.latest_done
          {
            not_audited: Queue.remaining,
            verified: latest.verified.count,
            unverifiable: latest.unverifiable.count,
            in_progress: books.open.count
          }
        end
      end
    end
  end
end
