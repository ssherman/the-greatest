require "test_helper"

class Services::BooksMigration::MigratorSyncTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  class Probe < Services::BooksMigration::Migrator
    attr_reader :seen

    private

    def model_key = "Probe"

    def sync_filter = [:book_ids, "book_id"]

    def upsert_row(attrs) = (@seen ||= []) << attrs["id"]
  end

  class BulkProbe < Services::BooksMigration::BulkUpsertMigrator
    attr_reader :seen

    private

    def model_key = "BulkProbe"

    def sync_filter = [:author_ids, "id"]

    def build_rows(attrs) = ((@seen ||= []) << attrs["id"]) && []
  end

  ROWS = [{"id" => 1, "book_id" => 10}, {"id" => 2, "book_id" => 20}]

  def run_probe(klass, sync)
    migrator = klass.new(sync: sync)
    migrator.stubs(:legacy_each).multiple_yields(*ROWS.zip)
    [migrator.call, migrator.seen]
  end

  test "without a sync scope every legacy row is processed" do
    result, seen = run_probe(Probe, nil)

    assert result[:success], result[:error]
    assert_equal [1, 2], seen
    assert_equal 2, result[:data][:count]
  end

  test "with a sync scope only the run's rows are processed and counted" do
    result, seen = run_probe(Probe, sync_scope(book_ids: [20]))

    assert_equal [2], seen
    assert_equal 1, result[:data][:count]
  end

  test "bulk migrators filter the same way" do
    _result, seen = run_probe(BulkProbe, sync_scope(author_ids: [1]))

    assert_equal [1], seen
  end

  test "call passes the scope through" do
    scope = sync_scope(book_ids: [20])
    Probe.any_instance.stubs(:legacy_each).multiple_yields(*ROWS.zip)

    assert_equal 1, Probe.call(sync: scope)[:data][:count]
  end
end
