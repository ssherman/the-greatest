module Services
  module BooksMigration
    # Pure mapping from a legacy description source label -- books.description_source_name
    # or authors.description_source -- onto a Description (source, source_name, license)
    # triple. Shared by BookDescriptionMigrator and AuthorDescriptionMigrator so books and
    # authors normalise by one rule.
    #
    # The legacy labels are dirty: "wikipedia" / "Wikipedia" / "WIkipedia" / "Wikipedia "
    # all mean one source (10,379 books + 8,218 authors), and 659 books + 452 authors state
    # no source at all. Case and whitespace are folded for MATCHING only; the label kept in
    # source_name is stripped but case-preserved, because source_name sits inside the
    # natural-key unique index -- "Publisher " (98 legacy rows) would otherwise be a second
    # distinct row and a near-duplicate label in the admin UI.
    #
    # Anything unrecognised becomes :other carrying its own label, never a guess (D10: no
    # :unknown source, and no licence asserted on text whose origin is not stated). The
    # unattributed rows matter most: none of them has a description_source_url, so a
    # cc_by_sa_4 claim would be an attribution increment (d)'s AttributionComponent could
    # not honour.
    #
    # Never returns :ai_generated or :goodreads. That is load-bearing, not incidental: it is
    # what keeps a normalised row from sharing a conflict key with the row a sibling column
    # already produced for the same record.
    module DescriptionSourceNormalizer
      NAMED = {
        "wikipedia" => {source: :wikipedia, license: :cc_by_sa_4},
        "openlibrary" => {source: :openlibrary, license: :cc0},
        "publisher" => {source: :publisher, license: nil}
      }.freeze

      GOOGLE_LABELS = ["google", "google books"].freeze
      GOOGLE_NAME = "Google Books"
      UNATTRIBUTED_NAME = "Unattributed"

      def self.call(raw_label)
        label = raw_label.to_s.strip
        named = NAMED[label.downcase]

        if named
          {source: named[:source], source_name: nil, license: named[:license]}
        elsif GOOGLE_LABELS.include?(label.downcase)
          {source: :other, source_name: GOOGLE_NAME, license: nil}
        elsif label.blank?
          {source: :other, source_name: UNATTRIBUTED_NAME, license: nil}
        else
          {source: :other, source_name: label, license: nil}
        end
      end
    end
  end
end
