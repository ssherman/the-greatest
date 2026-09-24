module Admin
  # View helpers shared by the match decisions and duplicate candidates pages.
  module ImportFinderAuditHelper
    # Keys a stored query may carry for its creators. Snapshots are per-domain
    # hashes (books: title/author_names/year; albums: title/artist; artists:
    # name), so this reads whichever is present rather than one ImportQuery.
    CREATOR_KEYS = %w[author_names artist artist_names company_names].freeze

    # Identifier keys a stored query may carry, across every domain's ImportQuery.
    IDENTIFIER_QUERY_KEYS = %w[
      isbn13 isbn10 asin goodreads_id open_library_work_key
      musicbrainz_id release_group_musicbrainz_id musicbrainz_recording_id igdb_id
    ].freeze

    # The stored query in one line: title or name, creators, year. A query
    # with none of those (an identifier-only import) shows as its JSON.
    def audit_query_line(decision)
      query = decision.query.to_h
      parts = [query["title"].presence || query["name"].presence]
      creators = CREATOR_KEYS.filter_map { |key| query[key].presence }.first
      parts << "by #{Array(creators).join(", ")}" if creators
      parts << "(#{query["year"]})" if query["year"].present?
      parts.compact.join(" | ").presence || query.to_json
    end

    def audit_record_label(record)
      record.respond_to?(:title) ? record.title : record.name
    end

    # Identifier values the query and a candidate snapshot both carry, plus
    # the value the Identifiers source matched on when the snapshot names it.
    def audit_shared_identifiers(decision, candidate)
      query = decision.query.to_h
      wanted = IDENTIFIER_QUERY_KEYS.flat_map { |key| Array(query[key]) }.map(&:to_s).compact_blank
      evidence = candidate.to_h["evidence"].to_h
      held = Array(evidence["identifiers"]).map { |identifier| identifier.to_h["value"].to_s }
      shared = wanted & held
      matched = evidence["matched_identifier"]
      shared |= [matched["value"].to_s] if matched.is_a?(Hash) && matched["value"].present?
      shared
    end
  end
end
