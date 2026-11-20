# frozen_string_literal: true

class Books::Profiles::HeaderComponent < ViewComponent::Base
  # profile is passed only on the owner's own page, where the header shows
  # whether the profile is public and links to its settings.
  def initialize(header:, audience:, profile: nil)
    @header = header
    @audience = audience
    @profile = profile
  end

  private

  attr_reader :header, :audience, :profile

  def owner? = audience == :owner

  def status_controls? = owner? && !profile.nil?

  def status = profile.public? ? "Public" : "Private"

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
