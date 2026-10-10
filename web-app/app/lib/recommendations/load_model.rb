# frozen_string_literal: true

require "zlib"
require "csv"

module Recommendations
  # Pull a published model into Postgres (spec 2 §5). Idempotent per version:
  # the hourly job can run forever and only ever inserts a version once. The
  # swap to `active` and the retirement of the previous model happen in one
  # transaction, after the row count is checked against the manifest, so a
  # short file never replaces a good model.
  module LoadModel
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)
    BATCH = 10_000

    # One load per domain at a time: a second caller (cron beside a retry, or
    # the rake task beside the job) would otherwise take the other's `loading`
    # row for a crashed load and delete rows out from under it.
    def self.call(domain:, store:, version: nil)
      domain = domain.to_s
      conn = ActiveRecord::Base.connection
      key = "SELECT %s(hashtext(#{conn.quote("recommendations_load_#{domain}")}))"
      # uncached: an identical SELECT inside a query-cache scope would replay
      # the first answer instead of asking Postgres again.
      locked = conn.uncached { conn.select_value(key % "pg_try_advisory_lock") }
      return skipped(version, "another load holds the lock") unless locked
      begin
        load_locked(domain, store, version)
      ensure
        conn.uncached { conn.select_value(key % "pg_advisory_unlock") }
      end
    end

    def self.load_locked(domain, store, version)
      version ||= store.read_pointer(Paths.model_latest(domain))
      return skipped(version, "no model published") if version.nil?

      existing = RecommendationModel.find_by(domain: domain, version: version)
      return skipped(version, "already #{existing.state}") if existing && !existing.loading?

      manifest = JSON.parse(store.get(Paths.model_manifest(domain, version)))
      model = existing || RecommendationModel.create!(domain: domain, version: version, manifest: manifest, state: :loading)
      model.update!(manifest: manifest) if existing
      model.recommendation_item_neighbors.in_batches(of: BATCH).delete_all if existing

      insert_rows(model, store.get(Paths.model(domain, version)))
      expected = manifest.fetch("rows").to_i
      rows = nil
      RecommendationModel.transaction do
        # Count what the signal will read, not what was parsed.
        rows = model.recommendation_item_neighbors.count
        next if rows != expected
        RecommendationModel.active.where(domain: domain).where.not(id: model.id).find_each { |m| m.update!(state: :retired) }
        model.update!(state: :active)
      end
      if rows != expected
        return Result.new(success?: false, data: {loaded: false, version: version, rows: rows},
          errors: ["#{domain} #{version}: #{rows} rows in the table but the manifest says #{expected}; left in loading"])
      end

      RecommendationModel.retired.where(domain: domain).find_each do |m|
        m.recommendation_item_neighbors.in_batches(of: BATCH).delete_all
        m.destroy!
      end
      Result.new(success?: true, errors: [], data: {loaded: true, version: version, rows: rows})
    end

    def self.insert_rows(model, gzipped)
      rows = 0
      buffer = []
      flush = lambda do
        RecommendationItemNeighbor.insert_all(buffer) if buffer.any?
        rows += buffer.size
        buffer = []
      end
      csv = CSV.new(Zlib.gunzip(gzipped), headers: true)
      csv.each do |row|
        buffer << {recommendation_model_id: model.id, item_id: row["item_id"].to_i, neighbor_id: row["neighbor_id"].to_i, weight: row["weight"].to_f}
        flush.call if buffer.size >= BATCH
      end
      flush.call
      rows
    end

    def self.skipped(version, reason)
      Result.new(success?: true, errors: [], data: {loaded: false, version: version, rows: 0, reason: reason})
    end

    private_class_method :load_locked, :insert_rows, :skipped
  end
end
