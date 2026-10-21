# frozen_string_literal: true

# The VIAF step of the author workflow (spec section 6.1): the line logic of
# the old Books::Authors::ViafJob, unchanged.
#
# The chain never waits on VIAF. VIAF allows two requests a minute and about a
# thousand a day, so a step that must wait takes turns from Viaf::Schedule's
# line: a step not yet in the line joins it whenever anyone is waiting, a pause
# (Viaf::Exceptions::Paused: a Cloudflare block, a 429, the day's budget running
# low) sends a step to the back, and a busy pace on a step's own turn (in_line)
# only delays that turn, since one author can need more requests than a minute
# allows. In-line is remembered on the step's own result.
#
# When VIAF is paused, or a step's turn is more than CHAIN_PATIENCE away, the
# wait outcome releases the step: the AI step proceeds now, and VIAF's facts
# land as fills when its turn comes. A run answerable from a stored cluster
# skips the line entirely, rather than waiting behind runs that must ask VIAF.
module Workflows
  module Books
    module Steps
      class Viaf
        RESCHEDULE_JITTER = 0..30

        # The longest the AI step waits for VIAF. A turn further off than this
        # releases the step now, as a pause does.
        CHAIN_PATIENCE = 600

        def call(step:, run:, target:)
          refresh = run.options.fetch("refresh", false)
          in_line = step.result["in_line"] == true

          # A step not yet in the line waits behind anyone already in it, rather
          # than competing with them for VIAF's two requests a minute.
          return take_turn(not_before: 0) if !in_line && schedule.horizon && !answerable_from_store?(target, refresh)

          result = ::Services::Books::Authors::EnrichFromViaf.call(author: target, refresh: refresh)
          Workflows::Outcome.succeeded(result.data[:outcome].to_s, {
            "wikidata_qid" => result.data[:wikidata_qid],
            "needs_review" => result.data[:decision]&.needs_review || false,
            "in_line" => in_line
          })
        rescue ::Viaf::Exceptions::RateLimited => e
          paused = e.is_a?(::Viaf::Exceptions::Paused)
          if in_line && !paused
            # The step's own turn, and the pace is busy: the turn goes on
            # shortly, resuming from the suggestions and clusters already
            # stored, rather than going to the back of the line.
            Workflows::Outcome.wait(Time.current + e.retry_after.to_i + rand(RESCHEDULE_JITTER), result: {"in_line" => true})
          else
            take_turn(not_before: e.retry_after, paused: paused)
          end
        end

        private

        # Not memoized: the adapter is one object shared by every run.
        def schedule = ::Viaf::Schedule.new

        # A run VIAF need not be asked for skips the line: the author holds, or
        # an earlier era's decision will put back (RestoreIdentifier), a VIAF id
        # whose cluster is already stored, so the held-id stage reads it without
        # a request. After a re-migration most VIAF-bound authors are these. A
        # forced run refetches, so it waits its turn. If the stored cluster does
        # not settle it and the run must search, a busy pace sends it to the
        # line then.
        def answerable_from_store?(author, refresh)
          return false if refresh

          ids = author.identifiers.where(identifier_type: :books_author_viaf).pluck(:value)
          ids << ::Services::Books::Authors::RestoreIdentifier.value_for(author: author, finder: ::Services::Books::Authors::ResolveViaf)
          ::ExternalRecord.where(source: :viaf, source_id: ids.compact, schema_version: ::Viaf::Distiller::SCHEMA_VERSION).exists?
        end

        # Takes the next start in the line and waits for it. The step is released
        # when VIAF is paused or the start is more than CHAIN_PATIENCE away.
        def take_turn(not_before:, paused: false)
          wait = schedule.reserve(not_before: not_before)
          Workflows::Outcome.wait(Time.current + wait + rand(RESCHEDULE_JITTER),
            release: paused || wait > CHAIN_PATIENCE, result: {"in_line" => true})
        end
      end
    end
  end
end
