require "test_helper"

class Books::GoodreadsRebuild::DecideFixesJobTest < ActiveSupport::TestCase
  def build(offset, with_survey: true)
    book = Books::Book.create!(id: Services::Books::GoodreadsRebuild::Cohort.post_import_range.first + 9_000 + offset, title: "B#{offset}")
    if with_survey
      Books::RebuildBookSurvey.create!(book: book, classification: :coherent, groups: [], title_agrees: false, authors_agree: false,
        surveyed_at: Time.current)
    end
    book
  end

  def result(outcome) = Struct.new(:success?, :data, :errors, keyword_init: true).new(success?: true, data: {outcome: outcome}, errors: [])

  test "decides each book and survives one book raising" do
    a, b, c = build(1), build(2), build(3)
    Services::Books::GoodreadsRebuild::DecideFix.stubs(:call).with { |args| args[:book].id == a.id }.returns(result(:fix))
    Services::Books::GoodreadsRebuild::DecideFix.stubs(:call).with { |args| args[:book].id == b.id }.raises(RuntimeError, "boom")
    Services::Books::GoodreadsRebuild::DecideFix.expects(:call).with { |args| args[:book].id == c.id }.returns(result(:retry))
    Rails.logger.stubs(:error)
    Rails.logger.expects(:info).with("decide_fixes batch: 3 books — merge 0, fix 1, kept 0, skipped 0, retry 1, errors 1")

    Books::GoodreadsRebuild::DecideFixesJob.new.perform([a.id, b.id, c.id])
  end

  test "skips books that are gone or have no survey" do
    surveyed = build(4)
    unsurveyed = build(5, with_survey: false)
    Services::Books::GoodreadsRebuild::DecideFix.expects(:call).once.with { |args| args[:book].id == surveyed.id }.returns(result(:merge))
    Rails.logger.stubs(:info)

    Books::GoodreadsRebuild::DecideFixesJob.new.perform([surveyed.id, unsurveyed.id, 999_999_999])
  end
end
