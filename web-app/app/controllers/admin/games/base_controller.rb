class Admin::Games::BaseController < Admin::BaseController
  include Admin::DomainScopedAuth

  layout "games/admin"
end
