# frozen_string_literal: true

module Services
  module Api
    # Creates and provisions service accounts -- User rows with
    # account_kind: :service that the Python agent framework authenticates as.
    # The rake tasks in lib/tasks/api.rake are thin wrappers over these three
    # methods; the secret is returned exactly once, in `data[:secret]`.
    class ServiceAccounts
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      # Find-or-create the account by name, then mint one token. Re-running with
      # the same NAME never makes a second account; it does mint another token,
      # which is the point (rotation).
      def self.create(name:, scopes:, token_name: "default")
        unless User::SERVICE_ACCOUNT_NAME_FORMAT.match?(name.to_s)
          return failure("NAME must be lowercase letters, digits and dashes (got #{name.inspect})")
        end

        unknown = scopes.reject { |scope| ::Api::Scopes.known?(scope) }
        return failure("unknown scope(s): #{unknown.join(", ")}") if unknown.any?

        user = User.transaction do
          User.service.find_or_create_by!(email: User.service_account_email(name)) do |account|
            account.display_name = name
            account.name = name
            account.role = :user
            account.account_kind = :service
            account.email_verified = false
          end
        end

        mint_for(user, token_name: token_name, scopes: scopes)
      end

      def self.mint(name:, token_name:, scopes:)
        user = User.service.find_by(email: User.service_account_email(name))
        return failure("no service account named #{name.inspect}") if user.nil?

        mint_for(user, token_name: token_name, scopes: scopes)
      end

      def self.revoke(id:)
        token = ApiToken.find_by(id: id)
        return failure("no token with id #{id.inspect}") if token.nil?

        token.destroy!
        success(token: token)
      end

      def self.mint_for(user, token_name:, scopes:)
        token, secret = ApiToken.generate(user: user, name: token_name, scopes: scopes)
        return failure(*token.errors.full_messages) unless token.persisted?

        success(user: user, token: token, secret: secret)
      end
      private_class_method :mint_for

      def self.success(data) = Result.new(success?: true, data: data, errors: [])

      def self.failure(*messages) = Result.new(success?: false, data: nil, errors: messages)
    end
  end
end
