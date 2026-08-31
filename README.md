# SofaScore NCAA Division I men's soccer scraper

This repository downloads every completed NCAA Division I men's soccer match exposed by SofaScore and turns the responses into cumulative, analysis-ready CSV tables. It collects match and team statistics, team and shot xG, player ratings and statistics, incidents, momentum, average positions, best players, managers, and the original endpoint JSON.

The friendly runner and GitHub workflow are locked to **Division I men**. The underlying R script has broader NCAA feeds in its catalog, but they are used only when someone explicitly overrides the defaults.

> SofaScore does not publish or guarantee these endpoints. They can change, and some matches do not have every data type. Use the scraper and resulting data in accordance with SofaScore's terms and applicable data rights.

## Quick start on a computer

Requirements:

- R 4.2 or newer
- Google Chrome or Chromium
- macOS or Linux for the friendly shell commands; the R script itself is cross-platform

Download or clone this repository, open a terminal in its folder, and install the R packages once:

```bash
Rscript install_dependencies.R
chmod +x run_scraper.sh
```

Then choose a run mode:

```bash
# Easiest daily command: scrape yesterday's completed D1 men's matches
Rscript scrape_daily.R

# Or choose today so far or an exact America/Chicago calendar date
Rscript scrape_daily.R today
Rscript scrape_daily.R 2026-08-31

# Resume the current season through today (best for recurring runs)
./run_scraper.sh update

# One calendar date
./run_scraper.sh date 2026-08-31

# An inclusive date range
./run_scraper.sh range 2026-08-01 2026-08-31
```

`scrape_daily.R` is the simple boss-facing entry point. With no argument it scrapes yesterday, which is recommended because those matches should all be complete. It is locked to NCAA Division I men, can be launched from any working directory, reuses cached matches, and updates the cumulative files under `data/tables/`.

On its first `update` run, the full scraper backfills from August 1 of the current college season through today. Later runs read `data/state.json`, revisit recent dates, retry transiently missing endpoints, and add newly completed games. Cached successful responses are not downloaded again. Explicit `date` and `range` runs do not alter the recurring scheduler's progress date.

For every command-line option:

```bash
Rscript sofascore_college_scraper.R --help
```

Useful advanced examples:

```bash
# Validate one SofaScore match or URL
Rscript sofascore_college_scraper.R --event 16718922
Rscript sofascore_college_scraper.R \
  --event 'https://www.sofascore.com/football/match/example#id:16718922'

# Discover a date without fetching match-detail endpoints
./run_scraper.sh date 2026-08-31 --dry-run

# Re-download a match if SofaScore corrected its data
Rscript sofascore_college_scraper.R --event 16718922 --force
```

## Run it from GitHub with a self-hosted runner

The included workflow, `.github/workflows/scrape.yml`, lets a repository collaborator launch and download scrapes from the GitHub interface. It deliberately targets a private **self-hosted macOS or Linux runner** labeled `sofascore-scraper`.

GitHub-hosted Ubuntu runners were tested end to end, but SofaScore returned HTTP 403 to their datacenter IP even through headless Chrome. A self-hosted runner uses the normal network connection of your office or computer, where the scraper has been validated successfully.

Set up the runner once:

1. In the repository, open **Settings → Actions → Runners → New self-hosted runner**.
2. Select macOS or Linux and follow GitHub's generated download and registration commands on the machine that will run the scraper.
3. Add the custom runner label `sofascore-scraper` when prompted, or add it from the runner's settings afterward.
4. Configure the runner as a service so it starts automatically with the machine. The machine must be on and connected when a job is scheduled.

GitHub's official setup guide is [Adding self-hosted runners](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners). **Security warning:** GitHub recommends private repositories for self-hosted runners because repository workflows execute on that machine. Since this repository is public, the safer option is the local scheduler below. If you do attach a self-hosted runner, use a dedicated machine/account, restrict repository write access to trusted collaborators, and do not add pull-request triggers to this workflow.

In GitHub:

1. Open **Actions**.
2. Select **Scrape NCAA D1 men's soccer**.
3. Click **Run workflow**.
4. Choose `update`, `single_date`, or `date_range` and fill in the relevant date fields.
5. When the job finishes, download the `ncaa-d1-men-tables-...` artifact from the workflow run's **Artifacts** section.

When completed games are available, each artifact contains all cumulative CSV tables, the run index, and `state.json` when recurring state exists. A genuinely empty date finishes successfully without an artifact. Artifacts are retained for 30 days. The larger raw-response archive is retained in an Actions cache so recurring jobs can resume without re-scraping the full season.

### Daily or weekly GitHub schedule

Scheduled runs are **off by default** until the self-hosted runner is ready. The available schedule is 6:15 AM America/Chicago.

To turn scheduling on:

1. Open **Settings → Secrets and variables → Actions → Variables**.
2. Create a repository variable named `SCRAPE_FREQUENCY`.
3. Set its value to `daily` or `weekly`.

Daily mode runs every day; weekly mode runs every Monday. Set the value to `off` or delete the variable to stop scheduled scraping while keeping manual runs available.

The first workflow run can take substantially longer because it must build the season cache. GitHub schedules are best-effort and can start later than the exact scheduled minute.

## Output

Data is written under `data/`:

```text
data/
├── discovery/             # Cached tournament/date event lists
├── raw/<event_id>/        # Original endpoint JSON and request manifest
├── fragments/             # Per-match parsed tables for resumable runs
├── runs/                  # Games discovered and their selection status
├── tables/                # Cumulative analysis-ready CSV files
└── state.json             # Progress and transient retry queue
```

The cumulative tables are:

| File | Contents |
|---|---|
| `events.csv` | One row per match: teams, score, time, competition, venue, status, and data-availability flags |
| `team_statistics.csv` | Match-by-match team statistics in long form, with both team IDs/names repeated on every row; `key == "expectedGoals"` is team xG |
| `shots.csv` | One row per shot, including shot xG, player, outcome, situation, body part, and coordinates when supplied |
| `player_statistics.csv` | One row per player per match, including `statistics_rating` and every other supplied statistic |
| `incidents.csv` | Goals, cards, substitutions, VAR, and period events |
| `momentum.csv` | SofaScore attack-momentum graph points |
| `average_positions.csv` | Player average positions and point counts |
| `best_players.csv` | Team leaders, match leaderboard, and player of the match |
| `managers.csv` | Home and away managers |

The team table contains **individual match statistics, not season aggregates**. Every row has `home_team_id`, `home_team_name`, `away_team_id`, and `away_team_name`. A row is identified by `event_id`, `period`, `group_name`, and `key`, with `home_value` and `away_value` holding those teams' values. SofaScore sometimes repeats the same statistic in multiple display groups, so use `unique()` when selecting a key such as xG.

Example analysis in R:

```r
library(data.table)

team_stats <- fread("data/tables/team_statistics.csv")
shots <- fread("data/tables/shots.csv")
players <- fread("data/tables/player_statistics.csv")

# One home/away xG pair per match
team_xg <- unique(
  team_stats[
    period == "ALL" & key == "expectedGoals",
    .(
      event_id, home_team_name, away_team_name,
      home_xg = home_value, away_xg = away_value
    )
  ]
)

# Shot-level xG totals by team side
shot_xg <- shots[, .(shot_xg = sum(xg, na.rm = TRUE)), by = .(event_id, side)]

# Player ratings by match
ratings <- players[
  !is.na(statistics_rating),
  .(event_id, side, player_id, player_name, statistics_rating)
]
```

## Schedule it locally on a Mac

The portable LaunchAgent installer detects the clone location and installed `Rscript` path automatically:

```bash
# Every day at 6:15 AM local time
./install_daily_job.sh daily

# Or every Monday at 6:15 AM local time
./install_daily_job.sh weekly
```

Logs are written to `logs/scraper.stdout.log` and `logs/scraper.stderr.log`. Running the installer again backs up and replaces the previous LaunchAgent definition.

## Reliability and validation

- The completed August 1–31, 2026 Division I men's validation backfill found 320 matches.
- Detailed team statistics, xG, shots, and player ratings were published for 298 of those matches. SofaScore returned 404 for those detail endpoints on the other 22.
- Each match's `raw/<event_id>/_manifest.json` records success, missing-data, and error status for every endpoint. Missing source data is not silently fabricated.
- Raw JSON and parsed fragments are saved as the run proceeds, so interrupted runs are resumable.
- HTTP 429 and server errors use bounded retries with exponential backoff.
- Chrome is used as a fallback because SofaScore often rejects plain HTTP requests with 403 responses.

Run the parser tests with:

```bash
Rscript tests/test_parsers.R
```
