#!/usr/bin/env Rscript

# SofaScore NCAA soccer scraper
#
# Default behavior:
#   * on the first run, backfill the current NCAA season (August 1 through today)
#   * on later runs, revisit a short lookback window and add newly completed games
#   * retain the original JSON and rebuild cumulative, analysis-ready CSV tables
#
# SofaScore's web API is undocumented and currently rejects many plain HTTP
# clients. This script first tries a normal request, then falls back to a real
# headless Chrome session via chromote.

SCRIPT_VERSION <- "1.0.2"
PARSER_VERSION <- 1L
SOFASCORE_BASE <- "https://www.sofascore.com"

COLLEGE_COMPETITIONS <- data.frame(
  unique_tournament_id = c(
    15946L, 18944L, 16914L, 18394L,
    28541L, 28543L, 31032L, 31033L,
    36031L, 36033L
  ),
  competition = c(
    "NCAA Division I, Men - Regular Season",
    "NCAA Division I, Women - Regular Season",
    "NCAA Division I, Men - National Championship",
    "NCAA Division I, Women - National Championship",
    "NCAA Division II, Men - Regular Season",
    "NCAA Division II, Women - Regular Season",
    "NCAA Division II, Men - National Championship",
    "NCAA Division II, Women - National Championship",
    "NCAA Division III, Men",
    "NCAA Division III, Women"
  ),
  division = c(1L, 1L, 1L, 1L, 2L, 2L, 2L, 2L, 3L, 3L),
  gender = c("men", "women", "men", "women", "men", "women", "men", "women", "men", "women"),
  phase = c("regular", "regular", "postseason", "postseason", "regular", "regular", "postseason", "postseason", "all", "all"),
  stringsAsFactors = FALSE
)

ENDPOINT_TEMPLATES <- c(
  event = "/api/v1/event/%s",
  statistics = "/api/v1/event/%s/statistics",
  shotmap = "/api/v1/event/%s/shotmap",
  lineups = "/api/v1/event/%s/lineups",
  incidents = "/api/v1/event/%s/incidents",
  graph = "/api/v1/event/%s/graph",
  average_positions = "/api/v1/event/%s/average-positions",
  best_players = "/api/v1/event/%s/best-players/summary",
  managers = "/api/v1/event/%s/managers"
)

TABLE_NAMES <- c(
  "events", "team_statistics", "shots", "player_statistics",
  "incidents", "momentum", "average_positions", "best_players", "managers"
)

`%||%` <- function(x, fallback) {
  if (is.null(x) || length(x) == 0L) fallback else x
}

script_directory <- function() {
  full_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", full_args, value = TRUE)
  if (!length(file_arg)) return(normalizePath(getwd(), mustWork = FALSE))
  dirname(normalizePath(sub("^--file=", "", file_arg[[1L]]), mustWork = FALSE))
}

utc_now <- function() {
  format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
}

timestamp_to_utc <- function(x) {
  if (is.null(x) || !length(x) || is.na(suppressWarnings(as.numeric(x[[1L]])))) {
    return(NA_character_)
  }
  format(
    as.POSIXct(as.numeric(x[[1L]]), origin = "1970-01-01", tz = "UTC"),
    tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ"
  )
}

scalar_character <- function(x, default = NA_character_) {
  if (is.null(x) || !length(x)) return(default)
  as.character(x[[1L]])
}

scalar_numeric <- function(x, default = NA_real_) {
  if (is.null(x) || !length(x)) return(default)
  value <- suppressWarnings(as.numeric(x[[1L]]))
  if (is.na(value)) default else value
}

scalar_logical <- function(x, default = NA) {
  if (is.null(x) || !length(x)) return(default)
  as.logical(x[[1L]])
}

pluck_value <- function(x, ...) {
  keys <- list(...)
  value <- x
  for (key in keys) {
    if (!is.list(value) || is.null(value[[key]])) return(NULL)
    value <- value[[key]]
  }
  value
}

safe_column_name <- function(x) {
  x <- gsub("([a-z0-9])([A-Z])", "\\1_\\2", x, perl = TRUE)
  x <- gsub("[^A-Za-z0-9]+", "_", x, perl = TRUE)
  x <- gsub("^_+|_+$", "", x, perl = TRUE)
  tolower(x)
}

flatten_record <- function(x, prefix = NULL) {
  output <- list()
  skipped_keys <- c(
    "fieldTranslations", "teamColors", "eventState", "timeActive", "subTeams"
  )

  walk <- function(value, path, current_key = NULL) {
    if (!is.null(current_key) && current_key %in% skipped_keys) return(invisible(NULL))
    column <- safe_column_name(paste(path, collapse = "_"))

    if (is.null(value)) {
      if (nzchar(column)) output[[column]] <<- NA_character_
      return(invisible(NULL))
    }

    if (is.atomic(value) && length(value) <= 1L) {
      if (nzchar(column)) output[[column]] <<- if (!length(value)) NA_character_ else value
      return(invisible(NULL))
    }

    is_named_object <- is.list(value) && !is.null(names(value)) && any(nzchar(names(value)))
    if (is_named_object) {
      for (name in names(value)) {
        walk(value[[name]], c(path, name), name)
      }
      return(invisible(NULL))
    }

    if (nzchar(column)) {
      output[[column]] <<- as.character(jsonlite::toJSON(
        value, auto_unbox = TRUE, null = "null", na = "null", digits = NA
      ))
    }
    invisible(NULL)
  }

  if (is.list(x) && !is.null(names(x))) {
    for (name in names(x)) walk(x[[name]], c(prefix, name), name)
  } else {
    walk(x, prefix %||% "value")
  }
  output
}

rows_to_table <- function(rows) {
  if (!length(rows)) return(data.table::data.table())
  data.table::rbindlist(lapply(rows, as.list), use.names = TRUE, fill = TRUE)
}

add_canonical_fields <- function(canonical, flattened) {
  flattened[names(canonical)] <- NULL
  c(canonical, flattened)
}

ensure_directory <- function(path) {
  if (!dir.exists(path)) dir.create(path, recursive = TRUE, showWarnings = FALSE)
  invisible(path)
}

atomic_replace <- function(temp_path, target_path) {
  ensure_directory(dirname(target_path))
  if (file.exists(target_path)) unlink(target_path)
  if (!file.rename(temp_path, target_path)) {
    if (!file.copy(temp_path, target_path, overwrite = TRUE)) {
      stop("Could not write ", target_path, call. = FALSE)
    }
    unlink(temp_path)
  }
  invisible(target_path)
}

write_json_atomic <- function(x, path) {
  ensure_directory(dirname(path))
  temp_path <- tempfile(pattern = paste0(basename(path), "."), tmpdir = dirname(path))
  jsonlite::write_json(
    x, temp_path, auto_unbox = TRUE, pretty = TRUE,
    null = "null", na = "null", digits = NA
  )
  atomic_replace(temp_path, path)
}

read_json_safe <- function(path, default = NULL) {
  if (!file.exists(path)) return(default)
  tryCatch(
    jsonlite::read_json(path, simplifyVector = FALSE),
    error = function(error) default
  )
}

save_rds_atomic <- function(x, path) {
  ensure_directory(dirname(path))
  temp_path <- tempfile(pattern = paste0(basename(path), "."), tmpdir = dirname(path))
  saveRDS(x, temp_path, compress = "xz")
  atomic_replace(temp_path, path)
}

required_packages <- function() {
  c("chromote", "data.table", "httr2", "jsonlite")
}

check_dependencies <- function() {
  missing <- required_packages()[!vapply(required_packages(), requireNamespace, logical(1L), quietly = TRUE)]
  if (length(missing)) {
    stop(
      "Missing R package(s): ", paste(missing, collapse = ", "), "\n",
      "Run: Rscript install_dependencies.R",
      call. = FALSE
    )
  }
}

new_sofascore_client <- function(
    delay_seconds = 0.8,
    retries = 4L,
    timeout_seconds = 30,
    transport = "auto",
    chrome_path = NULL) {
  state <- new.env(parent = emptyenv())
  state$last_request <- as.numeric(Sys.time()) - delay_seconds
  state$browser <- NULL
  state$active_transport <- if (transport == "browser") "browser" else "direct"
  state$request_count <- 0L

  throttle <- function() {
    elapsed <- as.numeric(Sys.time()) - state$last_request
    remaining <- delay_seconds - elapsed
    if (is.finite(remaining) && remaining > 0) Sys.sleep(remaining)
    state$last_request <- as.numeric(Sys.time())
    state$request_count <- state$request_count + 1L
  }

  initialize_browser <- function() {
    if (!is.null(state$browser)) return(invisible(state$browser))
    if (!is.null(chrome_path) && nzchar(chrome_path)) {
      Sys.setenv(CHROMOTE_CHROME = chrome_path)
    }
    if (identical(Sys.info()[["sysname"]], "Linux")) {
      chromote::set_chrome_args(unique(c(
        chromote::get_chrome_args(),
        "--no-sandbox",
        "--disable-dev-shm-usage"
      )))
    }
    state$browser <- chromote::ChromoteSession$new()
    invisible(state$browser$Page$navigate(paste0(SOFASCORE_BASE, "/")))
    invisible(state$browser$Page$loadEventFired(wait_ = TRUE))
    invisible(state$browser)
  }

  direct_fetch <- function(path) {
    url <- paste0(SOFASCORE_BASE, path)
    request <- httr2::request(url)
    request <- httr2::req_headers(
      request,
      Accept = "application/json",
      Referer = paste0(SOFASCORE_BASE, "/")
    )
    request <- httr2::req_user_agent(
      request,
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/126 Safari/537.36"
    )
    request <- httr2::req_timeout(request, timeout_seconds)
    request <- httr2::req_error(request, is_error = function(response) FALSE)
    tryCatch({
      response <- httr2::req_perform(request)
      list(
        status = httr2::resp_status(response),
        body = httr2::resp_body_string(response),
        error = NULL,
        transport = "direct"
      )
    }, error = function(error) {
      list(status = 0L, body = "", error = conditionMessage(error), transport = "direct")
    })
  }

  browser_fetch <- function(path) {
    tryCatch({
      initialize_browser()
      path_json <- as.character(jsonlite::toJSON(path, auto_unbox = TRUE))
      javascript <- sprintf(
        paste0(
          "(async () => {",
          "const controller = new AbortController();",
          "const timer = setTimeout(() => controller.abort(), %d);",
          "try {",
          "const response = await fetch(%s, {",
          "headers: {'accept': 'application/json'}, signal: controller.signal",
          "});",
          "const body = await response.text();",
          "return JSON.stringify({status: response.status, body: body, error: null});",
          "} catch (error) {",
          "return JSON.stringify({status: 0, body: '', error: String(error)});",
          "} finally { clearTimeout(timer); }",
          "})()"
        ),
        as.integer(timeout_seconds * 1000), path_json
      )
      evaluated <- state$browser$Runtime$evaluate(
        javascript, awaitPromise = TRUE, returnByValue = TRUE
      )
      value <- pluck_value(evaluated, "result", "value")
      if (is.null(value)) stop("Chrome returned no value")
      parsed <- jsonlite::fromJSON(value, simplifyVector = FALSE)
      list(
        status = as.integer(parsed$status %||% 0L),
        body = scalar_character(parsed$body, ""),
        error = parsed$error %||% NULL,
        transport = "browser"
      )
    }, error = function(error) {
      if (!is.null(state$browser)) try(state$browser$close(), silent = TRUE)
      state$browser <- NULL
      list(status = 0L, body = "", error = conditionMessage(error), transport = "browser")
    })
  }

  get_json <- function(path) {
    last_result <- NULL
    attempt <- 0L
    max_attempts <- as.integer(retries) + 1L

    while (attempt < max_attempts) {
      attempt <- attempt + 1L
      throttle()
      result <- if (state$active_transport == "browser") browser_fetch(path) else direct_fetch(path)

      if (
        transport == "auto" && state$active_transport == "direct" &&
          result$status %in% c(401L, 403L)
      ) {
        state$active_transport <- "browser"
        attempt <- attempt - 1L
        next
      }

      last_result <- result
      if (result$status == 200L) {
        data <- tryCatch(
          jsonlite::fromJSON(result$body, simplifyVector = FALSE),
          error = function(error) error
        )
        if (!inherits(data, "error")) {
          result$ok <- TRUE
          result$data <- data
          result$attempts <- attempt
          return(result)
        }
        result$error <- paste("Invalid JSON:", conditionMessage(data))
        last_result <- result
      }

      if (result$status == 404L) {
        result$ok <- FALSE
        result$data <- NULL
        result$attempts <- attempt
        return(result)
      }

      retryable <- result$status == 0L || result$status == 429L || result$status >= 500L
      if (!retryable || attempt >= max_attempts) break
      Sys.sleep(min(2^(attempt - 1L), 30) + stats::runif(1L, 0, 0.5))
    }

    last_result$ok <- FALSE
    last_result$data <- NULL
    last_result$attempts <- attempt
    last_result
  }

  close <- function() {
    if (!is.null(state$browser)) try(state$browser$close(), silent = TRUE)
    state$browser <- NULL
    invisible(TRUE)
  }

  list(
    get = get_json,
    close = close,
    request_count = function() state$request_count,
    transport = function() state$active_transport
  )
}

extract_event_id <- function(value) {
  if (is.null(value) || !nzchar(value)) return(NA_integer_)
  patterns <- c("#id:([0-9]+)", "[?&]id=([0-9]+)", "/event/([0-9]+)", "^([0-9]+)$")
  for (pattern in patterns) {
    match <- regexec(pattern, value, perl = TRUE)
    groups <- regmatches(value, match)[[1L]]
    if (length(groups) >= 2L) return(as.integer(groups[[2L]]))
  }
  stop("Could not find a SofaScore event ID in: ", value, call. = FALSE)
}

competition_subset <- function(options) {
  competitions <- COLLEGE_COMPETITIONS
  if (!is.null(options$competition_ids)) {
    ids <- as.integer(strsplit(options$competition_ids, ",", fixed = TRUE)[[1L]])
    unknown <- setdiff(ids, competitions$unique_tournament_id)
    if (length(unknown)) {
      extra <- data.frame(
        unique_tournament_id = unknown,
        competition = paste("Custom competition", unknown),
        division = NA_integer_, gender = "unknown", phase = "unknown",
        stringsAsFactors = FALSE
      )
      competitions <- rbind(competitions[competitions$unique_tournament_id %in% ids, ], extra)
    } else {
      competitions <- competitions[competitions$unique_tournament_id %in% ids, ]
    }
  } else {
    if (options$gender != "all") competitions <- competitions[competitions$gender == options$gender, ]
    if (options$division != "all") {
      divisions <- as.integer(strsplit(options$division, ",", fixed = TRUE)[[1L]])
      competitions <- competitions[competitions$division %in% divisions, ]
    }
  }
  if (!nrow(competitions)) stop("No competitions remain after filtering", call. = FALSE)
  competitions
}

season_start_for <- function(date) {
  year <- as.integer(format(date, "%Y"))
  month <- as.integer(format(date, "%m"))
  if (month < 8L) year <- year - 1L
  as.Date(sprintf("%04d-08-01", year))
}

date_in_timezone <- function(timezone) {
  as.Date(format(Sys.time(), tz = timezone, format = "%Y-%m-%d"))
}

discovery_cache_path <- function(output_dir, date, competition_id) {
  file.path(output_dir, "discovery", as.character(date), paste0(competition_id, ".json"))
}

discover_college_events <- function(
    client, dates, competitions, output_dir, refresh_cutoff, force = FALSE) {
  events_by_id <- list()
  failed_requests <- list()

  total <- length(dates) * nrow(competitions)
  counter <- 0L
  message(sprintf("Discovering games: %d dates x %d NCAA feeds (%d date/feed requests)",
                  length(dates), nrow(competitions), total))

  for (date in dates) {
    date <- as.Date(date, origin = "1970-01-01")
    for (row_index in seq_len(nrow(competitions))) {
      counter <- counter + 1L
      competition_id <- competitions$unique_tournament_id[[row_index]]
      cache_path <- discovery_cache_path(output_dir, date, competition_id)
      should_refresh <- force || date >= refresh_cutoff
      payload <- if (!should_refresh) read_json_safe(cache_path) else NULL

      if (is.null(payload)) {
        path <- sprintf(
          "/api/v1/unique-tournament/%s/scheduled-events/%s",
          competition_id, format(date, "%Y-%m-%d")
        )
        response <- client$get(path)
        if (isTRUE(response$ok)) {
          payload <- response$data
          write_json_atomic(payload, cache_path)
        } else if (response$status == 404L) {
          payload <- list(events = list())
          write_json_atomic(payload, cache_path)
        } else {
          stale <- read_json_safe(cache_path)
          if (!is.null(stale)) {
            payload <- stale
          } else {
            failure <- list(
              date = as.character(date), competition_id = competition_id,
              status = response$status,
              transport = response$transport %||% NA_character_,
              error = response$error %||% NA_character_
            )
            failed_requests[[length(failed_requests) + 1L]] <- failure
            message(sprintf(
              "  discovery FAILED: date=%s feed=%s status=%s transport=%s error=%s",
              failure$date, failure$competition_id, failure$status,
              scalar_character(failure$transport, "unknown"),
              scalar_character(failure$error, "no error message")
            ))
            next
          }
        }
      }

      event_rows <- payload$events %||% list()
      for (event in event_rows) {
        event_id <- scalar_numeric(event$id)
        if (is.na(event_id)) next
        event$discoveryDate <- as.character(date)
        event$sourceCompetitionId <- competition_id
        event$sourceCompetitionName <- competitions$competition[[row_index]]
        events_by_id[[as.character(as.integer(event_id))]] <- event
      }

      if (counter %% 50L == 0L || counter == total) {
        message(sprintf("  discovery %d/%d; %d unique games found", counter, total, length(events_by_id)))
      }
    }
  }

  list(events = unname(events_by_id), failures = failed_requests)
}

event_summary_row <- function(event, selected = TRUE) {
  data.table::data.table(
    event_id = as.integer(scalar_numeric(event$id)),
    discovery_date = scalar_character(event$discoveryDate),
    start_time_utc = timestamp_to_utc(event$startTimestamp),
    status = scalar_character(pluck_value(event, "status", "type")),
    home_team = scalar_character(pluck_value(event, "homeTeam", "name")),
    away_team = scalar_character(pluck_value(event, "awayTeam", "name")),
    unique_tournament_id = as.integer(scalar_numeric(pluck_value(event, "tournament", "uniqueTournament", "id"))),
    competition = scalar_character(event$sourceCompetitionName %||% pluck_value(event, "tournament", "uniqueTournament", "name")),
    has_xg = scalar_logical(event$hasXg),
    has_player_statistics = scalar_logical(event$hasEventPlayerStatistics),
    selected = selected
  )
}

event_object <- function(event_payload, event_hint = NULL) {
  if (!is.null(event_payload$event)) return(event_payload$event)
  event_payload %||% event_hint %||% list()
}

parse_event_table <- function(event_payload, event_hint = NULL) {
  event <- event_object(event_payload, event_hint)
  event_id <- as.integer(scalar_numeric(event$id))
  feed_id <- as.integer(scalar_numeric(
    event_hint$sourceCompetitionId %||%
      event$sourceCompetitionId %||%
      pluck_value(event, "tournament", "uniqueTournament", "id")
  ))
  feed_row <- COLLEGE_COMPETITIONS[COLLEGE_COMPETITIONS$unique_tournament_id == feed_id, , drop = FALSE]
  feed_name <- scalar_character(
    event_hint$sourceCompetitionName %||%
      event$sourceCompetitionName %||%
      if (nrow(feed_row)) feed_row$competition[[1L]] else NULL,
    scalar_character(pluck_value(event, "tournament", "uniqueTournament", "name"))
  )
  canonical <- list(
    event_id = event_id,
    discovery_date = scalar_character(event$discoveryDate %||% event_hint$discoveryDate),
    source_competition_id = feed_id,
    source_competition_name = feed_name,
    feed_gender = if (nrow(feed_row)) feed_row$gender[[1L]] else NA_character_,
    feed_division = if (nrow(feed_row)) feed_row$division[[1L]] else NA_integer_,
    feed_phase = if (nrow(feed_row)) feed_row$phase[[1L]] else NA_character_,
    start_time_utc = timestamp_to_utc(event$startTimestamp),
    status_type = scalar_character(pluck_value(event, "status", "type")),
    status_description = scalar_character(pluck_value(event, "status", "description")),
    home_team_id = as.integer(scalar_numeric(pluck_value(event, "homeTeam", "id"))),
    home_team_name = scalar_character(pluck_value(event, "homeTeam", "name")),
    away_team_id = as.integer(scalar_numeric(pluck_value(event, "awayTeam", "id"))),
    away_team_name = scalar_character(pluck_value(event, "awayTeam", "name")),
    tournament_id = as.integer(scalar_numeric(pluck_value(event, "tournament", "id"))),
    tournament_name = scalar_character(pluck_value(event, "tournament", "name")),
    unique_tournament_id = as.integer(scalar_numeric(pluck_value(event, "tournament", "uniqueTournament", "id"))),
    unique_tournament_name = scalar_character(pluck_value(event, "tournament", "uniqueTournament", "name")),
    season_id = as.integer(scalar_numeric(pluck_value(event, "season", "id"))),
    season_name = scalar_character(pluck_value(event, "season", "name")),
    has_xg = scalar_logical(event$hasXg),
    has_player_statistics = scalar_logical(event$hasEventPlayerStatistics),
    has_player_heatmap = scalar_logical(event$hasEventPlayerHeatMap),
    source_url = if (!is.na(event_id)) sprintf("%s/#id:%s", SOFASCORE_BASE, event_id) else NA_character_
  )
  flattened <- flatten_record(event)
  flattened$id <- NULL
  rows_to_table(list(add_canonical_fields(canonical, flattened)))
}

team_context <- function(event, side) {
  team <- event[[paste0(side, "Team")]] %||% list()
  list(
    team_id = as.integer(scalar_numeric(team$id)),
    team_name = scalar_character(team$name)
  )
}

parse_team_statistics <- function(payload, event_id) {
  rows <- list()
  for (period_block in payload$statistics %||% list()) {
    period <- scalar_character(period_block$period)
    for (group in period_block$groups %||% list()) {
      group_name <- scalar_character(group$groupName)
      for (item in group$statisticsItems %||% list()) {
        canonical <- list(event_id = event_id, period = period, group_name = group_name)
        rows[[length(rows) + 1L]] <- add_canonical_fields(canonical, flatten_record(item))
      }
    }
  }
  rows_to_table(rows)
}

parse_shots <- function(payload, event_id, event) {
  rows <- list()
  for (shot in payload$shotmap %||% list()) {
    side <- if (isTRUE(shot$isHome)) "home" else if (identical(shot$isHome, FALSE)) "away" else NA_character_
    context <- if (!is.na(side)) team_context(event, side) else list(team_id = NA_integer_, team_name = NA_character_)
    canonical <- c(list(event_id = event_id, side = side), context)
    rows[[length(rows) + 1L]] <- add_canonical_fields(canonical, flatten_record(shot))
  }
  rows_to_table(rows)
}

parse_player_statistics <- function(payload, event_id, event) {
  rows <- list()
  for (side in c("home", "away")) {
    lineup <- payload[[side]] %||% list()
    context <- team_context(event, side)
    for (player_row in lineup$players %||% list()) {
      canonical <- c(
        list(
          event_id = event_id,
          side = side,
          lineup_confirmed = scalar_logical(payload$confirmed),
          lineup_formation = scalar_character(lineup$formation),
          statistical_version = scalar_numeric(payload$statisticalVersion)
        ),
        context
      )
      rows[[length(rows) + 1L]] <- add_canonical_fields(canonical, flatten_record(player_row))
    }
  }
  rows_to_table(rows)
}

parse_incidents <- function(payload, event_id) {
  rows <- list()
  for (incident in payload$incidents %||% list()) {
    side <- if (isTRUE(incident$isHome)) "home" else if (identical(incident$isHome, FALSE)) "away" else NA_character_
    canonical <- list(event_id = event_id, side = side)
    rows[[length(rows) + 1L]] <- add_canonical_fields(canonical, flatten_record(incident))
  }
  rows_to_table(rows)
}

parse_momentum <- function(payload, event_id) {
  rows <- list()
  series <- list(v1 = payload$graphPoints %||% list(), v2 = payload$graphPointsV2 %||% list())
  for (version in names(series)) {
    for (point in series[[version]]) {
      canonical <- list(
        event_id = event_id,
        graph_version = version,
        period_time = scalar_numeric(payload$periodTime),
        overtime_length = scalar_numeric(payload$overtimeLength),
        period_count = scalar_numeric(payload$periodCount)
      )
      rows[[length(rows) + 1L]] <- add_canonical_fields(canonical, flatten_record(point))
    }
  }
  rows_to_table(rows)
}

parse_average_positions <- function(payload, event_id, event) {
  rows <- list()
  for (side in c("home", "away")) {
    context <- team_context(event, side)
    for (position in payload[[side]] %||% list()) {
      canonical <- c(list(event_id = event_id, side = side), context)
      rows[[length(rows) + 1L]] <- add_canonical_fields(canonical, flatten_record(position))
    }
  }
  rows_to_table(rows)
}

parse_best_players <- function(payload, event_id) {
  rows <- list()
  groups <- list(
    best_home = payload$bestHomeTeamPlayers %||% list(),
    best_away = payload$bestAwayTeamPlayers %||% list(),
    leaderboard = payload$leaderboard %||% list()
  )
  if (!is.null(payload$playerOfTheMatch)) groups$player_of_the_match <- list(payload$playerOfTheMatch)
  for (group_name in names(groups)) {
    group_rows <- groups[[group_name]]
    if (!length(group_rows)) next
    for (rank in seq_along(group_rows)) {
      canonical <- list(event_id = event_id, list_type = group_name, rank = rank)
      rows[[length(rows) + 1L]] <- add_canonical_fields(canonical, flatten_record(group_rows[[rank]]))
    }
  }
  rows_to_table(rows)
}

parse_managers <- function(payload, event_id, event) {
  rows <- list()
  for (side in c("home", "away")) {
    manager <- payload[[paste0(side, "Manager")]]
    if (is.null(manager)) next
    canonical <- c(list(event_id = event_id, side = side), team_context(event, side))
    rows[[length(rows) + 1L]] <- add_canonical_fields(canonical, flatten_record(manager))
  }
  rows_to_table(rows)
}

fragment_path <- function(output_dir, table_name, event_id) {
  file.path(output_dir, "fragments", table_name, paste0(event_id, ".rds"))
}

save_event_fragments <- function(output_dir, event_id, tables) {
  for (table_name in TABLE_NAMES) {
    table <- tables[[table_name]] %||% data.table::data.table()
    path <- fragment_path(output_dir, table_name, event_id)
    if (nrow(table)) {
      save_rds_atomic(table, path)
    } else if (file.exists(path)) {
      unlink(path)
    }
  }
  invisible(TRUE)
}

parse_event_payloads <- function(payloads, event_hint, event_id) {
  event_payload <- payloads$event %||% list(event = event_hint)
  event <- event_object(event_payload, event_hint)
  if (is.null(event$discoveryDate) && !is.null(event_hint$discoveryDate)) {
    event$discoveryDate <- event_hint$discoveryDate
  }

  list(
    events = parse_event_table(list(event = event), event_hint),
    team_statistics = parse_team_statistics(payloads$statistics %||% list(), event_id),
    shots = parse_shots(payloads$shotmap %||% list(), event_id, event),
    player_statistics = parse_player_statistics(payloads$lineups %||% list(), event_id, event),
    incidents = parse_incidents(payloads$incidents %||% list(), event_id),
    momentum = parse_momentum(payloads$graph %||% list(), event_id),
    average_positions = parse_average_positions(payloads$average_positions %||% list(), event_id, event),
    best_players = parse_best_players(payloads$best_players %||% list(), event_id),
    managers = parse_managers(payloads$managers %||% list(), event_id, event)
  )
}

event_manifest_path <- function(output_dir, event_id) {
  file.path(output_dir, "raw", as.character(event_id), "_manifest.json")
}

endpoint_payload_path <- function(output_dir, event_id, endpoint_name) {
  file.path(output_dir, "raw", as.character(event_id), paste0(endpoint_name, ".json"))
}

scrape_event <- function(
    client, event_hint, output_dir, force = FALSE, refresh_missing = FALSE) {
  event_id <- as.integer(scalar_numeric(event_hint$id))
  if (is.na(event_id)) stop("Event has no ID", call. = FALSE)
  raw_dir <- file.path(output_dir, "raw", as.character(event_id))
  ensure_directory(raw_dir)
  manifest_path <- event_manifest_path(output_dir, event_id)
  manifest <- read_json_safe(manifest_path, list(
    event_id = event_id,
    script_version = SCRIPT_VERSION,
    parser_version = PARSER_VERSION,
    endpoints = list()
  ))
  manifest$event_id <- event_id
  manifest$script_version <- SCRIPT_VERSION
  manifest$parser_version <- PARSER_VERSION
  manifest$last_attempt_utc <- utc_now()
  manifest$endpoints <- manifest$endpoints %||% list()

  payloads <- list()
  retry_needed <- FALSE

  for (endpoint_name in names(ENDPOINT_TEMPLATES)) {
    payload_path <- endpoint_payload_path(output_dir, event_id, endpoint_name)
    previous <- manifest$endpoints[[endpoint_name]] %||% list()
    previous_status <- as.integer(scalar_numeric(previous$status, NA_real_))
    terminal_missing <- !is.na(previous_status) && previous_status == 404L

    if (!force && file.exists(payload_path)) {
      payloads[[endpoint_name]] <- read_json_safe(payload_path, list())
      previous$cached <- TRUE
      manifest$endpoints[[endpoint_name]] <- previous
      next
    }
    if (!force && terminal_missing && !refresh_missing) next

    path <- sprintf(ENDPOINT_TEMPLATES[[endpoint_name]], event_id)
    response <- client$get(path)
    endpoint_record <- list(
      path = path,
      status = response$status,
      ok = isTRUE(response$ok),
      transport = response$transport,
      attempts = response$attempts,
      retrieved_at_utc = utc_now(),
      error = response$error %||% NULL,
      cached = FALSE
    )

    if (isTRUE(response$ok)) {
      write_json_atomic(response$data, payload_path)
      payloads[[endpoint_name]] <- response$data
    } else if (file.exists(payload_path)) {
      payloads[[endpoint_name]] <- read_json_safe(payload_path, list())
      endpoint_record$used_stale_cache <- TRUE
    }

    if (response$status == 0L || response$status == 429L || response$status >= 500L) {
      retry_needed <- TRUE
    }
    manifest$endpoints[[endpoint_name]] <- endpoint_record
    write_json_atomic(manifest, manifest_path)
  }

  for (endpoint_name in names(ENDPOINT_TEMPLATES)) {
    if (is.null(payloads[[endpoint_name]])) {
      payloads[[endpoint_name]] <- read_json_safe(
        endpoint_payload_path(output_dir, event_id, endpoint_name), list()
      )
    }
  }

  tables <- parse_event_payloads(payloads, event_hint, event_id)
  save_event_fragments(output_dir, event_id, tables)
  manifest$parsed_at_utc <- utc_now()
  manifest$retry_needed <- retry_needed
  write_json_atomic(manifest, manifest_path)

  list(event_id = event_id, retry_needed = retry_needed, tables = tables)
}

rebuild_csv_tables <- function(output_dir) {
  table_dir <- file.path(output_dir, "tables")
  ensure_directory(table_dir)
  message("Rebuilding cumulative CSV tables from per-event fragments...")

  for (table_name in TABLE_NAMES) {
    fragment_dir <- file.path(output_dir, "fragments", table_name)
    files <- if (dir.exists(fragment_dir)) {
      sort(list.files(fragment_dir, pattern = "\\.rds$", full.names = TRUE))
    } else character()
    if (!length(files)) next

    all_columns <- character()
    for (path in files) {
      fragment <- tryCatch(readRDS(path), error = function(error) NULL)
      if (!is.null(fragment)) all_columns <- union(all_columns, names(fragment))
    }
    if (!length(all_columns)) next

    preferred <- c("event_id", "discovery_date", "start_time_utc", "side", "team_id", "player_id")
    all_columns <- c(intersect(preferred, all_columns), setdiff(all_columns, preferred))
    final_path <- file.path(table_dir, paste0(table_name, ".csv"))
    temp_path <- tempfile(pattern = paste0(table_name, "."), tmpdir = table_dir)
    first <- TRUE
    row_count <- 0L

    for (path in files) {
      fragment <- tryCatch(data.table::as.data.table(readRDS(path)), error = function(error) NULL)
      if (is.null(fragment) || !nrow(fragment)) next
      missing_columns <- setdiff(all_columns, names(fragment))
      for (column in missing_columns) fragment[, (column) := NA]
      data.table::setcolorder(fragment, all_columns)
      data.table::fwrite(
        fragment, temp_path, append = !first, col.names = first,
        na = "", quote = "auto"
      )
      first <- FALSE
      row_count <- row_count + nrow(fragment)
    }

    if (!first) {
      atomic_replace(temp_path, final_path)
      message(sprintf("  %-22s %8d rows", paste0(table_name, ".csv"), row_count))
    } else if (file.exists(temp_path)) {
      unlink(temp_path)
    }
  }
  invisible(TRUE)
}

parse_boolean <- function(x) {
  if (is.logical(x)) return(x)
  value <- tolower(as.character(x))
  if (value %in% c("true", "t", "1", "yes", "y")) return(TRUE)
  if (value %in% c("false", "f", "0", "no", "n")) return(FALSE)
  stop("Not a boolean value: ", x, call. = FALSE)
}

is_incremental_date_mode <- function(options) {
  is.null(options$event) && is.null(options$start_date) && is.null(options$end_date)
}

default_options <- function() {
  list(
    event = NULL,
    start_date = NULL,
    end_date = NULL,
    output = file.path(script_directory(), "data"),
    timezone = "America/Chicago",
    lookback_days = 3L,
    delay = 0.8,
    retries = 4L,
    timeout = 30,
    transport = "auto",
    chrome_path = NULL,
    gender = "men",
    division = "1",
    competition_ids = NULL,
    only_xg = FALSE,
    force = FALSE,
    dry_run = FALSE,
    no_rebuild = FALSE,
    max_events = Inf,
    list_competitions = FALSE,
    help = FALSE
  )
}

parse_cli <- function(args) {
  options <- default_options()
  boolean_flags <- c(
    "only-xg", "force", "dry-run", "no-rebuild", "list-competitions", "help"
  )
  value_flags <- c(
    "event", "start-date", "end-date", "output", "timezone", "lookback-days",
    "delay", "retries", "timeout", "transport", "chrome-path", "gender",
    "division", "competition-ids", "max-events"
  )

  index <- 1L
  while (index <= length(args)) {
    argument <- args[[index]]
    if (!startsWith(argument, "--")) stop("Unexpected argument: ", argument, call. = FALSE)
    pair <- strsplit(sub("^--", "", argument), "=", fixed = TRUE)[[1L]]
    name <- pair[[1L]]
    key <- gsub("-", "_", name, fixed = TRUE)

    if (name %in% boolean_flags) {
      value <- if (length(pair) > 1L) parse_boolean(pair[[2L]]) else TRUE
    } else if (name %in% value_flags) {
      if (length(pair) > 1L) {
        value <- paste(pair[-1L], collapse = "=")
      } else {
        index <- index + 1L
        if (index > length(args)) stop("Missing value for --", name, call. = FALSE)
        value <- args[[index]]
      }
    } else {
      stop("Unknown option: --", name, call. = FALSE)
    }
    options[[key]] <- value
    index <- index + 1L
  }

  options$lookback_days <- as.integer(options$lookback_days)
  options$delay <- as.numeric(options$delay)
  options$retries <- as.integer(options$retries)
  options$timeout <- as.numeric(options$timeout)
  options$max_events <- as.numeric(options$max_events)
  options$only_xg <- parse_boolean(options$only_xg)
  options$force <- parse_boolean(options$force)
  options$dry_run <- parse_boolean(options$dry_run)
  options$no_rebuild <- parse_boolean(options$no_rebuild)
  options$list_competitions <- parse_boolean(options$list_competitions)
  options$help <- parse_boolean(options$help)
  options$gender <- tolower(options$gender)
  options$transport <- tolower(options$transport)

  if (!options$gender %in% c("all", "men", "women")) {
    stop("--gender must be all, men, or women", call. = FALSE)
  }
  if (!options$transport %in% c("auto", "direct", "browser")) {
    stop("--transport must be auto, direct, or browser", call. = FALSE)
  }
  options
}

print_help <- function() {
  cat(paste0(
    "SofaScore NCAA soccer scraper v", SCRIPT_VERSION, "\n\n",
    "Daily/current-season mode (default):\n",
    "  Rscript sofascore_college_scraper.R\n\n",
    "Historical backfill:\n",
    "  Rscript sofascore_college_scraper.R --start-date 2024-08-01 --end-date 2026-08-31\n\n",
    "One match or URL:\n",
    "  Rscript sofascore_college_scraper.R --event 16718922\n",
    "  Rscript sofascore_college_scraper.R --event 'https://www.sofascore.com/...#id:16718922'\n\n",
    "Important options:\n",
    "  --output PATH             Cache and output directory (default: ./data)\n",
    "  --gender all|men|women    Default: men\n",
    "  --division all|1|2|3      Default: 1; comma-separated values accepted\n",
    "  --only-xg                 Keep only games flagged as having xG\n",
    "  --lookback-days N         Refresh recent discovery/data (default: 3)\n",
    "  --delay SECONDS           Minimum delay per request (default: 0.8)\n",
    "  --force                   Refresh cached match endpoints\n",
    "  --dry-run                 Discover and list games without scraping them\n",
    "  --max-events N            Safety/test limit; does not advance daily state\n",
    "  --competition-ids IDS     Override built-in tournament IDs\n",
    "  --list-competitions       Print built-in NCAA feeds\n",
    "  --transport auto|direct|browser\n",
    "  --chrome-path PATH        Explicit Chrome/Chromium executable\n",
    "  --no-rebuild              Skip cumulative CSV rebuild\n",
    "  --help\n"
  ))
}

load_state <- function(output_dir) {
  read_json_safe(file.path(output_dir, "state.json"), list())
}

save_state <- function(output_dir, state) {
  write_json_atomic(state, file.path(output_dir, "state.json"))
}

write_run_index <- function(output_dir, event_rows) {
  if (!length(event_rows)) return(invisible(NULL))
  run_dir <- file.path(output_dir, "runs")
  ensure_directory(run_dir)
  run_id <- format(Sys.time(), tz = "UTC", format = "%Y%m%dT%H%M%SZ")
  path <- file.path(run_dir, paste0(run_id, "_events.csv"))
  table <- data.table::rbindlist(event_rows, use.names = TRUE, fill = TRUE)
  data.table::setorder(table, start_time_utc, event_id)
  data.table::fwrite(table, path)
  invisible(path)
}

main <- function() {
  options <- parse_cli(commandArgs(trailingOnly = TRUE))
  if (options$help) {
    print_help()
    return(invisible(0L))
  }
  if (options$list_competitions) {
    print(COLLEGE_COMPETITIONS, row.names = FALSE)
    return(invisible(0L))
  }

  check_dependencies()
  output_dir <- normalizePath(options$output, mustWork = FALSE)
  ensure_directory(output_dir)
  competitions <- competition_subset(options)
  state <- load_state(output_dir)
  pending_ids <- unique(as.integer(unlist(state$pending_event_ids %||% list())))
  pending_ids <- pending_ids[!is.na(pending_ids)]
  client <- new_sofascore_client(
    delay_seconds = options$delay,
    retries = options$retries,
    timeout_seconds = options$timeout,
    transport = options$transport,
    chrome_path = options$chrome_path
  )
  on.exit(client$close(), add = TRUE)

  date_mode <- is.null(options$event)
  incremental_mode <- is_incremental_date_mode(options)
  truncated <- FALSE
  discovery_failures <- list()

  if (!date_mode) {
    event_id <- extract_event_id(options$event)
    events <- list(list(id = event_id, status = list(type = "finished")))
    start_date <- end_date <- date_in_timezone(options$timezone)
    refresh_cutoff <- start_date
  } else {
    today <- date_in_timezone(options$timezone)
    end_date <- if (is.null(options$end_date)) today else as.Date(options$end_date)
    season_start <- season_start_for(end_date)
    if (!is.null(options$start_date)) {
      start_date <- as.Date(options$start_date)
    } else if (!is.null(state$last_successful_date)) {
      resumed <- as.Date(scalar_character(state$last_successful_date)) - options$lookback_days
      start_date <- max(season_start, resumed)
    } else {
      start_date <- season_start
    }
    if (is.na(start_date) || is.na(end_date)) stop("Invalid start or end date", call. = FALSE)
    if (start_date > end_date) stop("Start date is after end date", call. = FALSE)
    dates <- seq.Date(start_date, end_date, by = "day")
    refresh_cutoff <- end_date - options$lookback_days
    discovered <- discover_college_events(
      client, dates, competitions, output_dir, refresh_cutoff, options$force
    )
    events <- discovered$events
    discovery_failures <- discovered$failures
  }

  statuses <- vapply(
    events,
    function(event) scalar_character(pluck_value(event, "status", "type"), "unknown"),
    character(1L)
  )
  completed <- events[statuses == "finished"]
  if (options$only_xg) {
    completed <- Filter(function(event) isTRUE(event$hasXg), completed)
  }
  completed_ids <- vapply(completed, function(event) as.integer(scalar_numeric(event$id)), integer(1L))

  run_rows <- lapply(events, function(event) {
    event_summary_row(event, scalar_numeric(event$id) %in% completed_ids)
  })
  run_index <- write_run_index(output_dir, run_rows)

  if (is.finite(options$max_events) && length(completed) > options$max_events) {
    completed <- completed[seq_len(as.integer(options$max_events))]
    truncated <- TRUE
  }

  known_ids <- vapply(completed, function(event) as.integer(scalar_numeric(event$id)), integer(1L))
  missing_pending <- if (incremental_mode) setdiff(pending_ids, known_ids) else integer()
  if (length(missing_pending)) {
    completed <- c(completed, lapply(missing_pending, function(id) {
      list(id = id, status = list(type = "finished"))
    }))
  }

  message(sprintf(
    "Completed games selected: %d%s",
    length(completed), if (options$only_xg) " (xG-flagged only)" else ""
  ))
  if (!is.null(run_index)) message("Run index: ", run_index)

  if (options$dry_run) {
    message("Dry run complete; no match endpoints were scraped.")
    return(invisible(0L))
  }

  if (length(completed)) {
    expected_requests <- length(completed) * length(ENDPOINT_TEMPLATES)
    message(sprintf(
      "Up to %d match-endpoint requests (cache hits reduce this); minimum uncached delay about %.1f minutes.",
      expected_requests, expected_requests * options$delay / 60
    ))
  }

  next_pending <- integer()
  for (index in seq_along(completed)) {
    event <- completed[[index]]
    event_id <- as.integer(scalar_numeric(event$id))
    discovery_date <- suppressWarnings(as.Date(scalar_character(event$discoveryDate)))
    recent_event <- !is.na(discovery_date) && discovery_date >= refresh_cutoff
    refresh_event <- options$force
    message(sprintf(
      "[%d/%d] %s: %s vs %s%s",
      index, length(completed), event_id,
      scalar_character(pluck_value(event, "homeTeam", "name"), "home"),
      scalar_character(pluck_value(event, "awayTeam", "name"), "away"),
      if (refresh_event) " (force refresh)" else if (recent_event) " (check late data)" else ""
    ))
    result <- tryCatch(
      scrape_event(
        client, event, output_dir,
        force = refresh_event, refresh_missing = recent_event
      ),
      error = function(error) {
        message("  ERROR: ", conditionMessage(error))
        list(event_id = event_id, retry_needed = TRUE)
      }
    )
    if (isTRUE(result$retry_needed)) next_pending <- c(next_pending, event_id)
  }

  if (!options$no_rebuild) rebuild_csv_tables(output_dir)

  if (incremental_mode) {
    state$last_run_utc <- utc_now()
    state$season_start <- as.character(season_start_for(end_date))
    state$pending_event_ids <- as.list(unique(next_pending))
    state$script_version <- SCRIPT_VERSION
    state$discovery_failures <- discovery_failures
    if (truncated) {
      message("Daily state was not advanced because --max-events truncated the run.")
    } else if (length(discovery_failures)) {
      message("Daily state was not advanced because some discovery requests failed; they will be retried.")
    } else {
      state$last_successful_date <- as.character(end_date)
    }
    save_state(output_dir, state)
  } else if (date_mode) {
    message("Explicit date run complete; recurring scheduler state was not changed.")
  }

  if (length(discovery_failures)) {
    stop(sprintf(
      "Run incomplete: %d event-discovery request(s) failed; retry the run.",
      length(discovery_failures)
    ), call. = FALSE)
  }

  message(sprintf(
    "Done. %d network requests this run using %s transport. Output: %s",
    client$request_count(), client$transport(), output_dir
  ))
  invisible(0L)
}

if (sys.nframe() == 0L) {
  tryCatch(
    main(),
    error = function(error) {
      message("ERROR: ", conditionMessage(error))
      quit(status = 1L, save = "no")
    }
  )
}
