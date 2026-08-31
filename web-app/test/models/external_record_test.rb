# frozen_string_literal: true

require "test_helper"

# == Schema Information
#
# Table name: external_records
#
#  id             :bigint           not null, primary key
#  fetched_at     :datetime         not null
#  payload        :jsonb            not null
#  schema_version :integer          default(1), not null
#  source         :integer          not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  source_id      :string           not null
#
# Indexes
#
#  index_external_records_on_source_and_fetched_at  (source,fetched_at)
#  index_external_records_on_source_and_source_id   (source,source_id) UNIQUE
#
class ExternalRecordTest < ActiveSupport::TestCase
  test "valid with required attributes" do
    record = ExternalRecord.new(
      source: :viaf,
      source_id: "96987389",
      payload: {"viaf_id" => "96987389"},
      fetched_at: Time.current
    )

    assert record.valid?
  end

  test "requires source_id" do
    record = ExternalRecord.new(source: :viaf, payload: {}, fetched_at: Time.current)

    assert_not record.valid?
    assert_includes record.errors[:source_id], "can't be blank"
  end

  test "requires payload" do
    record = ExternalRecord.new(source: :viaf, source_id: "1", fetched_at: Time.current)

    assert_not record.valid?
    assert_includes record.errors[:payload], "can't be blank"
  end

  test "source_id is unique per source" do
    ExternalRecord.create!(
      source: :viaf, source_id: "96987389", payload: {}, fetched_at: Time.current
    )

    duplicate = ExternalRecord.new(
      source: :viaf, source_id: "96987389", payload: {}, fetched_at: Time.current
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:source_id], "has already been taken"
  end

  test "schema_version defaults to 1" do
    record = ExternalRecord.create!(
      source: :viaf, source_id: "1", payload: {}, fetched_at: Time.current
    )

    assert_equal 1, record.schema_version
  end

  test "stale scope returns records fetched before the cutoff" do
    old = ExternalRecord.create!(
      source: :viaf, source_id: "old", payload: {}, fetched_at: 10.days.ago
    )
    ExternalRecord.create!(
      source: :viaf, source_id: "fresh", payload: {}, fetched_at: 1.hour.ago
    )

    assert_equal [old], ExternalRecord.stale(3.days.ago).to_a
  end

  test "source enum exposes viaf" do
    record = ExternalRecord.new(source: :viaf)

    assert record.viaf?
    assert_equal "viaf", record.source
  end
end
