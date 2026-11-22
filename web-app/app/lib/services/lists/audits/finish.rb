module Services
  module Lists
    module Audits
      class Finish
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

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
          end
          errors
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
