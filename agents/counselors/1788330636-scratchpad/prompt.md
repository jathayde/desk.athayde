# Review Request

## Question
Review Phase 2 step 5 of Investment Copilot (uncommitted on top of commit 73becc2; `git status --porcelain` lists the files): the two remaining write tools (annotate_trade appends dated, signed notes; add_watchlist_item), the watchlist screen with its propose link and drop, tax lots on sell proposals with a default lot method (names unverified), the watchlist in the morning brief's frame and prompt, the nightly trail job that stores a tighten-stop suggestion per position, and that suggestion in the end-of-day brief and get_portfolio. Under 600 words.

## Files
@app/models/agent/tools/annotate_trade.rb @app/models/agent/tools/add_watchlist_item.rb @app/models/watchlist_item.rb @app/models/trade.rb @app/controllers/watchlist_items_controller.rb @app/views/watchlist_items/index.html.erb @app/models/tax_lots.rb @app/models/proposals.rb @app/controllers/proposals_controller.rb @app/views/proposals/show.html.erb @app/views/proposals/new.html.erb @app/models/stop_collar/trail.rb @app/jobs/stop_collar/trail_job.rb @app/models/agent/context.rb @app/models/agent/prompts/system.md.erb @app/models/agent/prompts/morning_brief.md.erb @app/models/brief.rb @app/views/brief_mailer/brief.text.erb @app/views/brief_mailer/_eod.text.erb @app/models/agent/tools/get_portfolio.rb @config/recurring.yml
Specs: @spec/models/watchlist_and_annotations_spec.rb @spec/requests/watchlist_items_spec.rb @spec/jobs/stop_collar/trail_job_spec.rb
Design: @docs/phase-2-plan.md §0.11, §0.12, §4, §7, §8; PRD §5.4 6a and §5.4.1 (trailing behaviour) in @docs/artifacts/investment-copilot-prd.md.

## Instructions
Independent and critical. Is the trail maths right and its "tighter than the working stop" rule honest (a suggestion never below the stop, never above the price)? Can the annotate tool overwrite or be used to inject text into a brief or a page? Is the watchlist's uniqueness and drop path sound, and does the propose link carry text safely? Are the tax lots honest about what the journal knows (plug legs, unknown dates) and is the default lot method the right posture given PRD 6a? Anything a scheduled run could now write? Say what must change before commit versus later.
