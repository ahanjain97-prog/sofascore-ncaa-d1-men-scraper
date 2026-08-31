#!/usr/bin/env Rscript

script_path <- normalizePath(
  file.path(dirname(normalizePath(commandArgs(trailingOnly = FALSE)[grep("^--file=", commandArgs(trailingOnly = FALSE))][1L] |> sub("^--file=", "", x = _))), "..", "sofascore_college_scraper.R"),
  mustWork = TRUE
)
source(script_path)

event <- list(
  id = 16718922L,
  startTimestamp = 1788134400,
  status = list(type = "finished", description = "Ended"),
  homeTeam = list(id = 329974L, name = "Northern Illinois Huskies"),
  awayTeam = list(id = 329901L, name = "UIC Flames"),
  tournament = list(
    id = 68377L, name = "NCAA",
    uniqueTournament = list(id = 15946L, name = "NCAA")
  ),
  hasXg = TRUE,
  hasEventPlayerStatistics = TRUE,
  homeScore = list(current = 2L),
  awayScore = list(current = 1L)
)

statistics <- list(statistics = list(list(
  period = "ALL",
  groups = list(list(
    groupName = "Match overview",
    statisticsItems = list(list(
      name = "Expected goals", key = "expectedGoals",
      home = "1.45", away = "2.06", homeValue = 1.45, awayValue = 2.06
    ))
  ))
)))

shotmap <- list(shotmap = list(list(
  id = 1L, isHome = TRUE, shotType = "goal", xg = 0.42,
  player = list(id = 10L, name = "Test Player")
)))

lineups <- list(
  confirmed = TRUE,
  home = list(
    formation = "4-3-3",
    players = list(list(
      player = list(id = 10L, name = "Test Player"),
      teamId = 329974L,
      substitute = FALSE,
      statistics = list(rating = 8.1, goals = 1L, expectedGoals = 0.42)
    ))
  ),
  away = list(players = list())
)

tables <- parse_event_payloads(
  list(
    event = list(event = event), statistics = statistics,
    shotmap = shotmap, lineups = lineups
  ),
  event_hint = event,
  event_id = 16718922L
)

stopifnot(nrow(tables$events) == 1L)
stopifnot(tables$events$has_xg[[1L]])
stopifnot(nrow(tables$team_statistics) == 1L)
stopifnot(tables$team_statistics$key[[1L]] == "expectedGoals")
stopifnot(tables$team_statistics$home_value[[1L]] == 1.45)
stopifnot(nrow(tables$shots) == 1L)
stopifnot(tables$shots$xg[[1L]] == 0.42)
stopifnot(nrow(tables$player_statistics) == 1L)
stopifnot(tables$player_statistics$statistics_rating[[1L]] == 8.1)
stopifnot(tables$player_statistics$statistics_expected_goals[[1L]] == 0.42)
stopifnot(extract_event_id("https://www.sofascore.com/match/x#id:16718922") == 16718922L)

message("Parser tests passed.")
