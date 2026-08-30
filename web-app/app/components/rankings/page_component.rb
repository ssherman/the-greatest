# frozen_string_literal: true

# The whole /rankings page for one domain.
#
# Sections run flat down the page rather than behind expanders: this is a
# transparency page, and hiding its substance undercuts the point. Only the full
# penalty tables collapse, because there are roughly fifty rows of them.
class Rankings::PageComponent < ViewComponent::Base
  ALGORITHM_REPO = "https://github.com/ssherman/weighted_list_rank"
  SITE_REPO = "https://github.com/ssherman/the-greatest/"
  DISCORD_URL = "https://discord.com/invite/8JE9fpMtZp"

  def initialize(data:, domain:)
    @data = data
    @domain = domain.to_sym
  end

  private

  attr_reader :data, :domain

  # Books only: percentage_western is implemented for books lists alone, and
  # Global Canon is a books page. Rendering this anywhere else would promise a
  # correction that does not exist.
  def western_section? = domain == :books

  def configuration = data.primary_configuration

  def date_penalty_age = configuration.max_list_dates_penalty_age

  def date_penalty_percentage = configuration.max_list_dates_penalty_percentage

  def date_penalty? = configuration.apply_list_dates_penalty?

  # The floor stated in "How a list earns its weight" -- derived the same way
  # ConfigurationFactsComponent derives it per column, but for the primary
  # configuration alone, since this sentence is talking about the page's one
  # worked example rather than every configuration on the page.
  def weight_floor = configuration.weight_floor

  def automatic_adjustments = data.automatic_adjustments
end
