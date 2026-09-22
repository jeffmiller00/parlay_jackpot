# Parlay Jackpot Tracker

Static Jekyll site (no theme dependency) tracking weekly parlay legs and awards.

## Weekly Workflow

Picks are collected in the Google Sheet (one tab per week, named `Week N 2026`),
then imported. Cloudflare Pages deploys on every push to `main`, so committing
the data file is all it takes to publish.

The importer reads the sheet's real tab list (from its xlsx export, since a
gviz request for a tab name that doesn't exist silently falls back to a
leftover hidden tab instead of erroring) and appends the next week on its own
the first time that week's tab shows up - nobody has to remember to run
`--new-week`. `--new-week` still exists as a manual override, for example to
force-add a week ahead of its tab appearing.

```bash
# pull whatever picks are in the sheet; auto-adds the next week if its tab now exists
bundle exec ruby scripts/import_picks.rb

# force-add the next week even if the sheet doesn't have its tab yet
bundle exec ruby scripts/import_picks.rb --new-week

# after Monday Night Football, grade the week
bundle exec ruby scripts/grade_picks.rb
```

Both take `--week N` and `--dry-run`. Neither ever overwrites a pick that has
already been graded.

Two scheduled workflows do this unattended and commit the result:
`import-picks.yml` (daily, plus a Thursday pre-kickoff sweep) and
`grade-picks.yml` (Tuesday morning). Both can be run on demand from the Actions
tab. Grading needs an `OPENAI_KEY` repository secret, and only grades weeks
that exist in `_data/weeks.yml`, so it still depends on a week having been
imported (automatically or otherwise) first.

Still done by hand in `_data/weeks.yml`:

- `worst: true` and `worst_rationale` for the voted worst pick.
- `total_potential` for the week.

Players are defined in `_config.yml` under `players:`. The importer matches the
sheet's `Friend` column against those names and fails loudly if the sheet has a
name the site does not know about, so a new player cannot be silently dropped.

## Awards
- Most Correct Picks (wins)
- Most Incorrect Picks (losses)
- Most Worst Pick Votes (worst: true)
- Placeholder: Biggest Longshot Hit (add logic later)

## Google Analytics
Put your GA4 Measurement ID in `_config.yml` at `google_analytics`. Script loads only when `JEKYLL_ENV=production`.

## Local Dev
```bash
bundle install
bundle exec jekyll serve --livereload
```
Visit http://localhost:4000

## Future Enhancements
- ROI / bankroll tracking per player.
- Per-player detail pages.
- JSON export page for data.
- Graphs of cumulative performance.

## License
MIT
