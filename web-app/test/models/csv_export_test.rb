# frozen_string_literal: true

require "test_helper"

class CsvExportTest < ActiveSupport::TestCase
  setup do
    @config = ranking_configurations(:games_secondary)
  end

  test "starts pending with no file" do
    export = CsvExport.create!(ranking_configuration: @config)

    assert export.pending?
    refute export.file.attached?
    refute export.downloadable?
  end

  test "one export per configuration" do
    CsvExport.create!(ranking_configuration: @config)

    duplicate = CsvExport.new(ranking_configuration: @config)
    refute duplicate.valid?
    assert_includes duplicate.errors[:ranking_configuration_id], "has already been taken"

    # insert_all (no bang) would skip the duplicate silently; the bang form raises.
    assert_raises(ActiveRecord::RecordNotUnique) do
      CsvExport.insert_all!([{ranking_configuration_id: @config.id, status: 0, created_at: Time.current, updated_at: Time.current}])
    end
  end

  test "pending, ready and failed exports are claimable" do
    export = CsvExport.create!(ranking_configuration: @config)
    assert export.claimable?

    export.update!(status: :ready)
    assert export.claimable?

    export.update!(status: :failed)
    assert export.claimable?
  end

  test "a fresh generation claim is not claimable" do
    export = CsvExport.create!(ranking_configuration: @config, status: :generating, requested_at: 5.minutes.ago)

    refute export.claimable?
  end

  test "a generation claim older than the stale window is claimable again" do
    export = CsvExport.create!(ranking_configuration: @config, status: :generating,
      requested_at: (CsvExport::GENERATION_STALE_AFTER + 1.minute).ago)

    assert export.claimable?
  end

  test "a generating claim with no requested_at is treated as abandoned" do
    export = CsvExport.create!(ranking_configuration: @config, status: :generating, requested_at: nil)

    assert export.claimable?
  end

  test "downloadable only when ready with a file attached" do
    export = CsvExport.create!(ranking_configuration: @config, status: :ready)
    refute export.downloadable?

    export.file.attach(io: StringIO.new("﻿Rank\n"), filename: "x.csv", content_type: "text/csv")
    assert export.downloadable?

    export.update!(status: :failed)
    refute export.downloadable?
  end

  test "is destroyed with its configuration" do
    export = CsvExport.create!(ranking_configuration: @config)

    @config.destroy!

    assert_nil CsvExport.find_by(id: export.id)
  end
end
