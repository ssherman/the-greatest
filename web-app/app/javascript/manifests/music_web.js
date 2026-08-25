import { application } from "../controllers/application"
import "./web_shared"

import YearRangeModalController from "../controllers/year_range_modal_controller"
application.register("year-range-modal", YearRangeModalController)
