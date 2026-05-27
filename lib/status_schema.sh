#!/usr/bin/env bash

status_error_json() {
    local host="$1"
    local output="$2"
    local err_type="command_failed"
    local overall="ERROR"

    if [[ "$output" == *"Connection timed out"* || "$output" == *"Could not resolve hostname"* || "$output" == *"Connection refused"* || "$output" == *"No route to host"* || "$output" == *"Permission denied"* ]]; then
        err_type="ssh_failed"
        overall="UNREACHABLE"
    elif [[ "$output" == "NON_JSON_RAW_PAYLOAD:"* ]]; then
        err_type="raw_payload_not_json"
        output="${output#NON_JSON_RAW_PAYLOAD: }"
    fi

    jq -cn --arg host "$host" --arg overall "$overall" --arg err_type "$err_type" --arg message "${output%%$'\n'*}" '{schema_version:1,host:$host,reachable:false,overall_status:$overall,last_run:{date:"unknown",age_hours:-1,result:null,status:"UNKNOWN"},jobs:[],errors:[{type:$err_type,message:$message}]}'
}
