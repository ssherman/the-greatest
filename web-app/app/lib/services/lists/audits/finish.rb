module Services
  module Lists
    module Audits
      class Finish
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        # Our own sites, which show our data back to an agent and often top a
        # search for a list. The apexes cover the legacy sites and every
        # subdomain (new., dev., www.), so this does not follow DOMAIN config.
        OWN_SITE_ROOTS = %w[thegreatestbooks.org thegreatestmusic.org thegreatest.games].freeze
        ARCHIVE_HOSTS = %w[web.archive.org archive.org archive.ph archive.today].freeze

        def self.call(audit:, user:, verdict:, note:, sources:)
          new(audit: audit, user: user, verdict: verdict, note: note, sources: sources).call
        end

        def initialize(audit:, user:, verdict:, note:, sources:)
          @audit = audit
          @user = user
          @verdict = verdict.to_s
          @note = note
          @sources = sources
        end

        def call
          @audit.with_lock do
            unless @audit.in_progress? && @audit.user_id == @user.id
              next failure(["Audit #{@audit.id} is not yours to finish"], conflict: true)
            end

            problems = validation_errors
            next failure(problems) if problems.any?

            after = Snapshot.call(@audit.list)
            @audit.update!(
              verdict: @verdict, note: @note, sources: @sources, after: after,
              field_changes: Diff.call(before: @audit.before, after: after),
              status: :finished, finished_at: Time.current, lease_expires_at: nil
            )
            Result.new(success?: true, data: {audit: @audit}, errors: [])
          end
        end

        private

        def validation_errors
          errors = []
          errors << "verdict must be verified or unverifiable" unless ::ListAudit.verdicts.key?(@verdict)
          errors << "note is required" if @note.to_s.strip.empty?
          if !@sources.is_a?(Array) || !@sources.all? { |s| http_url?(s) }
            errors << "sources must be an array of http(s) URLs"
          elsif @sources.empty? && @verdict == "verified"
            errors << "a verified audit needs at least one source"
          elsif (own = @sources.select { |s| own_site?(s) }).any?
            errors << "sources must not be our own site or a copy of it: #{own.join(", ")}"
          end
          errors
        end

        # A host on one of our domains, or an archive copy whose path is a URL
        # on one of them (web.archive.org/web/<stamp>/https://thegreatestbooks.org/...).
        def own_site?(value)
          uri = URI.parse(value)
          host = uri.host.to_s.downcase
          return true if own_host?(host)
          return false unless ARCHIVE_HOSTS.any? { |archive| host == archive || host.end_with?(".#{archive}") }

          archived = uri.path.to_s[%r{(?:https?:/{1,2})?([^/]+\.[a-z]+)/?}i, 1]
          archived.present? && own_host?(archived.downcase.delete_prefix("www."))
        rescue URI::InvalidURIError
          false
        end

        def own_host?(host)
          OWN_SITE_ROOTS.any? { |root| host == root || host.end_with?(".#{root}") }
        end

        def http_url?(value)
          return false unless value.is_a?(String)
          uri = URI.parse(value)
          uri.is_a?(URI::HTTP) && uri.host.present?
        rescue URI::InvalidURIError
          false
        end

        def failure(errors, conflict: false)
          Result.new(success?: false, data: conflict ? {conflict: true} : {}, errors: errors)
        end
      end
    end
  end
end
