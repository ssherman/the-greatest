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

  test "the unique index allows one export per configuration" do
    CsvExport.create!(ranking_configuration: @config)

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

  test "downloadable whenever a file is attached, whatever the latest attempt says" do
    export = CsvExport.create!(ranking_configuration: @config, status: :ready)
    refute export.downloadable?

    export.file.attach(io: StringIO.new("\uFEFFRank\n"), filename: "x.csv", content_type: "text/csv")
    assert export.downloadable?

    export.update!(status: :generating)
    assert export.downloadable?, "the last good file is served during a regeneration"

    export.update!(status: :failed)
    assert export.downloadable?, "the last good file is served after a failed regeneration"
  end

  test "the claimable scope agrees with claimable?" do
    pending = CsvExport.create!(ranking_configuration: @config)
    fresh = CsvExport.create!(ranking_configuration: ranking_configurations(:music_albums_secondary),
      status: :generating, requested_at: 1.minute.ago)
    stale = CsvExport.create!(ranking_configuration: ranking_configurations(:music_songs_secondary),
      status: :generating, requested_at: (CsvExport::GENERATION_STALE_AFTER + 1.minute).ago)
    unstamped = CsvExport.create!(ranking_configuration: ranking_configurations(:books_inherited),
      status: :generating, requested_at: nil)

    assert_equal [pending, stale, unstamped].map(&:id).sort, CsvExport.claimable.pluck(:id).sort
    [pending, fresh, stale, unstamped].each do |export|
      assert_equal export.claimable?, CsvExport.claimable.exists?(export.id), "#{export.status} disagrees"
    end
  end

  test "is destroyed with its configuration, attachment included" do
    export = CsvExport.create!(ranking_configuration: @config)
    export.file.attach(io: StringIO.new("\uFEFFRank\n"), filename: "x.csv", content_type: "text/csv")
    attachment_id = export.file.attachment.id

    @config.destroy!

    assert_nil CsvExport.find_by(id: export.id)
    assert_nil ActiveStorage::Attachment.find_by(id: attachment_id)
  end
end
