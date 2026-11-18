# frozen_string_literal: true

module Services
  module EnrichmentQueue
    # Puts one queue row per candidate record of a type, and keeps the open ones
    # honest. Safe to run repeatedly: a record that already has a row is never
    # inserted twice (the unique index decides), a row that was resolved under
    # an older version of the type is re-opened, and a pending row's priority
    # follows the type's priority expression.
    #
    # Candidates are read as (id, priority) pairs, never as records: a queue
    # can hold 160,000 of them.
    class Fill
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      BATCH = 5_000
      UNIQUE_INDEX = :index_enrichment_requests_one_per_record_and_kind

      def self.call(kind:, scope: "ranked", limit: nil)
        new(kind: kind, scope: scope, limit: limit).call
      end

      def initialize(kind:, scope:, limit:)
        @kind = kind
        @scope = scope.to_s
        @limit = limit
      end

      def call
        return failure("unknown scope: #{@scope.inspect}") unless Type::SCOPES.include?(@scope)

        type = Registry.fetch(@kind)
        counts = {inserted: 0, reopened: 0, reprioritized: 0}
        candidate_pairs(type).each_slice(BATCH) do |pairs|
          counts[:inserted] += insert(type, pairs)
          counts[:reopened] += reopen(type, pairs.map(&:first))
          counts[:reprioritized] += reprioritize(type, pairs)
        end
        Result.new(success?: true, data: counts, errors: [])
      rescue Registry::UnknownKind => e
        failure(e.message)
      end

      private

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])

      # [[id, priority], ...], lowest priority value first, then id.
      def candidate_pairs(type)
        priority = Arel.sql(type.priority_sql)
        relation = type.candidates(scope: @scope).reorder(priority, type.target_class.arel_table[:id])
        relation = relation.limit(@limit) if @limit
        relation.pluck(:id, priority).map { |id, value| [id, value.to_i] }
      end

      def insert(type, pairs)
        rows = pairs.map do |id, priority|
          {enrichable_type: type.target_class.polymorphic_name, enrichable_id: id, kind: type.kind,
           reason: "missing", version: type.version, priority: priority, sources: []}
        end
        result = ::EnrichmentRequest.insert_all(rows, unique_by: UNIQUE_INDEX, returning: %w[id])
        result.rows.size
      end

      def reopen(type, ids)
        ::EnrichmentRequest
          .where(kind: type.kind, enrichable_type: type.target_class.polymorphic_name, enrichable_id: ids)
          .where(status: [:done, :skipped])
          .where("version < ?", type.version)
          .update_all(::EnrichmentRequest::REOPEN_RESET.merge(reason: "version", version: type.version, updated_at: Time.current))
      end

      def reprioritize(type, pairs)
        values = pairs.map { |id, priority| "(#{Integer(id)}, #{Integer(priority)})" }.join(", ")
        sql = <<~SQL.squish
          UPDATE enrichment_requests SET priority = v.priority, updated_at = #{::EnrichmentRequest.connection.quote(Time.current)}
          FROM (VALUES #{values}) AS v(id, priority)
          WHERE enrichment_requests.enrichable_id = v.id
            AND enrichment_requests.enrichable_type = #{::EnrichmentRequest.connection.quote(type.target_class.polymorphic_name)}
            AND enrichment_requests.kind = #{::EnrichmentRequest.connection.quote(type.kind)}
            AND enrichment_requests.status = #{::EnrichmentRequest.statuses.fetch("pending")}
            AND enrichment_requests.priority <> v.priority
        SQL
        ::EnrichmentRequest.connection.exec_update(sql)
      end
    end
  end
end
