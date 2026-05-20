SHELL := /usr/bin/env bash

.PHONY: help status deploy schedule

help:
	@echo "Targets:"
	@echo "  make status  # human fleet status"
	@echo "  make deploy  # deploy runtime to all hosts"
	@echo "  make schedule  # install schedules on all hosts"
	@echo ""
	@echo "Archived email scripts: archive/check-and-email.sh, archive/install-email-cron.sh"

status:
	bash bin/status-all.sh

deploy:
	bash bin/deploy-all.sh

schedule:
	bash bin/schedule-all.sh
