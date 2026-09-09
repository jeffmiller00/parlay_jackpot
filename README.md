# Parlay Jackpot Tracker

Static Jekyll site (no theme dependency) tracking weekly parlay legs and awards.

## Weekly Workflow

Picks are collected in the Google Sheet (one tab per week, named `Week N 2026`),
then imported. Cloudflare Pages deploys on every push to `main`, so committing
the data file is all it takes to publish.

```bash
# start a new week and pull whatever picks are in the sheet
bundle exec ruby scripts/import_picks.rb --new-week

# re-run any time during the week to pick up late entries (idempotent)
bundle exec ruby scripts/import_picks.rb

# after Monday Night Football, grade the week
bundle exec ruby scripts/grade_picks.rb
```

Both take `--week N` and `--dry-run`. Neither ever overwrites a pick that has
already been graded.

Two scheduled workflows do this unattended and commit the result:
`import-picks.yml` (daily, plus a Thursday pre-kickoff sweep) and
`grade-picks.yml` (Tuesday morning). Both can be run on demand from the Actions
tab. Grading needs an `OPENAI_KEY` repository secret.

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
