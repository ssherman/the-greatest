# frozen_string_literal: true

class Books::ProvisionalNoticeComponent < ViewComponent::Base
  def initialize(record:)
    @record = record
  end

  def render?
    @record.provisional?
  end
end
