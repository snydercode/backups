#!/usr/bin/env bash

is_valid_before_date() {
    local date_value="$1"
    [[ "$date_value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}
