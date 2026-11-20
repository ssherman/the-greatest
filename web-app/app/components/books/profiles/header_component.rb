# frozen_string_literal: true

class Books::Profiles::HeaderComponent < ViewComponent::Base
  def initialize(header:, audience:)
    @header = header
    @audience = audience
  end

  private

  attr_reader :header, :audience

  def owner? = audience == :owner

  def name = header.name.presence

  # Never anything derived from the email address: no name means a generic
  # heading and a generic icon.
  def heading
    name || (owner? ? "Your profile" : "Reader profile")
  end

  def initial
    name&.strip&.first&.upcase
  end
end
