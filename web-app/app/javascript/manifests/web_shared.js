// Stimulus controllers used by public markup on every domain: the layouts, the
// reviews and user-list surfaces, and root-level components. Domain manifests
// import this and add their own.
//
// This replaces controllers/index.js, which imported all 24 controllers into a
// single bundle and is why nothing tree-shook. Do NOT run
// `bin/rails stimulus:manifest:update` -- it regenerates that file and this app
// no longer uses it. Registrations here are checked against markup by
// test/lint/stimulus_manifest_test.rb.
import { application } from "../controllers/application"

import AuthenticationController from "../controllers/authentication_controller"
application.register("authentication", AuthenticationController)

import AutocompleteController from "../controllers/autocomplete_controller"
application.register("autocomplete", AutocompleteController)

import Contact__FormController from "../controllers/contact/form_controller"
application.register("contact--form", Contact__FormController)

import MembershipStateController from "../controllers/membership_state_controller"
application.register("membership-state", MembershipStateController)

import Reviews__ModalController from "../controllers/reviews/modal_controller"
application.register("reviews--modal", Reviews__ModalController)

import Reviews__MyReviewsController from "../controllers/reviews/my_reviews_controller"
application.register("reviews--my-reviews", Reviews__MyReviewsController)

import Reviews__SpoilerController from "../controllers/reviews/spoiler_controller"
application.register("reviews--spoiler", Reviews__SpoilerController)

import Reviews__WidgetController from "../controllers/reviews/widget_controller"
application.register("reviews--widget", Reviews__WidgetController)

import Shared__FormTokenController from "../controllers/shared/form_token_controller"
application.register("shared--form-token", Shared__FormTokenController)
// Deprecated alias. Public correction form pages are edge-cached for 24 hours and
// their cached HTML still carries data-controller="corrections--form". Without this
// they lose the alternate-titles Add/Remove buttons -- not just token attribution --
// until the cache turns over. DELETE THIS LINE once the edge cache has cycled past
// the deploy that introduced it (>24h).
application.register("corrections--form", Shared__FormTokenController)

import ToastController from "../controllers/toast_controller"
application.register("toast", ToastController)

import UserListAddItemController from "../controllers/user_list_add_item_controller"
application.register("user-list-add-item", UserListAddItemController)

import UserListCompletionController from "../controllers/user_list_completion_controller"
application.register("user-list-completion", UserListCompletionController)

import UserListModalController from "../controllers/user_list_modal_controller"
application.register("user-list-modal", UserListModalController)

import UserListStateController from "../controllers/user_list_state_controller"
application.register("user-list-state", UserListStateController)

import UserListWidgetController from "../controllers/user_list_widget_controller"
application.register("user-list-widget", UserListWidgetController)
