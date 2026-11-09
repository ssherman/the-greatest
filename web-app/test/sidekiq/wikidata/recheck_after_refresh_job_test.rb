# frozen_string_literal: true

require "test_helper"

class Wikidata::RecheckAfterRefreshJobTest < ActiveSupport::TestCase
  setup do
    @config = Rails.application.config.x.wikidata
    @original = @config.recheck_after_refresh
    @cache = ActiveSupport::Cache::MemoryStore.new
    @original_cache = Rails.application.config.x.external_api_cache
    Rails.application.config.x.external_api_cache = @cache
  end

  teardown do
    @config.recheck_after_refresh = @original
    Rails.application.config.x.external_api_cache = @original_cache
  end

  def stub_version(date)
    ::Wikidata::Service.any_instance.stubs(:get).with("/version").returns({"dump_date" => date})
  end

  test "does nothing with the flag off" do
    ::Wikidata::Service.any_instance.expects(:get).never
    ::Services::Wikidata::Recheck.expects(:call).never

    Wikidata::RecheckAfterRefreshJob.new.perform
  end

  test "with the flag on, the same dump date seen twice runs the re-check once" do
    @config.recheck_after_refresh = true
    stub_version("2026-11-01")
    ::Services::Wikidata::Recheck.expects(:call).with(dump_date: "2026-11-01", apply: true).once

    2.times { Wikidata::RecheckAfterRefreshJob.new.perform }
  end

  test "a newer dump date runs it again" do
    @config.recheck_after_refresh = true
    ::Services::Wikidata::Recheck.expects(:call).twice
    stub_version("2026-11-01")
    Wikidata::RecheckAfterRefreshJob.new.perform
    stub_version("2026-11-08")
    Wikidata::RecheckAfterRefreshJob.new.perform
  end

  test "an unavailable service raises and stores no dump date" do
    @config.recheck_after_refresh = true
    ::Wikidata::Service.any_instance.stubs(:get).raises(::Wikidata::Exceptions::Unavailable.new("down", retry_after: 60))

    assert_raises(::Wikidata::Exceptions::Unavailable) { Wikidata::RecheckAfterRefreshJob.new.perform }
    assert_nil @cache.read(Wikidata::RecheckAfterRefreshJob::CACHE_KEY)
  end
end
