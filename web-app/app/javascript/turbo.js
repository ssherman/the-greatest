// Turbo core, WITHOUT @hotwired/turbo-rails.
//
// turbo-rails' entry also imports cable_stream_source_element and cable, which
// pulls ActionCable into every bundle for ~3.5 KB gzipped. This app broadcasts
// nothing over a cable: no view calls Turbo's stream-from helper, no model uses
// a broadcast helper, and there is no app/channels. <turbo-cable-stream-source>
// is the only thing that ever opens a cable connection, and it only enters the
// DOM via that helper. test/lint/turbo_cable_test.rb enforces the precondition
// -- it scans this file too, as raw text including comments, so name those
// helpers rather than spelling them.
//
// Turbo Frames are plain fetch and never involve ActionCable. Turbo Stream
// RESPONSES over HTTP (text/vnd.turbo-stream.html) are core Turbo and are
// likewise unaffected -- several controllers rely on them.
//
// encodeMethodIntoRequestBody is the one Rails-specific piece turbo-rails adds
// that this app genuinely needs: it encodes _method into non-GET form bodies,
// without which `form_with method: :patch` and `button_to method: :delete`
// silently submit as POST. This is a DEEP IMPORT into turbo-rails' internals --
// RE-CHECK THIS PATH ON EVERY turbo-rails UPGRADE. If it moves, the import
// throws at build time rather than failing silently, which is the safe direction.
import * as Turbo from "@hotwired/turbo"
import { encodeMethodIntoRequestBody } from "@hotwired/turbo-rails/app/javascript/turbo/fetch_requests"

window.Turbo = Turbo
addEventListener("turbo:before-fetch-request", encodeMethodIntoRequestBody)
