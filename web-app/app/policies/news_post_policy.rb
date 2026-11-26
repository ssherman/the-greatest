# frozen_string_literal: true

# Permission follows the post's own site, so an editor of one site's news cannot
# touch another's. Same rules as the Books:: policies: global admin/editor, or a
# domain role that can write.
class NewsPostPolicy < ApplicationPolicy
  def domain
    record.domain
  end
end
