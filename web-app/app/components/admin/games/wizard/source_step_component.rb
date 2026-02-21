# frozen_string_literal: true

# Games source step component.
# Only supports custom_html import (no series import for games).
#
class Admin::Games::Wizard::SourceStepComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  private

  attr_reader :list

  def advance_step_path
    helpers.advance_step_admin_games_list_wizard_path(list_id: list.id, step: "source")
  end

  def default_import_source
    list.wizard_state&.[]("import_source") || "custom_html"
  end

  def default_batch_mode
    list.wizard_state&.dig("batch_mode") || false
  end
end
