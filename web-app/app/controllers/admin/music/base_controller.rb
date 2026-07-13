class Admin::Music::BaseController < Admin::BaseController
  include Admin::DomainScopedAuth

  layout "music/admin"
end
