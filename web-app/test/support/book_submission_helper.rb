# frozen_string_literal: true

# Builders shared by the book submission processing tests: a submission on a
# books list, the facts ResolveInput hands on, and finder answers.
module BookSubmissionHelper
  FINDER = "DataImporters::Books::Book::Finder"

  def book_submission(user: users(:regular_user), list: user_lists(:regular_user_books_read), **attributes)
    ::Books::BookSubmission.create!({user: user, user_list: list, input_method: :title_authors,
                                     typed_title: "The Quiet Year", typed_author_names: ["Anna Brenner"]}.merge(attributes))
  end

  def resolved_facts(title: "The Quiet Year", author_names: ["Anna Brenner"], identifiers: {}, year: nil, subtitle: nil, source: "title_authors")
    {outcome: :resolved, source: source, title: title, subtitle: subtitle, author_names: author_names, year: year,
     identifiers: {isbn13: [], isbn10: [], asin: [], goodreads_id: []}.merge(identifiers)}
  end

  # A finder answer with its persisted decision. decided_by :fallback is an AI
  # call that failed, which the finder flags for review.
  def finder_match(subject:, record: nil, decided_by: :rule, sources_failed: [], needs_review: nil, candidates: [], confidence: :high)
    needs_review = (decided_by == :fallback) if needs_review.nil?
    outcome = record ? :matched : :unmatched
    decision = ::MatchDecision.create!(finder: FINDER, subject: subject, record: record, outcome: outcome, confidence: confidence,
      decided_by: decided_by, sources_failed: sources_failed, needs_review: needs_review)
    ::DataImporters::Match.new(outcome: outcome, record: record, confidence: confidence, decided_by: decided_by,
      reason: "test", candidates: candidates, decision: decision, sources_failed: sources_failed)
  end

  def stub_finder(match)
    ::DataImporters::Books::Book::Finder.any_instance.stubs(:call).returns(match)
  end
end
