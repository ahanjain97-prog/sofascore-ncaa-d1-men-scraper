#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
scraper="$project_dir/sofascore_college_scraper.R"
output_dir="$project_dir/data"

run_r_scraper() {
  exec Rscript "$scraper" \
    --output "$output_dir" \
    --division 1 \
    --gender men \
    "$@"
}

usage() {
  cat <<'EOF'
Usage:
  ./run_scraper.sh update [extra scraper options]
  ./run_scraper.sh date YYYY-MM-DD [extra scraper options]
  ./run_scraper.sh range YYYY-MM-DD YYYY-MM-DD [extra scraper options]

Modes:
  update  Resume the current Division I men's season through today.
  date    Scrape completed matches on one date.
  range   Scrape completed matches from the first date through the second.

Examples:
  ./run_scraper.sh update
  ./run_scraper.sh date 2026-08-31
  ./run_scraper.sh range 2026-08-01 2026-08-31
EOF
}

if ! command -v Rscript >/dev/null 2>&1; then
  echo "Rscript was not found. Install R 4.2 or newer first." >&2
  exit 1
fi

mode="${1:-}"
if [[ -z "$mode" || "$mode" == "-h" || "$mode" == "--help" ]]; then
  usage
  [[ -n "$mode" ]] && exit 0
  exit 2
fi
shift

case "$mode" in
  update)
    run_r_scraper "$@"
    ;;
  date)
    if [[ $# -lt 1 ]]; then
      echo "The date mode requires YYYY-MM-DD." >&2
      usage >&2
      exit 2
    fi
    selected_date="$1"
    shift
    run_r_scraper --start-date "$selected_date" --end-date "$selected_date" "$@"
    ;;
  range)
    if [[ $# -lt 2 ]]; then
      echo "The range mode requires START_DATE and END_DATE." >&2
      usage >&2
      exit 2
    fi
    start_date="$1"
    end_date="$2"
    shift 2
    run_r_scraper --start-date "$start_date" --end-date "$end_date" "$@"
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    usage >&2
    exit 2
    ;;
esac
