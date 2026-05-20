SHELL := /usr/bin/env bash

.PHONY: help status-all status-all-raw deploy-all schedule-all

help:
	@echo "Targets:"
	@echo "  make status-all      # human fleet status"
	@echo "  make status-all-raw  # machine key=value status"
	@echo "  make deploy-all      # deploy backup runtime to all hosts"
	@echo "  make schedule-all    # install schedules on all hosts"
	@echo ""
	@echo "Archived email scripts: archive/check-and-email.sh, archive/install-email-cron.sh"

status-all:
	bash bin/status-all.sh

status-all-raw:
	bash bin/status-all.sh --raw

deploy-all:
	bash bin/deploy-all.sh

schedule-all:
	bash bin/schedule-all.sh
