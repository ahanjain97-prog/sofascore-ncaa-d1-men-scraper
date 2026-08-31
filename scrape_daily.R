#!/usr/bin/env Rscript

# Simple boss-facing entry point: scrape one local calendar day of completed
# NCAA Division I men's matches and update the cumulative data/ tables.

full_args <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", full_args, value = TRUE)
daily_directory <- if (length(file_arg)) {
  dirname(normalizePath(sub("^--file=", "", file_arg[[1L]]), mustWork = TRUE))
} else {
  normalizePath(getwd(), mustWork = TRUE)
}

source(file.path(daily_directory, "sofascore_college_scraper.R"))

print_daily_help <- function() {
  cat(paste0(
    "Scrape completed NCAA Division I men's matches for one day.\n\n",
    "Usage:\n",
    "  Rscript scrape_daily.R              # yesterday (recommended)\n",
    "  Rscript scrape_daily.R today        # today so far\n",
    "  Rscript scrape_daily.R yesterday\n",
    "  Rscript scrape_daily.R 2026-08-31   # exact America/Chicago date\n\n",
    "Results are added to data/tables/; already cached matches are reused.\n"
  ))
}

run_daily <- function(args = commandArgs(trailingOnly = TRUE)) {
  if (length(args) && args[[1L]] %in% c("--help", "-h", "help")) {
    print_daily_help()
    return(invisible(0L))
  }
  if (length(args) > 1L) {
    stop("Expected at most one value: today, yesterday, or YYYY-MM-DD", call. = FALSE)
  }

  timezone <- "America/Chicago"
  today <- date_in_timezone(timezone)
  requested <- if (length(args)) tolower(args[[1L]]) else "yesterday"
  target_date <- if (requested == "today") {
    today
  } else if (requested == "yesterday") {
    today - 1L
  } else {
    suppressWarnings(as.Date(requested, format = "%Y-%m-%d"))
  }

  if (is.na(target_date) || !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", as.character(target_date))) {
    stop("Date must be today, yesterday, or YYYY-MM-DD", call. = FALSE)
  }
  if (target_date > today) stop("The requested date is in the future", call. = FALSE)

  message(sprintf(
    "Scraping completed NCAA Division I men's matches for %s (%s).",
    target_date, timezone
  ))
  if (target_date == today) {
    message("Today's matches that have not finished yet will be picked up by a later rerun.")
  }

  main(c(
    "--start-date", as.character(target_date),
    "--end-date", as.character(target_date),
    "--gender", "men",
    "--division", "1",
    "--output", file.path(daily_directory, "data")
  ))
}

if (sys.nframe() == 0L) {
  tryCatch(
    run_daily(),
    error = function(error) {
      message("ERROR: ", conditionMessage(error))
      quit(status = 1L, save = "no")
    }
  )
}
