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

    def self.call(domain:, store:, version: nil)
      domain = domain.to_s
      version ||= store.read_pointer(Paths.model_latest(domain))
      return skipped(version, "no model published") if version.nil?

      existing = RecommendationModel.find_by(domain: domain, version: version)
      return skipped(version, "already #{existing.state}") if existing && !existing.loading?

      manifest = JSON.parse(store.get(Paths.model_manifest(domain, version)))
      model = existing || RecommendationModel.create!(domain: domain, version: version, manifest: manifest, state: :loading)
      model.update!(manifest: manifest) if existing
      model.recommendation_item_neighbors.in_batches(of: BATCH).delete_all if existing

      rows = insert_rows(model, store.get(Paths.model(domain, version)))
      expected = manifest.fetch("rows").to_i
      if rows != expected
        return Result.new(success?: false, data: {loaded: false, version: version, rows: rows},
          errors: ["#{domain} #{version}: inserted #{rows} rows but the manifest says #{expected}; left in loading"])
      end

      RecommendationModel.transaction do
        RecommendationModel.active.where(domain: domain).where.not(id: model.id).find_each { |m| m.update!(state: :retired) }
        model.update!(state: :active)
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

    private_class_method :insert_rows, :skipped
  end
end
