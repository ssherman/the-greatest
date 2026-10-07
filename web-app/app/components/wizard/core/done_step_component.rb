# frozen_string_literal: true

class Wizard::Core::DoneStepComponent < ViewComponent::Base
  LABELS = {
    "matched" => "Matched", "created" => "Created", "admin_linked" => "Linked by an admin",
    "unlinked" => "Left unlinked", "changed_since_match" => "Changed since match", "duplicate_pairs" => "New duplicate pairs raised"
  }.freeze

  def initialize(list:, adapter:)
    @list = list
    @adapter = adapter
  end

  def counts = @counts ||= ::Services::Lists::Wizard::Core::Summary.new(@list).done_counts

  def list_path = @adapter.list_path(@list)
end
