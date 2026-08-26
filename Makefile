SHELL := /usr/bin/env bash

.PHONY: help status deploy schedule jobs check-jobs test check report

help:
	@echo "Targets:"
	@echo "  make status        # human fleet status"
	@echo "  make deploy        # deploy runtime to all hosts"
	@echo "  make schedule      # install schedules on all hosts"
	@echo "  make jobs          # regenerate jobs.txt from the fleet config"
	@echo "  make check-jobs    # fail if jobs.txt is stale vs the fleet config"
	@echo "  make test          # run the gate, triage-prompt and status-schema tests"
	@echo "  make check         # daily health gate, verdict only (no side effects)"
	@echo "  make report        # weekly report, printed instead of emailed"

status:
	bash bin/status-all.sh

deploy:
	bash bin/deploy-all.sh

schedule:
	bash bin/schedule-all.sh

jobs:
	python3 bin/render-jobs-from-fleet.py

check-jobs:
	python3 bin/render-jobs-from-fleet.py --check

test:
	bash test/gate-test.sh
	bash test/prompt-test.sh
	bash test/status-schema-test.sh

check:
	bash bin/check.sh --check-only

report:
	bash bin/report.sh --dry-run
