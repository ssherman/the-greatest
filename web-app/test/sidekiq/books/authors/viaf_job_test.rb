# frozen_string_literal: true

require "test_helper"

class Books::Authors::ViafJobTest < ActiveSupport::TestCase
  def setup
    @author = books_authors(:tolstoy)
    # Sidekiq runs inline in tests: a real enqueue would run the next step.
    Books::Authors::EnrichJob.stubs(:perform_async)
    Books::Authors::WikidataJob.stubs(:perform_async)

    # CI has no Redis: every job reserves its start time in a fake. The
    # clock is frozen so a second passing mid-reservation cannot shift a wait.
    freeze_time
    @schedule = Viaf::Schedule.new(redis: Books::OpenLibrary::FakeRedis.new)
    Viaf::Schedule.stubs(:new).returns(@schedule)
  end

  def outcome(wikidata_qid: nil, needs_review: false)
    decision = stub(needs_review: needs_review)
    ::Services::Books::Authors::EnrichFromViaf::Result.new(success?: true,
      data: {outcome: :matched, wikidata_qid: wikidata_qid, decision: decision}, errors: [])
  end

  def job_with_jitter(seconds)
    Books::Authors::ViafJob.new.tap { |job| job.stubs(:rand).returns(seconds) }
  end

  test "runs on the author_chain queue with three retries" do
    options = Books::Authors::ViafJob.get_sidekiq_options

    assert_equal ["author_chain", 3], [options["queue"].to_s, options["retry"]]
  end

  test "runs the VIAF step, passing refresh through, then the AI step" do
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).with(author: @author, refresh: true).returns(outcome)
    Books::Authors::WikidataJob.expects(:perform_async).never
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id, true)

    Books::Authors::ViafJob.new.perform(@author.id, true)
  end

  test "a newly found Wikidata id sends the author back to Wikidata once, forced, and the AI step waits for that run" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome(wikidata_qid: "Q7243"))
    Books::Authors::WikidataJob.expects(:perform_async).with(@author.id, true, true, true)
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::ViafJob.new.perform(@author.id)
  end

  test "a Wikidata id from a decision that needs review goes straight to the AI step" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome(wikidata_qid: "Q7243", needs_review: true))
    Books::Authors::WikidataJob.expects(:perform_async).never
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id, true)

    Books::Authors::ViafJob.new.perform(@author.id)
  end

  test "research off reaches the AI step and the forced Wikidata hop" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome)
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id, false)
    Books::Authors::ViafJob.new.perform(@author.id, false, false, false)

    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome(wikidata_qid: "Q7243"))
    Books::Authors::WikidataJob.expects(:perform_async).with(@author.id, true, true, false)
    Books::Authors::ViafJob.new.perform(@author.id, false, false, false)
  end

  test "does nothing for an author deleted since enqueue" do
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).never
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::ViafJob.new.perform(0)
  end

  test "a VIAF pause queues the AI step at once and reschedules itself, remembering that it did" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::Paused.new("paused", retry_after: 3600))
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id, true).once
    Books::Authors::ViafJob.expects(:perform_in).with(3607, @author.id, false, true, true, true)

    job_with_jitter(7).perform(@author.id)
  end

  test "a pause on a rescheduled run does not queue the AI step again" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::Paused.new("paused", retry_after: 3600))
    Books::Authors::EnrichJob.expects(:perform_async).never
    Books::Authors::ViafJob.expects(:perform_in).with(3607, @author.id, false, true, true, true)

    job_with_jitter(7).perform(@author.id, false, true)
  end

  test "a busy pace only reschedules, keeping refresh and what was already queued" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::RateLimited.new("VIAF pace busy", retry_after: 30))
    Books::Authors::EnrichJob.expects(:perform_async).never
    Books::Authors::ViafJob.expects(:perform_in).with(37, @author.id, true, false, true, true)

    job_with_jitter(7).perform(@author.id, true)
  end

  test "a rescheduled run that finishes does not queue the AI step a second time" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome)
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::ViafJob.new.perform(@author.id, false, true)
  end

  test "a rescheduled run that finds a Wikidata id still sends the author back to Wikidata" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome(wikidata_qid: "Q7243"))
    Books::Authors::WikidataJob.expects(:perform_async).with(@author.id, true, true, true)

    Books::Authors::ViafJob.new.perform(@author.id, false, true)
  end

  test "a busy pace after a pause keeps enrich_queued" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::RateLimited.new("VIAF pace busy", retry_after: 30))
    Books::Authors::EnrichJob.expects(:perform_async).never
    Books::Authors::ViafJob.expects(:perform_in).with(37, @author.id, false, true, true, true)

    job_with_jitter(7).perform(@author.id, false, true)
  end

  test "a pause keeps refresh" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::Paused.new("paused", retry_after: 3600))
    Books::Authors::ViafJob.expects(:perform_in).with(3607, @author.id, true, true, true, true)

    job_with_jitter(7).perform(@author.id, true)
  end

  test "a job behind a waiting line joins it without asking VIAF, and a far turn queues the AI step now" do
    8.times { @schedule.reserve(not_before: 30) }
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).never
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id, false).once
    Books::Authors::ViafJob.expects(:perform_in).with(30 + (8 * 300) + 7, @author.id, false, true, false, true)

    job_with_jitter(7).perform(@author.id, false, false, false)
  end

  test "a job behind a short line waits its turn without queuing the AI step" do
    @schedule.reserve(not_before: 30)
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).never
    Books::Authors::EnrichJob.expects(:perform_async).never
    Books::Authors::ViafJob.expects(:perform_in).with(30 + 300 + 7, @author.id, false, false, true, true)

    job_with_jitter(7).perform(@author.id)
  end

  test "a job behind a waiting line whose author holds a VIAF id with a stored cluster runs now" do
    @schedule.reserve(not_before: 30)
    @author.identifiers.create!(identifier_type: :books_author_viaf, value: "5391")
    ExternalRecord.create!(source: :viaf, source_id: "5391", payload: {"viaf_id" => "5391", "name_type" => "Personal"},
      schema_version: Viaf::Distiller::SCHEMA_VERSION, fetched_at: Time.current)
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).with(author: @author, refresh: false).returns(outcome)
    Books::Authors::ViafJob.expects(:perform_in).never

    Books::Authors::ViafJob.new.perform(@author.id)
  end

  test "a job behind a waiting line whose earlier-era decision will put back a VIAF id with a stored cluster runs now" do
    @schedule.reserve(not_before: 30)
    ::MatchDecision.create!(finder: ::Services::Books::Authors::ResolveViaf.name, subject: @author, outcome: :matched, confidence: :high,
      decided_by: :ai, candidates: [{"external_key" => "5391"}], selected_index: 1, created_at: @author.created_at - 1.day)
    ExternalRecord.create!(source: :viaf, source_id: "5391", payload: {"viaf_id" => "5391", "name_type" => "Personal"},
      schema_version: Viaf::Distiller::SCHEMA_VERSION, fetched_at: Time.current)
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).with(author: @author, refresh: false).returns(outcome)
    Books::Authors::ViafJob.expects(:perform_in).never

    Books::Authors::ViafJob.new.perform(@author.id)
  end

  test "a forced run with a stored cluster still waits its turn" do
    @schedule.reserve(not_before: 30)
    @author.identifiers.create!(identifier_type: :books_author_viaf, value: "5391")
    ExternalRecord.create!(source: :viaf, source_id: "5391", payload: {"viaf_id" => "5391", "name_type" => "Personal"},
      schema_version: Viaf::Distiller::SCHEMA_VERSION, fetched_at: Time.current)
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).never
    Books::Authors::EnrichJob.expects(:perform_async).never
    Books::Authors::ViafJob.expects(:perform_in).with(30 + 300 + 7, @author.id, true, false, true, true)

    job_with_jitter(7).perform(@author.id, true)
  end

  test "a held id with no stored cluster waits its turn" do
    @schedule.reserve(not_before: 30)
    @author.identifiers.create!(identifier_type: :books_author_viaf, value: "9999")
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).never
    Books::Authors::EnrichJob.expects(:perform_async).never
    Books::Authors::ViafJob.expects(:perform_in).with(30 + 300 + 7, @author.id, false, false, true, true)

    job_with_jitter(7).perform(@author.id)
  end

  test "a busy pace on the job's own turn delays the turn and keeps its place in the line" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::RateLimited.new("VIAF pace busy", retry_after: 30))
    Books::Authors::EnrichJob.expects(:perform_async).never
    Books::Authors::ViafJob.expects(:perform_in).with(37, @author.id, true, false, true, true)

    job_with_jitter(7).perform(@author.id, true, false, true, true)

    assert_nil @schedule.horizon
  end

  test "a pause on the job's own turn sends it to the back of the line and queues the AI step now" do
    2.times { @schedule.reserve(not_before: 30) }
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::Paused.new("paused", retry_after: 3600))
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id, true).once
    Books::Authors::ViafJob.expects(:perform_in).with(3607, @author.id, false, true, true, true)

    job_with_jitter(7).perform(@author.id, false, false, true, true)
  end

  test "a far turn does not queue the AI step again once it was queued" do
    8.times { @schedule.reserve(not_before: 30) }
    Books::Authors::EnrichJob.expects(:perform_async).never
    Books::Authors::ViafJob.expects(:perform_in).with(30 + (8 * 300) + 7, @author.id, false, true, true, true)

    job_with_jitter(7).perform(@author.id, false, true)
  end
end
