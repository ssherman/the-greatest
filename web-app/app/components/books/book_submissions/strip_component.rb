# frozen_string_literal: true

# The owner's strip above a list's items: one line per submission, in its own
# Turbo Frame. Every string here came from the reader or from a lookup of
# their input, so it is printed escaped and never put in an href. Task 9
# finishes the markup and the polling. The state attributes sit on a child of
# the frame because a frame reload copies only the frame's children.
class Books::BookSubmissions::StripComponent < ViewComponent::Base
  def initialize(list:, submissions:, reload_list: false, in_progress: false)
    @list = list
    @submissions = submissions
    @reload_list = reload_list
    @in_progress = in_progress
  end

  private

  attr_reader :list, :submissions

  def frame_data
    data = {poll_url: books_my_list_book_submissions_path(list)}
    data[:in_progress] = "true" if @in_progress || submissions.any?(&:in_progress?)
    data[:reload_list] = "true" if @reload_list
    data
  end

  # Cancel is only for a request that has made no book yet: the server
  # refuses it once there is one, so the button is not offered then.
  def cancellable?(submission) = submission.book_id.nil? && ::Books::BookSubmission::OPEN_STATUSES.include?(submission.status)

  def finished?(submission) = ::Books::BookSubmission::OPEN_STATUSES.exclude?(submission.status)

  def retryable?(submission) = %w[needs_details failed].include?(submission.status) && !submission.review_rejected?

  def message(submission)
    label = submission.label
    return "We couldn't verify #{label}, so it was removed." if submission.review_rejected?

    case submission.status
    when "queued", "looking_up" then "Adding: #{label}"
    when "needs_details" then not_found_message(submission)
    when "added" then submission.created_book? ? "Added #{label}" : "Already on the site: added #{label}"
    when "failed" then "Could not add #{label}"
    else label.to_s
    end
  end

  def not_found_message(submission)
    if submission.method_isbn?
      "We couldn't find a book with that ISBN. Try another way"
    elsif submission.method_title_authors?
      "We couldn't find that book. Try another way"
    else
      "We couldn't find a book from that link. Try another way"
    end
  end

  # The not-found sentence names no book, so two such rows would read the same:
  # the row also shows what the reader asked for. Every other row's message has it.
  def request_label(submission)
    submission.label if submission.needs_details?
  end
end
