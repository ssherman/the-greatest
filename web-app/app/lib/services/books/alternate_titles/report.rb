# frozen_string_literal: true

module Services
  module Books
    module AlternateTitles
      # A plain-text summary of the AI review of books' alternate titles:
      # counts by status, verdict, category and source, a few samples per
      # category, and how many admin-added titles are waiting in review.
      class Report
        SAMPLES = 10

        def self.call
          new.call
        end

        def call
          rows = ::AlternateTitle.where(titleable_type: "Books::Book")
          lines = ["Alternate titles (books) total: #{rows.count}"]
          lines += section("By status", rows.group(:status).count)
          lines += section("By verdict", rows.group(:verdict).count)
          lines += section("By category", rows.group(:category).count)
          lines += section("By source", rows.group(:source).count)
          lines << ""
          lines << "Admin rows in review: #{rows.from_admin.where(status: :review).count}"
          lines += samples(rows)
          lines.join("\n")
        end

        private

        def section(heading, counts)
          ["", "#{heading}:"] + counts.sort_by { |key, _| key.to_s }.map { |key, n| "  #{key || "none"}: #{n}" }
        end

        def samples(rows)
          ::AlternateTitle.categories.keys.flat_map do |category|
            found = rows.where(category: category).includes(:titleable).order(:id).limit(SAMPLES)
            next [] if found.empty?

            ["", "Samples, #{category} (book id, book title, title, confidence, reason):"] +
              found.map { |r| "  #{r.titleable_id}, #{r.titleable&.title}, #{r.title}, #{r.confidence}, #{r.reason}" }
          end
        end
      end
    end
  end
end
