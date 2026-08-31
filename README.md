# NCAA Division I men's soccer scraper

This repository downloads completed NCAA Division I men's matches from SofaScore. One run collects match results, team statistics and xG, shots, player ratings and statistics, incidents, momentum, average positions, best players, managers, and the original JSON.

The boss-facing commands are locked to **men's Division I**. Data is cumulative, so each run adds new matches and reuses everything already downloaded.

> SofaScore's endpoints are undocumented and may change. Some matches do not have every detailed data type; the scraper records missing source data instead of inventing values.

## Set up once

Install:

- R 4.2 or newer
- Google Chrome or Chromium

Then open a terminal and run:

```bash
git clone https://github.com/ahanjain97-prog/sofascore-ncaa-d1-men-scraper.git
cd sofascore-ncaa-d1-men-scraper
Rscript install_dependencies.R
```

## Get the full current season through today

Run this once after setup, or whenever you want a complete refresh:

```bash
Rscript sofascore_college_scraper.R
```

On a new installation, this collects every completed men's D1 match from August 1 of the current college season through today. Later runs revisit recent dates, add newly completed games, and retry data that SofaScore published late.

## Scrape yesterday every morning

This is the normal daily command:

```bash
Rscript scrape_daily.R
```

It automatically uses yesterday's America/Chicago date and collects both match and player data. To choose another day:

```bash
Rscript scrape_daily.R today
Rscript scrape_daily.R 2026-08-31
```

Today's unfinished matches are skipped and can be collected by running the command again later.

## Automate it on a Mac

To run the updater every day at 6:15 AM local time:

```bash
./install_daily_job.sh daily
```

The Mac must be awake and connected to the internet. Logs are written to:

```text
logs/scraper.stdout.log
logs/scraper.stderr.log
```

## Results

The main files are cumulative and live under `data/tables/`:

| File | What it contains |
|---|---|
| `events.csv` | One row per match with date, teams, final score, competition, venue, status, and source URL |
| `team_statistics.csv` | Match-by-match team statistics and xG; every row includes both team IDs and names |
| `player_statistics.csv` | One row per player per match with team, position, minutes, rating, goals, assists, xG, xA, passing, and every other supplied statistic |
| `shots.csv` | Every supplied shot with player, team, outcome, coordinates, xG, and xGOT |
| `best_players.csv` | Leaders, player of the match, and match leaderboard data |
| `incidents.csv` | Goals, cards, substitutions, VAR, and period events |
| `momentum.csv` | Attack-momentum graph points |
| `average_positions.csv` | Player average positions |
| `managers.csv` | Home and away managers |

In `team_statistics.csv`, `home_value` belongs to `home_team_name` and `away_value` belongs to `away_team_name`. Team xG rows have `period == "ALL"` and `key == "expectedGoals"`.

In `player_statistics.csv`, the match rating is `statistics_rating`. Players without a rating are retained because they may be unused substitutes or SofaScore may not have supplied a rating.

Raw responses and resumable per-match files are retained under `data/raw/` and `data/fragments/`.

## Useful recovery commands

```bash
# Refresh one exact date
Rscript scrape_daily.R 2026-08-31

# Refresh one match by SofaScore event ID
Rscript sofascore_college_scraper.R --event 16718922 --force

# Check the parsers without scraping
Rscript tests/test_parsers.R
```
