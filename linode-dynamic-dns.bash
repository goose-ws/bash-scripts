#!/usr/bin/env bash

#############################
##         Issues          ##
#############################
# If you experience any issues, please let me know here:
# https://github.com/goose-ws/bash-scripts
# These scripts are purely a passion project of convenience for myself, so pull requests welcome :)

#############################
##          About          ##
#############################
# This script will update a DNS record via Linode's DNS manager. Main use case is keeping a dynamic
# DNS record updated.

#############################
##        Changelog        ##
#############################
# 2024-01-27
# Improved some sanity checks and logic for escape scenarioes
# Added support for when a container has multiple networks attached (Multiple IP addresses)
# Updated the logic for sending Telegram messages to make sure the bot can authenticate to each channel
# Added support for super groups, silent messages (See updated .env file)
# Added support for sending error messages via telegram (See updated .env file)
# Initial commit, more or less a total rewrite

#############################
##       Installation      ##
#############################
# 1. Download the script .bash file somewhere safe
# 2. Download the script .env file somewhere safe
# 3. Edit the .env file to your liking
# 4. Set the script to run on an hourly cron job, or whatever your preference is

#############################
##      Sanity checks      ##
#############################
if ! [ -e "/bin/bash" ]; then
    echo "This script requires Bash"
    exit 255
fi
if [[ -z "${BASH_VERSINFO[0]}" || "${BASH_VERSINFO[0]}" -lt "4" ]]; then
    echo "This script requires Bash version 4 or greater"
    exit 255
fi
depArr=("awk" "curl" "md5sum" "printf" "rm")
depFail="0"
for i in "${depArr[@]}"; do
    if [[ "${i:0:1}" == "/" ]]; then
        if ! [[ -e "${i}" ]]; then
            echo "${i}\\tnot found"
            depFail="1"
        fi
    else
        if ! command -v "${i}" > /dev/null 2>&1; then
            echo "${i}\\tnot found"
            depFail="1"
        fi
    fi
done
if [[ "${depFail}" -eq "1" ]]; then
    echo "Dependency check failed"
    exit 255
fi
realPath="$(realpath "${0}")"
scriptName="$(basename "${0}")"
lockFile="${realPath%/*}/.${scriptName}.lock"
# URL of where the most updated version of the script is
updateURL="https://raw.githubusercontent.com/goose-ws/bash-scripts/main/linode-dynamic-dns.bash"
# For ease of printing messages
lineBreak="$(printf "\r\n\r\n")"

#############################
##         Lockfile        ##
#############################
if [[ -e "${lockFile}" ]]; then
    if kill -s 0 "$(<"${lockFile}")" > /dev/null 2>&1; then
        echo "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   [1] Lockfile present, exiting"
        exit 0
    else
        echo "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   [1] Removing stale lockfile for PID $(<"${lockFile}")"
    fi
fi
echo "${$}" > "${lockFile}"

#############################
##    Standard Functions   ##
#############################
function printOutput {
case "${1}" in
    0) logLevel="[reqrd]";; # Required
    1) logLevel="[error]";; # Errors
    2) logLevel="[info] ";; # Informational
    3) logLevel="[verb] ";; # Verbose
esac
if [[ "${1}" -le "${outputVerbosity}" ]]; then
    echo "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   ${logLevel} ${2}"
fi
}

function removeLock {
if rm -f "${lockFile}"; then
    printOutput "3" "Lockfile removed"
else
    printOutput "1" "Unable to remove lockfile"
fi
}

function badExit {
removeLock
if [[ -z "${2}" ]]; then
    printOutput "0" "Received signal: ${1}"
    exit "255"
else
    if [[ "${telegramErrorMessages}" =~ ^(yes|true)$ ]]; then
        sendTelegramMessage "Error code ${1} received: ${2}" "${telegramErrorChannel}"
    fi
    printOutput "1" "${2}"
    exit "${1}"
fi
}

function cleanExit {
removeLock
exit 0
}

function sendTelegramMessage {
# Message to send should be passed as function positional parameter #1
# We can pass an "Admin channel" as positional parameter #2 for the case of sending error messages
# Let's check to make sure our messaging credentials are valid
skipTelegram="0"
telegramOutput="$(curl -skL "https://api.telegram.org/bot${telegramBotId}/getMe" 2>&1)"
curlExitCode="${?}"
if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl to Telegram to check Bot ID returned a non-zero exit code: ${curlExitCode}"
    skipTelegram="1"
elif [[ -z "${telegramOutput}" ]]; then
    printOutput "1" "Curl to Telegram to check Bot ID returned an empty string"
    skipTelegram="1"
else
    printOutput "3" "Curl exit code and null output checks passed"
fi
if [[ "${skipTelegram}" -eq "0" ]]; then
    if ! [[ "$(jq -M -r ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
        printOutput "1" "Telegram bot API check failed"
    else
        printOutput "2" "Telegram bot API key authenticated: $(jq -M -r ".result.username" <<<"${telegramOutput}")"
        for chanId in "${telegramChannelId[@]}"; do
            if [[ -n "${2}" ]]; then
                chanId="${2}"
            fi
            telegramOutput="$(curl -skL "https://api.telegram.org/bot${telegramBotId}/getChat?chat_id=${telegramChannelId}")"
            curlExitCode="${?}"
            if [[ "${curlExitCode}" -ne "0" ]]; then
                printOutput "1" "Curl to Telegram to check channel returned a non-zero exit code: ${curlExitCode}"
            elif [[ -z "${telegramOutput}" ]]; then
                printOutput "1" "Curl to Telegram to check channel returned an empty string"
            else
                printOutput "3" "Curl exit code and null output checks passed"
            fi
            if [[ "$(jq -M -r ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
                printOutput "2" "Telegram channel authenticated: $(jq -M -r ".result.title" <<<"${telegramOutput}")"
                telegramOutput="$(curl -skL --data-urlencode "text=${1}" "https://api.telegram.org/bot${telegramBotId}/sendMessage?chat_id=${chanId}&parse_mode=html" 2>&1)"
                curlExitCode="${?}"
                if [[ "${curlExitCode}" -ne "0" ]]; then
                    printOutput "1" "Curl to Telegram returned a non-zero exit code: ${curlExitCode}"
                elif [[ -z "${telegramOutput}" ]]; then
                    printOutput "1" "Curl to Telegram to send message returned an empty string"
                else
                    printOutput "3" "Curl exit code and null output checks passed"
                    # Check to make sure Telegram returned a true value for ok
                    if ! [[ "$(jq -M -r ".ok" <<<"${telegramOutput}")" == "true" ]]; then
                        printOutput "1" "Failed to send Telegram message:"
                        printOutput "1" ""
                        printOutput "1" "$(jq . <<<"${telegramOutput}")"
                        printOutput "1" ""
                    else
                        printOutput "2" "Telegram message sent successfully"
                    fi
                fi
            else
                printOutput "1" "Telegram channel check failed"
            fi
            if [[ -n "${2}" ]]; then
                break
            fi
        done
    fi
fi
}

function callCurl {
# URL to call should be $1
curlOutput="$(curl -skL -H "Authorization: Bearer ${apiKey}" "${1}" 2>&1)"
curlExitCode="${?}"
if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    while read i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    badExit "1" "Bad curl output"
fi
}

#############################
##     Unique Functions    ##
#############################

#############################
##       Signal Traps      ##
#############################
trap "badExit SIGINT" INT
trap "badExit SIGQUIT" QUIT
trap "badExit SIGKILL" KILL

#############################
##  Positional parameters  ##
#############################
# We can run the positional parameter options without worrying about lockFile
case "${1,,}" in
    "-h"|"--help")
        echo "-h  --help      Displays this help message"
        echo ""
        echo "-u  --update    Self update to the most recent version"
        exit 0
    ;;
    "-u"|"--Update")
        oldStartLine="0"
        while read -r i; do
            if [[ "${i}" == "##        Changelog        ##" ]]; then
                oldStartLine="1"
            elif [[ "${oldStartLine}" -eq "1" ]]; then
                oldStartLine="2"
            elif [[ "${oldStartLine}" -eq "2" ]]; then
                oldStartLine="${i}"
                break
            fi
        done < "${0}"
        if curl -skL "${updateURL}" -o "${0}"; then
            if chmod +x "${0}"; then
                printOutput "1" "Update complete"
                newStartLine="0"
                while read -r i; do
                    if [[ "${newStartLine}" -eq "2" ]]; then
                        if [[ "${i}" == "${oldStartLine}" ]]; then
                            break
                        fi
                        if [[ "${i:2:1}" =~ ^[0-9]$ ]]; then
                            changelogArr+=(" ${i#\#}")
                        else
                            changelogArr+=("  - ${i#\#}")
                        fi
                    elif [[ "${newStartLine}" -eq "1" ]]; then
                        newStartLine="2"
                    elif [[ "${i}" == "##        Changelog        ##" ]]; then
                        newStartLine="1"
                    fi
                done < <(curl -skL "${updateURL}")

                printOutput "1"  "Changelog:"
                for i in "${changelogArr[@]}"; do
                    printOutput "1"  "${i}"
                done
                cleanExit
            else
                badExit "2" "Update downloaded, but unable to \`chmod +x\`"
            fi
        else
            badExit "3" "Unable to download Update"
        fi
    ;;
esac

#############################
##   Initiate .env file    ##
#############################
if [[ -e "${realPath%/*}/${scriptName%.bash}.env" ]]; then
    source "${realPath%/*}/${scriptName%.bash}.env"
else
    badExit "4" "Error: \"${realPath%/*}/${scriptName%.bash}.env\" does not appear to exist"
fi
varFail="0"
# Standard checks
if ! [[ "${updateCheck,,}" =~ ^(yes|no|true|false)$ ]]; then
    echo "Option to check for updates not valid. Assuming no."
    updateCheck="No"
fi
if ! [[ "${outputVerbosity}" =~ ^[1-3]$ ]]; then
    echo "Invalid output verbosity defined. Assuming level 1 (Errors only)"
    outputVerbosity="1"
fi

# Config specific checks
if ! [[ "${apiKey}" =~ ^[[:alnum:]]+$ ]]; then
    printOutput "1" "API key appears to be invalid (Characters other than letters/numbers)"
    varFail="1"
fi
if [[ "${#recordNames[@]}" -eq "0" ]]; then
    printOutput "1" "No DNS records are set"
    varFail="1"
else
    for i in "${recordNames[@]}"; do
        if ! host "${i}" > /dev/null 2>&1; then
            printOutput "1" "${i} does not appear to be a valid DNS record (Did you not create it yet?)"
            varFail="1"
        fi
    done
fi

# Quit if failures
if [[ "${varFail}" -eq "1" ]]; then
    badExit "5" "Please fix above errors"
fi

#############################
##       Update check      ##
#############################
if [[ "${updateCheck,,}" =~ ^(yes|true)$ ]]; then
    newest="$(curl -skL "${updateURL}" | md5sum | awk '{print $1}')"
    current="$(md5sum "${0}" | awk '{print $1}')"
    if ! [[ "${newest}" == "${current}" ]]; then
        # Although it's not an error, we should always be allowed to print this message if update checks are allowed, so giving it priority 1
        printOutput "1" "A newer version is available"
        # If our ${TERM} is dumb, we're probably running via cron, and should push a message to Telegram, if allowed
        if [[ "${TERM,,}" == "dumb" ]]; then
            if [[ "${telegramErrorMessages}" =~ ^(yes|true)$ ]]; then
                sendTelegramMessage "An updated version of \"${0##*/}\" is available" "${telegramErrorChannel}"
            fi
        fi
    else
        printOutput "3" "No new updates available"
    fi
fi

#############################
##         Payload         ##
#############################
# First thing's first, do we have internet?
printOutput "2" "Verifying internet connectivity"
if ! ping -w 5 -c 1 "api.linode.com" > /dev/null 2>&1; then
    # It appears not
    badExit "6" "Internet appears to be offline"
else
    printOutput "3" "Internet connectivity verified"
fi

# Get our addresses
v4addr="$(curl -skL4 "https://icanhazip.com" 2>&1)"
if [[ -n "${v4addr}" ]]; then
    printOutput "3" "Detected assigned IPv4 address: ${v4addr}"
else
    printOutput "3" "No assigned IPv4 address detected"
fi

v6addr="$(curl -skL6 "https://icanhazip.com" 2>&1)"
if [[ -n "${v6addr}" ]]; then
    printOutput "3" "Detected assigned IPv6 address: ${v6addr}"
else
    printOutput "3" "No assigned IPv6 address detected"
fi

if [[ -z "${v4addr}" && -z "${v6addr}" ]]; then
    badExit "7" "Unable to determine local IPv4 and IPv6 address (Is https://icanhazip.com down?)"
fi

# Get the available domains
callCurl "https://api.linode.com/v4/domains/"
if jq -e . >/dev/null 2>&1 <<<"${curlOutput}"; then
    if [[ "$(jq " .errors[].reason" <<<"${curlOutput}" > /dev/null 2>&1)" == "\"Invalid Token\"" ]]; then
        badExit "8" "Access denied using API key"
    fi
    itemCount="$(jq ".results" <<<"${curlOutput}")"
    if ! [[ "${itemCount}" =~ ^[[:digit:]]+$ ]]; then
        badExit "9" "Item count does not appear to be a number: ${itemCount}"
    elif [[ "${itemCount}" -eq "0" ]]; then
        badExit "10" "Failed to retrieve any domains from Linode DNS manager (Have you added any?)"
    else
        declare -A domains
        while read i; do
            id="${i%% *}"
            dom="${i#${id} }"
            domains[${id}]="${dom}"
        done < <(jq -M -r ".data | .[] | \"\(.id) \(.domain)\"" <<<"${curlOutput}")
    fi
fi

for i in "${recordNames[@]}"; do
    printOutput "2" "Processing: ${i}"
    # Start by figuring out which domain we're working with
    for ii in "${!domains[@]}"; do
        iiEscaped="${domains[${ii}]//\./\\.}"
        if [[ "${i}" =~ ^.*\.${iiEscaped} ]]; then
            printOutput "2" "Matched ${i} to parent domain ${domains[${ii}]}"
            printOutput "3" "Domain ID: ${ii}"
            break
        fi
    done
    # We have the ID of the domain we need, now let's get the record ID for it
    callCurl "https://api.linode.com/v4/domains/${ii}/records/"
    # Set this to a different variable so we can preserve it
    recordsOutput="${curlOutput}"
    searchName="${i%.${domains[${ii}]}}"
    unset aRecords aaaaRecords
    readarray -t aRecords < <(jq -M -r " .data[] | select((.name == \"${searchName}\") and (.type == \"A\")) | .id" <<<"${recordsOutput}")
    readarray -t aaaaRecords < <(jq -M -r " .data[] | select((.name == \"${searchName}\") and (.type == \"AAAA\")) | .id" <<<"${recordsOutput}")
    if [[ "$(( ${#aRecords[@]} + ${#aaaaRecords[@]} ))" -eq "0" ]]; then
        badExit "11" "No A or AAAA records detected"
    fi
    if [[ "${#aRecords[@]}" -gt "1" ]]; then
        badExit "12" "Found multiple A record(s) (${#aRecords[@]} matches, ID's: ${aRecords[*]})"
    fi
    if [[ "${#aaaaRecords[@]}" -gt "1" ]]; then
        badExit "13" "Found multiple AAAA record(s) (${#aaaaRecords[@]} matches, ID's: ${aaaaRecords[*]})"
    fi
    # Update our IPv4 record, if our v4 address and our v4 record is not empty
    if [[ -n "${v4addr}" && -n "${aRecords[0]}" ]]; then
        # Using an array here as a cheap way of making sure we only ended up with one target
        unset targetAddr
        readarray -t targetAddr < <(jq -M -r ".data[] | select(.id == ${aRecords[0]}) | .target" <<<"${recordsOutput}")
        if [[ "${#targetAddr[@]}" -gt "1" ]]; then
            badExit "14" "Matched too many target addresses"
        else
            printOutput "2" "Existing target address: ${targetAddr[0]}"
            printOutput "3" "Record ID: ${aRecords[0]}"
        fi
        if [[ "${targetAddr[0]}" == "${v4addr}" ]]; then
            # Our addresses match, we can break this loop
            printOutput "2" "Assigned IPv4 address matches DNS record, skipping"
        else
            # If we've made it this far, our addresses do not match
            printOutput "2" "Assigned IPv4 address does not match DNS record, issuing update"
            # Get the rest of the data we need to generate the request
            # name
            targetName="$(jq -M -r ".data[] | select(.id == ${aRecords[0]}) | .name" <<<"${recordsOutput}")"
            # priority
            targetPriority="$(jq -M -r ".data[] | select(.id == ${aRecords[0]}) | .priority" <<<"${recordsOutput}")"
            # weight
            targetWeight="$(jq -M -r ".data[] | select(.id == ${aRecords[0]}) | .weight" <<<"${recordsOutput}")"
            # port
            targetPort="$(jq -M -r ".data[] | select(.id == ${aRecords[0]}) | .port" <<<"${recordsOutput}")"
            # service
            targetService="$(jq -M -r ".data[] | select(.id == ${aRecords[0]}) | .service" <<<"${recordsOutput}")"
            # protocol
            targetProtocol="$(jq -M -r ".data[] | select(.id == ${aRecords[0]}) | .protocol" <<<"${recordsOutput}")"
            # ttl_sec
            targetTtl="$(jq -M -r ".data[] | select(.id == ${aRecords[0]}) | .ttl_sec" <<<"${recordsOutput}")"
            # tag
            targetTag="$(jq -M -r ".data[] | select(.id == ${aRecords[0]}) | .tag" <<<"${recordsOutput}")"
            # Send a request to update the record
            updateRequest="$(curl -skL -H "Content-Type: application/json" -H "Authorization: Bearer ${apiKey}" \
            -X PUT -d "{
            \"type\": \"A\",
            \"name\": \"${targetName}\",
            \"target\": \"${v4addr}\",
            \"priority\": ${targetPriority},
            \"weight\": ${targetWeight},
            \"port\": ${targetPort},
            \"service\": ${targetService},
            \"protocol\": ${targetProtocol},
            \"ttl_sec\": ${targetTtl},
            \"tag\": ${targetTag}
            }" "https://api.linode.com/v4/domains/${ii}/records/${aRecords[0]}" 2>&1)"
            curlExitCode="${?}"
            if [[ "${curlExitCode}" -ne "0" ]]; then
                printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
                while read i; do
                    printOutput "1" "Output: ${i}"
                done <<<"${curlOutput}"
                badExit "15" "Bad curl output"
            fi
            if [[ "$(jq -M -r ".data[] | select(.id == ${aRecords[0]}) | .target" <<<"${curlOutput}")" == "${targetAddr[0]}" ]]; then
                # Our call was issued successfully, sleep for 1 second then check the record
                sleep 1
                oldTargetAddr="${targetAddr[0]}"
                unset targetAddr
                callCurl "https://api.linode.com/v4/domains/${ii}/records/${aRecords[0]}"
                readarray -t targetAddr < <(jq -M -r ".target" <<<"${curlOutput}")
                if [[ "${#targetAddr[@]}" -gt "1" ]]; then
                    badExit "16" "Matched too many target addresses"
                fi
                if [[ "${targetAddr[0]}" == "${v4addr}" ]]; then
                    printOutput "2" "A record for ${targetName}.${domains[${ii}]} successfully updated from ${oldTargetAddr} to ${targetAddr[0]}"
                    msgArr+=("A record for ${targetName}.${domains[${ii}]} successfully updated from ${oldTargetAddr} to ${targetAddr[0]}")
                else
                    printOutput "1" "A record for ${targetName}.${domains[${ii}]} failed to update from ${oldTargetAddr} to ${targetAddr[0]}"
                    msgArr+=("A record for ${targetName}.${domains[${ii}]} failed to update from ${oldTargetAddr} to ${targetAddr[0]}")
                fi
            fi
        fi
    else
        printOutput "2" "Skipping IPv4"
    fi
    if [[ -n "${v6addr}" && -n "${aaaaRecords[0]}" ]]; then
        # Using an array here as a cheap way of making sure we only ended up with one target
        unset targetAddr
        readarray -t targetAddr < <(jq -M -r ".data[] | select(.id == ${aaaaRecords[0]}) | .target" <<<"${recordsOutput}")
        if [[ "${#targetAddr[@]}" -gt "1" ]]; then
            badExit "17" "Matched too many target addresses"
        else
            printOutput "3" "[ID: ${aaaaRecords[0]}] Target address: ${targetAddr[0]}"
        fi
        if [[ "${targetAddr[0]}" == "${v4addr}" ]]; then
            # Our addresses match, we can break this loop
            printOutput "2" "Assigned IPv6 address matches DNS record, skipping"
        else
            # If we've made it this far, our addresses do not match
            printOutput "2" "Assigned IPv6 address does not match DNS record, issuing update"
            # Get the rest of the data we need to generate the request
            # name
            targetName="$(jq -M -r ".data[] | select(.id == ${aaaaRecords[0]}) | .name" <<<"${recordsOutput}")"
            # priority
            targetPriority="$(jq -M -r ".data[] | select(.id == ${aaaaRecords[0]}) | .priority" <<<"${recordsOutput}")"
            # weight
            targetWeight="$(jq -M -r ".data[] | select(.id == ${aaaaRecords[0]}) | .weight" <<<"${recordsOutput}")"
            # port
            targetPort="$(jq -M -r ".data[] | select(.id == ${aaaaRecords[0]}) | .port" <<<"${recordsOutput}")"
            # service
            targetService="$(jq -M -r ".data[] | select(.id == ${aaaaRecords[0]}) | .service" <<<"${recordsOutput}")"
            # protocol
            targetProtocol="$(jq -M -r ".data[] | select(.id == ${aaaaRecords[0]}) | .protocol" <<<"${recordsOutput}")"
            # ttl_sec
            targetTtl="$(jq -M -r ".data[] | select(.id == ${aaaaRecords[0]}) | .ttl_sec" <<<"${recordsOutput}")"
            # tag
            targetTag="$(jq -M -r ".data[] | select(.id == ${aaaaRecords[0]}) | .tag" <<<"${recordsOutput}")"
            # Send a request to update the record
            updateRequest="$(curl -skL -H "Content-Type: application/json" -H "Authorization: Bearer ${apiKey}" \
            -X PUT -d "{
            \"type\": \"AAAA\",
            \"name\": \"${targetName}\",
            \"target\": \"${v4addr}\",
            \"priority\": ${targetPriority},
            \"weight\": ${targetWeight},
            \"port\": ${targetPort},
            \"service\": ${targetService},
            \"protocol\": ${targetProtocol},
            \"ttl_sec\": ${targetTtl},
            \"tag\": ${targetTag}
            }" "https://api.linode.com/v4/domains/${ii}/records/${aaaaRecords[0]}" 2>&1)"
            curlExitCode="${?}"
            if [[ "${curlExitCode}" -ne "0" ]]; then
                printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
                while read i; do
                    printOutput "1" "Output: ${i}"
                done <<<"${curlOutput}"
                badExit "18" "Bad curl output"
            fi
            if [[ "$(jq -M -r ".data[] | select(.id == ${aaaaRecords[0]}) | .target" <<<"${curlOutput}")" == "${targetAddr[0]}" ]]; then
                # Our call was issued successfully, sleep for 1 second then check the record
                sleep 1
                oldTargetAddr="${targetAddr[0]}"
                unset targetAddr
                callCurl "https://api.linode.com/v4/domains/${ii}/records/${aaaaRecords[0]}"
                readarray -t targetAddr < <(jq -M -r ".target" <<<"${curlOutput}")
                if [[ "${#targetAddr[@]}" -gt "1" ]]; then
                    badExit "19" "Matched too many target addresses"
                fi
                if [[ "${targetAddr[0]}" == "${v4addr}" ]]; then
                    printOutput "2" "A record for ${targetName}.${domains[${ii}]} successfully updated from ${oldTargetAddr} to ${targetAddr[0]}"
                    msgArr+=("A record for ${targetName}.${domains[${ii}]} successfully updated from ${oldTargetAddr} to ${targetAddr[0]}")
                else
                    printOutput "1" "A record for ${targetName}.${domains[${ii}]} failed to update from ${oldTargetAddr} to ${targetAddr[0]}"
                    msgArr+=("A record for ${targetName}.${domains[${ii}]} failed to update from ${oldTargetAddr} to ${targetAddr[0]}")
                fi
            fi
        fi
    else
        printOutput "2" "Skipping IPv6"
    fi
done

# Send Telegram message here
if [[ -n "${telegramBotId}" && -n "${telegramChannelId[0]}" && -n "${msgArr[@]}" ]]; then
    sendTelegramMessage "${msgArr[@]}"
fi

#############################
##       End of file       ##
#############################
cleanExit
