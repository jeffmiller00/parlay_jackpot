# Jekyll plugin to automatically recalculate week totals before rendering.
# Runs the weeks_editor.rb recalc_all command each build/serve

module WeeksAutoUpdate
  SCRIPT_PATH = File.expand_path('../scripts/guess_bet_success.rb', __dir__)

  Jekyll::Hooks.register :site, :after_init do |site|
    if File.exist?(SCRIPT_PATH)
      puts '[auto_grade_bets] Guess the outcome via guess_bet_success.rb'
      system(RbConfig.ruby, SCRIPT_PATH)
    else
      warn '[auto_grade_bets] Script not found, skipping'
    end
  end
end
