# frozen_string_literal: true

# The full penalty reference, grouped into the five reader-facing categories.
#
# Each group renders an intro paragraph explaining what the category actually
# measures, then its rows -- name, description, reduction -- inside a
# <details>, collapsed because the complete set runs to roughly fifty rows and
# would otherwise dominate the page.
class Rankings::PenaltyTableComponent < ViewComponent::Base
  # Public copy, reviewed and exact. Keyed by Penalty#category (the enum
  # reads back as a String); nil is the uncategorized "Other" fallback that
  # exists so a mis-tagged penalty is visibly odd rather than silently gone.
  INTROS = {
    "voter_expertise" => "Who chose the entries matters more than almost anything else. A ranking judged by critics, authors and scholars is different evidence from a public poll, and a panel drawn from one country or one background tells you about that group rather than about readers generally. The largest single reduction we apply anywhere is for a list voted on entirely by non-experts.",
    "voter_participation" => "A poll of five people is far easier to skew than a poll of five hundred. Where a list publishes its turnout we compare it against the typical list in our collection and reduce weight as it falls below that. Where a list does not say how many people voted at all, we assume the worst, because a list confident in its turnout usually publishes it.",
    "list_time_scope" => "A list covering only the 2010s cannot tell you what the greatest of all time is; it was never asking. The narrower a list's window, the less its verdict generalises, so a single-year award is reduced far more than a list spanning a century.",
    "list_subject_scope" => "The same logic applies to subject. A list restricted to a single country, language, genre or gender is answering a narrower question than \"what is the greatest\". We do not discard these lists. They are often the most careful ones we have, and they are where work from outside the usual centres gets its due. But first place among fifty is a smaller achievement than first place among all of them.",
    "list_integrity" => "Some lists are not really rankings. They are inventories of five hundred titles, or sequels collecting what an earlier list left out, or affiliate pages built by someone who sells what they recommend. Others are simply undocumented, and we cannot establish who made them or how. These adjustments concern how a list came to exist rather than what it covers."
  }.freeze

  OTHER_INTRO = "Adjustments that have not yet been sorted into a category."

  def initialize(groups:, configurations:)
    @groups = groups
    @configurations = configurations
  end

  def render? = @groups.any?

  private

  attr_reader :groups, :configurations

  def intro(group)
    INTROS.fetch(group.category, OTHER_INTRO)
  end

  # With one configuration the reduction column is generic ("Reduction"),
  # matching the page as it has always looked. With several -- music passes
  # albums and songs, which genuinely differ -- each gets its own column so a
  # value is never shown under the wrong media's heading.
  def multi_configuration? = configurations.size > 1

  def value_column_heading(configuration)
    multi_configuration? ? configuration.media_noun_plural.capitalize : "Reduction"
  end
end
