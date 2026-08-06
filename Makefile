SHELL := /usr/bin/env bash

.PHONY: help status deploy schedule jobs check-jobs test weekly-check

help:
	@echo "Targets:"
	@echo "  make status        # human fleet status"
	@echo "  make deploy        # deploy runtime to all hosts"
	@echo "  make schedule      # install schedules on all hosts"
	@echo "  make jobs          # regenerate jobs.txt from the fleet config"
	@echo "  make check-jobs    # fail if jobs.txt is stale vs the fleet config"
	@echo "  make test          # run the weekly-check gate fixture tests"
	@echo "  make weekly-check  # weekly health gate, verdict only (no side effects)"

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

weekly-check:
	bash bin/weekly-check.sh --check-only
