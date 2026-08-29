# Contact form

A modal contact form opened from the footer link on books, music and games.
Replaces the `mailto:` that shipped with the footer.

## Flow

1. `FooterComponent` renders a `<dialog id="contact_modal">` containing
   `contact_messages/_form`. The markup is identical for every visitor, because
   the footer appears on every Cloudflare-cached page.
2. The `contact--form` Stimulus controller opens the dialog and fetches
   `GET /contact_state` (uncached; no query beyond `current_user` loading the
   session's own user), which returns the signed-in visitor's email and a
   CSRF token for their own session.
3. `POST /contact_messages` persists a `ContactMessage`, enqueues
   `AdminMailer#contact_message`, and answers with a turbo-stream that swaps
   `#contact_modal_body` to a confirmation.

## Why it works this way

- **The form cannot be prefilled server-side.** The footer is on every
  edge-cached page, so rendering one visitor's email would serve it to
  everyone. `test/components/footer_component_test.rb` asserts the footer's
  HTML is identical signed in and signed out.
- **The posted email is ignored for a signed-in visitor.** The server reads
  `current_user.email`. The prefill is a convenience, not evidence.
- **The email is required for anonymous submitters**, unlike the legacy site,
  which accepted blank addresses and produced messages nobody could answer.
- **Every response is a turbo-stream**, including failures. A bare
  `head :unprocessable_entity` blanks the page, and public layouts render no
  flash.

## Spam controls

A honeypot field (`website`) and two rate-limit buckets: 5/hour for anonymous
submitters keyed on `visitor_ip`, 20/hour for signed-in ones keyed on user id.
Both numbers are guesses — legacy stored no contact messages, so there was no
history to set them from. Adjust in `ContactMessagesController`.

## Mail

`AdminMailer#contact_message` sends to `SiteContact::ADDRESS` with the
submitter as `Reply-To`, branded per domain via `MailBranding`. The subject
carries the site name and the first 60 characters of the message.

## Admin

Split per site, like corrections: `Admin::ContactMessagesController` scoped to
`current_domain`, reachable from the Contact entry in `Admin::DomainNav`.
