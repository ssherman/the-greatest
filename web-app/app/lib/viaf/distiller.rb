# frozen_string_literal: true

module Viaf
  # Reduces a VIAF cluster to the ~13 fields worth persisting.
  #
  # Roughly 82% of a cluster is MARC scaffolding around the name forms: each
  # x400 entry spends ~870 bytes to convey a ~25 byte name, and Tolstoy's 1,016
  # entries deduplicate to 777 unique strings. Distilling is a 25-46x reduction
  # with no loss of information we can use.
  #
  # This is deliberately separate from the HTTP client so a future dump-based
  # backfill can reuse it: the dump contains the same cluster records.
  module Distiller
    SCHEMA_VERSION = 2

    # MARC name subfields. Deliberately excludes dates (d/f) and the language
    # and script codes some agencies emit as integer codes.
    NAME_SUBFIELD_CODES = %w[a b c q].freeze

    TITLE_LIMIT = 200
    # A "title" that is only an authority id: NDL files LC's record number
    # ("n2021040535") as one of its works.
    ID_LIKE_TITLE = /\A\p{L}{0,3}\s?\d{6,}\z/

    WITHDRAWN_MARKERS = %w[
      abandoned abandoned_viaf_record scavenged redirect directto
    ].freeze

    module_function

    def call(raw, requested_id:)
      normalized = Normalizer.call(raw)
      guard_withdrawn!(normalized)

      cluster = normalized["VIAFCluster"]
      if cluster.nil?
        raise Exceptions::ParseError.new("No VIAFCluster in response", raw.to_s[0, 500])
      end

      {
        "viaf_id" => requested_id.to_s,
        "name_type" => cluster["nameType"],
        "birth_date" => cluster["birthDate"],
        "death_date" => cluster["deathDate"],
        "date_type" => cluster["dateType"],
        "gender" => cluster.dig("fixed", "gender"),
        "source_ids" => source_ids(cluster),
        "main_headings" => main_headings(cluster),
        "names" => alternate_names(cluster),
        "nationality" => text_values(cluster, "nationalityOfEntity"),
        "language" => text_values(cluster, "languageOfEntity"),
        "occupation" => text_values(cluster, "occupation"),
        "field_of_activity" => text_values(cluster, "fieldOfActivity"),
        "titles" => titles(cluster)
      }
    rescue TypeError, NoMethodError => e
      # `.dig` is used through every intermediate node while Normalizer.array
      # only guards the leaves. If an intermediate arrives as an Array where a
      # Hash was expected, `.dig`/`[]` raise TypeError/NoMethodError instead of
      # a Viaf::Exceptions::Error. Re-raise as ParseError so everything this
      # module raises stays inside the module's exception hierarchy, which is
      # what callers (e.g. PersonSearch) rescue against.
      raise Exceptions::ParseError.new(e.message, raw.to_s[0, 500])
    end

    # Withdrawn markers can sit at the top level of the response (the shape
    # observed for `abandoned`/`abandoned_viaf_record`/`scavenged`) or nested
    # under VIAFCluster (`redirect`, and `directto` nested inside `redirect`).
    # The exact withdrawn-body shape isn't pinned by the spec, so this checks
    # both scopes rather than trying to narrow which marker lives where.
    def guard_withdrawn!(normalized)
      return unless normalized.is_a?(Hash)

      marker = withdrawn_marker(normalized) || withdrawn_marker(normalized["VIAFCluster"])
      return if marker.nil?

      raise Exceptions::AbandonedRecordError, "VIAF cluster is #{marker}"
    end

    def withdrawn_marker(scope)
      return nil unless scope.is_a?(Hash)

      WITHDRAWN_MARKERS.find { |key| scope.key?(key) }
    end

    # sources.source entries look like {"nsid" => ..., "content" => "LC|n  79068416"}.
    # nsid can disagree with content and is sometimes an Integer, so content wins.
    def source_ids(cluster)
      entries = Normalizer.array(cluster.dig("sources", "source"))

      entries.each_with_object({}) do |entry, acc|
        content = entry.is_a?(Hash) ? entry["content"] : entry
        next unless content.is_a?(String) && content.include?("|")

        code, local = content.split("|", 2)
        next if acc.key?(code)

        acc[code] = local.gsub(/\s+/, "")
      end
    end

    def main_headings(cluster)
      Normalizer.array(cluster.dig("mainHeadings", "mainHeadingEl")).filter_map do |entry|
        name = heading_name(entry)
        next if name.blank?

        {
          "source" => Normalizer.array(entry.dig("sources", "s")).first,
          "name" => name,
          "surname_first" => surname_first(entry)
        }
      end
    end

    def alternate_names(cluster)
      Normalizer.array(cluster.dig("x400s", "x400")).filter_map { |entry| heading_name(entry).presence }.uniq
    end

    # MARC21's ind1 (1 = surname entry, 3 = family-name entry) and UNIMARC's
    # ind2 (1 = surname entry) mark a heading as entered under a surname; a 0
    # marks a forename entry, and anything else (a different dtype, a missing
    # indicator, or a blank/"|" value) leaves it unknown.
    def surname_first(entry)
      datafield = entry["datafield"]
      return nil unless datafield.is_a?(Hash)

      case datafield["dtype"]
      when "MARC21"
        case datafield["ind1"].to_s.strip
        when "1", "3" then true
        when "0" then false
        end
      when "UNIMARC"
        case datafield["ind2"].to_s.strip
        when "1" then true
        when "0" then false
        end
      end
    end

    def heading_name(entry)
      subfields = Normalizer.array(entry.dig("datafield", "subfield"))

      parts = subfields.filter_map do |subfield|
        next unless subfield.is_a?(Hash)
        next unless NAME_SUBFIELD_CODES.include?(subfield["code"].to_s)

        subfield["content"].to_s
      end

      parts.join(" ").squish.sub(/[,\s]+\z/, "")
    end

    def text_values(cluster, field)
      Normalizer.array(cluster.dig(field, "data")).filter_map do |entry|
        entry["text"] if entry.is_a?(Hash)
      end.uniq
    end

    # Work titles, the most-catalogued first: how many sources list a work is
    # the best signal of what the person is known for. A title that parses as
    # a number ("1984") arrives as an Integer.
    def titles(cluster)
      works = Normalizer.array(cluster.dig("titles", "work")).filter_map do |work|
        next unless work.is_a?(Hash)

        title = work["title"].to_s.squish
        next if title.blank? || title.match?(ID_LIKE_TITLE)

        [title, Normalizer.array(work.dig("sources", "s")).size]
      end
      works.each_with_index.sort_by { |(_title, count), index| [-count, index] }
        .map { |(title, _count), _index| title }.uniq.first(TITLE_LIMIT)
    end

    # These have no caller outside this module (grepped: Tasks 7/9/10 use only
    # `.call` and SCHEMA_VERSION). Kept private rather than tested directly.
    private_class_method :guard_withdrawn!, :withdrawn_marker, :source_ids,
      :main_headings, :alternate_names, :surname_first, :heading_name, :text_values, :titles
  end
end
