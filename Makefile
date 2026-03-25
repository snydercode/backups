SHELL := /usr/bin/env bash

.PHONY: install-email

install-email:
	bash hub/install-email-cron.sh
