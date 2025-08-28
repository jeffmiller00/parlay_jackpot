# Parlay Jackpot Tracker

Static Jekyll site (no theme dependency) tracking weekly parlay legs and awards.

## Update Workflow
Edit `_data/weeks.yml` each week:
1. Set each player's `pick`, `odds` (optional), `status` (won|lost|pending).
2. Mark the voted worst pick with `worst: true`.
3. Update `total_potential` for that week.
4. Rebuild: `bundle exec jekyll serve` (dev) or `JEKYLL_ENV=production bundle exec jekyll build` (deploy).

Players are defined in `_config.yml` under `players:`.

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
