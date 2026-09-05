# The single source of truth for which social providers this app knows about.
#
# Shared rather than duplicated for the same reason config/asset_bundles.json
# is (see test/lint/asset_bundle_coverage_test.rb): the widget, the client, and
# AuthController#check_provider each need this list, and three copies drift.
#
# "enabled" gates the BUTTON only. A disabled provider can still authenticate
# if a token arrives from elsewhere -- the legacy site shares this Firebase
# project, so its Apple and Facebook tokens validate against /auth/sign_in
# today. That is why PROVIDER_MAP in AuthenticationService stays broader than
# the enabled set, and why check_provider reads every entry rather than only
# the enabled ones.
#
# This is NOT the trust boundary. Which providers may link an account by email
# is AuthenticationService::TRUSTED_EMAIL_PROVIDERS, a hardcoded constant --
# deliberately not config, so turning a button on can never widen a security
# decision as a side effect.
module Services
  class AuthProviderRegistry
    CONFIG_PATH = "config/auth_providers.json"

    class << self
      def all
        @all ||= JSON.parse(File.read(Rails.root.join(CONFIG_PATH))).freeze
      end

      def provider_names
        all.keys
      end

      def enabled
        all.select { |_id, entry| entry["enabled"] }
      end

      # Symbol-keyed and ordered, for the widget and the Stimulus value. Kept
      # separate from #enabled so the view is not coupled to the file's string
      # keys.
      def enabled_for_view
        enabled.map do |id, entry|
          {
            id: id,
            firebase_id: entry["firebase_id"],
            label: entry["label"],
            scopes: entry["scopes"]
          }
        end
      end

      # Test seam: the file is memoised because it cannot change at runtime.
      def reset!
        @all = nil
      end
    end
  end
end
