# frozen_string_literal: true

class Books::AuthorAvatarComponent < ViewComponent::Base
  def initialize(author:, size_classes: "w-full aspect-square")
    @author = author
    @size_classes = size_classes
  end

  private

  attr_reader :author, :size_classes

  def image
    @image ||= author.primary_image if author.primary_image&.file&.attached?
  end

  def initials
    tokens = author.name.to_s.split(/\s+/).filter_map { |token| token[/[[:alnum:]]/] }
    return "" if tokens.empty?

    chosen = (tokens.size == 1) ? tokens.first(1) : [tokens.first, tokens.last]
    chosen.join.upcase
  end
end
