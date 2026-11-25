# frozen_string_literal: true

# The owner's strip above a list's items: one alert per submission, in its own
# Turbo Frame. A request is called by its title or by where it came from, with a
# short reference built from its parsed ids: the pasted text is never shown.
# Titles came from the reader or from a lookup of their input, so they are
# printed escaped and never put in an href. The state attributes sit on a child
# of the frame because a frame reload copies only the frame's children.
#
# No alert has a role: the element around the frame is the one live region, and
# nested ones would announce a change twice.
class Books::BookSubmissions::StripComponent < ViewComponent::Base
  # Whole class names, so Tailwind's scan finds them.
  ALERTS = {working: "alert-info", done: "alert-success", problem: "alert-warning"}.freeze
  ICONS = {
    done: '<circle cx="12" cy="12" r="10"></circle><path d="m9 12 2 2 4-4"></path>',
    problem: '<path d="m21.7 18-8-14a2 2 0 0 0-3.4 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.7-3"></path><path d="M12 9v4"></path><path d="M12 17h.01"></path>',
    stalled: '<circle cx="12" cy="12" r="10"></circle><path d="M12 6v6l4 2"></path>'
  }.freeze

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

  def viewable_book(submission)
    submission.book if submission.added? && !submission.review_rejected?
  end

  def state(submission)
    return :problem if submission.review_rejected?
    return :working if submission.in_progress?

    submission.added? ? :done : :problem
  end

  def icon(name, css = nil)
    tag.svg(ICONS.fetch(name).html_safe,
      xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 24 24", fill: "none", stroke: "currentColor",
      "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true",
      class: ["size-6 shrink-0", css])
  end

  def title(submission) = submission.resolved_title.presence || submission.typed_title.presence

  def name(submission)
    return %("#{title(submission)}") if title(submission)

    case submission.input_method
    when "goodreads" then "a book from Goodreads"
    when "amazon" then "a book from Amazon"
    else "a book by ISBN"
    end
  end

  def reference(submission)
    case submission.input_method
    when "goodreads" then "Goodreads book #{submission.goodreads_book_id}"
    when "amazon" then "Amazon item #{submission.asin}"
    when "isbn" then "ISBN #{submission.isbn13.presence || submission.isbn10}"
    end
  end

  def message(submission)
    name = name(submission)
    return "We couldn't verify #{name}, so it was removed." if submission.review_rejected?

    case submission.status
    when "queued", "looking_up" then "Adding #{name}"
    when "needs_details" then not_found_message(submission)
    when "added" then submission.created_book? ? "Added #{name}" : "Already on the site: added #{name}"
    else "Could not add #{name}"
    end
  end

  def not_found_message(submission)
    if submission.method_isbn?
      "We couldn't find a book with that ISBN."
    elsif submission.method_title_authors?
      "We couldn't find that book."
    else
      "We couldn't find a book from that link."
    end
  end

  # What tells two requests apart when the message holds no title. The not-found
  # sentence names no book at all, so there the title counts too.
  def request_label(submission)
    return title(submission) || reference(submission) if submission.needs_details? && !submission.review_rejected?

    reference(submission) unless title(submission)
  end
end
