#!/usr/bin/env zsh
set -euo pipefail

frequency="${1:-daily}"
if [[ "$frequency" != "daily" && "$frequency" != "weekly" ]]; then
  echo "Usage: ./install_daily_job.sh [daily|weekly]" >&2
  exit 2
fi

project_dir="${0:A:h}"
source_plist="$project_dir/com.sofascore-college.scraper.plist.template"
launch_agents_dir="$HOME/Library/LaunchAgents"
target_plist="$launch_agents_dir/com.sofascore-college.scraper.plist"
label="com.sofascore-college.scraper"
user_id="$(id -u)"
rscript_path="$(command -v Rscript)"

mkdir -p "$project_dir/logs" "$launch_agents_dir"

if [[ -f "$target_plist" ]]; then
  backup_path="$target_plist.backup.$(date +%Y%m%dT%H%M%S)"
  cp "$target_plist" "$backup_path"
  echo "Backed up the existing LaunchAgent to $backup_path"
  launchctl bootout "gui/$user_id" "$target_plist" 2>/dev/null || true
fi

cp "$source_plist" "$target_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $rscript_path" "$target_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:1 $project_dir/sofascore_college_scraper.R" "$target_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:3 $project_dir/data" "$target_plist"
/usr/libexec/PlistBuddy -c "Set :WorkingDirectory $project_dir" "$target_plist"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath $project_dir/logs/scraper.stdout.log" "$target_plist"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath $project_dir/logs/scraper.stderr.log" "$target_plist"
if [[ "$frequency" == "daily" ]]; then
  /usr/libexec/PlistBuddy -c "Delete :StartCalendarInterval:Weekday" "$target_plist"
fi

plutil -lint "$target_plist"
launchctl bootstrap "gui/$user_id" "$target_plist"

echo "Installed and loaded $label"
if [[ "$frequency" == "daily" ]]; then
  echo "It will run daily at 6:15 AM local time. Logs: $project_dir/logs"
else
  echo "It will run every Monday at 6:15 AM local time. Logs: $project_dir/logs"
fi
