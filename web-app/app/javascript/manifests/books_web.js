import { application } from "../controllers/application"
import "./web_shared"

import Books__FilterController from "../controllers/books/filter_controller"
application.register("books--filter", Books__FilterController)

import Books__NavDrawerController from "../controllers/books/nav_drawer_controller"
application.register("books--nav-drawer", Books__NavDrawerController)

import Books__ReadingGoalStateController from "../controllers/books/reading_goal_state_controller"
application.register("books--reading-goal-state", Books__ReadingGoalStateController)

import ClipboardCopyController from "../controllers/clipboard_copy_controller"
application.register("clipboard-copy", ClipboardCopyController)

import SavedSearchPickerController from "../controllers/saved_search_picker_controller"
application.register("saved-search-picker", SavedSearchPickerController)
