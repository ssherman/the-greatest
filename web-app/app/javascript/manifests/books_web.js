import { application } from "../controllers/application"
import "./web_shared"

import Books__CategorySearchController from "../controllers/books/category_search_controller"
application.register("books--category-search", Books__CategorySearchController)

import Books__DropdownCloseController from "../controllers/books/dropdown_close_controller"
application.register("books--dropdown-close", Books__DropdownCloseController)

import Books__FilterController from "../controllers/books/filter_controller"
application.register("books--filter", Books__FilterController)

import Books__NavDrawerController from "../controllers/books/nav_drawer_controller"
application.register("books--nav-drawer", Books__NavDrawerController)

import Books__ReadingGoalStateController from "../controllers/books/reading_goal_state_controller"
application.register("books--reading-goal-state", Books__ReadingGoalStateController)
