// One admin bundle for all domains: admin lives at /admin on each domain's own
// hostname, and there is no domain-specific admin JavaScript, so per-domain
// admin bundles would be byte-identical. Split this only when that stops being
// true.
import { application } from "../controllers/application"

import Admin__MarkdownPreviewController from "../controllers/admin/markdown_preview_controller"
application.register("admin--markdown-preview", Admin__MarkdownPreviewController)

import Admin__SearchController from "../controllers/admin/search_controller"
application.register("admin--search", Admin__SearchController)

import AuthenticationController from "../controllers/authentication_controller"
application.register("authentication", AuthenticationController)

import AutocompleteController from "../controllers/autocomplete_controller"
application.register("autocomplete", AutocompleteController)

import AutoDismissController from "../controllers/auto_dismiss_controller"
application.register("auto-dismiss", AutoDismissController)

import ClipboardCopyController from "../controllers/clipboard_copy_controller"
application.register("clipboard-copy", ClipboardCopyController)

import ConditionalFieldController from "../controllers/conditional_field_controller"
application.register("conditional-field", ConditionalFieldController)

import MetadataEditorController from "../controllers/metadata_editor_controller"
application.register("metadata-editor", MetadataEditorController)

import ModalFormController from "../controllers/modal_form_controller"
application.register("modal-form", ModalFormController)

import ReviewFilterController from "../controllers/review_filter_controller"
application.register("review-filter", ReviewFilterController)

import Reviews__SpoilerController from "../controllers/reviews/spoiler_controller"
application.register("reviews--spoiler", Reviews__SpoilerController)

import SharedModalController from "../controllers/shared_modal_controller"
application.register("shared-modal", SharedModalController)

import WizardStepController from "../controllers/wizard_step_controller"
application.register("wizard-step", WizardStepController)
