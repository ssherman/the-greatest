# frozen_string_literal: true

module Books
  module OpenLibrary
    # One scored candidate from a `/resolve` response. `verdict` here is
    # never re-derived client-side -- it is exactly what the service decided
    # for this candidate (see Resolution for the one authoritative verdict
    # of the whole response, `decision.verdict`).
    #
    # Subclassing `Data.define(...)` (rather than passing it a block) so
    # DiffEntry can be a real nested constant -- Standard's
    # Lint/ConstantDefinitionInBlock rejects a constant assigned inside a
    # `Data.define do ... end` block.
    class Candidate < Data.define(
      :work_key, :source, :score, :rules, :margin, :verdict,
      :evidence, :conflicting_features, :diff, :record
    )
      # One row of the work-level diff between the query and this
      # candidate's record. `kind` is kept as the server's raw string rather
      # than mapped onto an enum, so a future kind the client doesn't know
      # about round-trips instead of raising.
      DiffEntry = Data.define(:field, :ours, :theirs, :kind)

      def self.from_record(record, source_version:)
        diff = (record["diff"] || []).map do |entry|
          DiffEntry.new(field: entry["field"], ours: entry["ours"], theirs: entry["theirs"], kind: entry["kind"])
        end

        new(
          work_key: record.dig("key", "key"),
          source: record.dig("key", "source"),
          score: record["score"],
          rules: record["rules"] || [],
          margin: record["margin"],
          verdict: record["verdict"],
          evidence: (record["evidence"] || {}).deep_symbolize_keys,
          conflicting_features: record["conflicts"] || [],
          diff: diff,
          record: record["record"] && Work.from_record(record["record"], source_version: source_version)
        )
      end

      def accept?
        verdict == "accept"
      end

      def abstain?
        verdict == "abstain"
      end

      def reject?
        verdict == "reject"
      end

      def fills
        diff.select { |entry| entry.kind == "fill" }
      end

      def conflicts
        diff.select { |entry| entry.kind == "conflict" }
      end

      def enrichments
        diff.select { |entry| entry.kind == "enrichment" }
      end
    end
  end
end
