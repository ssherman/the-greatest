# Service-account provisioning for the public API. Each task prints the new
# secret and NOTHING else to stdout, so `bin/rails api:service_account:create … | sops …`
# works; errors go to stderr via abort.
namespace :api do
  def api_env!(name)
    ENV[name].presence || abort("#{name} is required")
  end

  def api_scopes
    api_env!("SCOPES").split(",").map(&:strip).reject(&:blank?)
  end

  def api_print!(result)
    abort result.errors.join("; ") unless result.success?
    puts result.data[:secret]
  end

  namespace :service_account do
    desc "Create a service account (NAME=lowercase-kebab SCOPES=books:read,music:read [TOKEN_NAME=default]) and print its first token"
    task create: :environment do
      api_print! Services::Api::ServiceAccounts.create(
        name: api_env!("NAME"), scopes: api_scopes, token_name: ENV.fetch("TOKEN_NAME", "default")
      )
    end

    desc "Mint another token for an existing service account (NAME= TOKEN_NAME= SCOPES=) and print it"
    task token: :environment do
      api_print! Services::Api::ServiceAccounts.mint(
        name: api_env!("NAME"), token_name: api_env!("TOKEN_NAME"), scopes: api_scopes
      )
    end
  end

  namespace :token do
    desc "Revoke (destroy) an API token by id (ID=)"
    task revoke: :environment do
      result = Services::Api::ServiceAccounts.revoke(id: api_env!("ID"))
      abort result.errors.join("; ") unless result.success?
    end
  end
end
