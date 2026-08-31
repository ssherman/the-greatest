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
    SCHEMA_VERSION = 1

    # MARC name subfields. Deliberately excludes dates (d/f) and the language
    # and script codes some agencies emit as integer codes.
    NAME_SUBFIELD_CODES = %w[a b c q].freeze

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
        "field_of_activity" => text_values(cluster, "fieldOfActivity")
      }
    end

    def guard_withdrawn!(normalized)
      return unless normalized.is_a?(Hash)

      marker = WITHDRAWN_MARKERS.find { |key| normalized.key?(key) }
      return if marker.nil?

      raise Exceptions::AbandonedRecordError, "VIAF cluster is #{marker}"
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

        {"source" => Normalizer.array(entry.dig("sources", "s")).first, "name" => name}
      end
    end

    def alternate_names(cluster)
      Normalizer.array(cluster.dig("x400s", "x400")).filter_map { |entry| heading_name(entry).presence }.uniq
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
  end
end
