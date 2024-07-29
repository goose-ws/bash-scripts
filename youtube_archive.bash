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
# A description of what the scrip does goes here

#############################
##        Changelog        ##
#############################
# 2023-10-15
# Initial commit

#############################
##       Installation      ##
#############################
# 1. Download the script .bash file somewhere safe
# 2. Download the script .env file somewhere safe
# 3. Edit the .env file to your liking
# 4. Create a video config directory
#    So if you name the script "ytdlp-plex-mirror.bash"
#    Then in the same folder you would create the directory "ytdlp-plex-mirror.sources"
#    And within that ".sources" directory, you would place a "source.env" file for each source
#    you want to add. The files can be named anything, as long as they end in ".env"
#    Here is an example source.env:
# 5. Set the script to run on an hourly cron job, or whatever your preference is

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

# Dependency check
depArr=("awk" "case" "chmod" "continue" "convert" "curl" "date" "declare" "do" "done" "echo" "elif" "exit" "for" "function" "grep" "identify" "if" "kill" "local" "md5sum" "printf" "readarray" "return" "rm" "select" "sleep" "source" "sqlite3" "then" "trap" "unset" "while" "yt-dlp" "yq")
depFail="0"
for i in "${depArr[@]}"; do
    if [[ "${i:0:1}" == "/" ]]; then
        if ! [[ -e "${i}" ]]; then
            echo "Missing dependency [${i}]"
            depFail="1"
        fi
    else
        if ! command -v "${i}" > /dev/null 2>&1; then
            echo "Missing dependency [${i}]"
            depFail="1"
        fi
    fi
done
if [[ "${depFail}" -eq "1" ]]; then
    echo "Dependency check failed"
    exit 255
fi

# Local variables
realPath="$(realpath "${0}")"
scriptName="$(basename "${0}")"
lockFile="${realPath%/*}/.${scriptName}.lock"
# URL of where the most updated version of the script is
updateURL="https://raw.githubusercontent.com/goose-ws/bash-scripts/main/ytdlp-plex-mirror.bash"
# For ease of printing messages
lineBreak="$(printf "\r\n\r\n")"
scriptStart="$(($(date +%s%N)/1000000))"

#############################
##         Lockfile        ##
#############################
if [[ -e "${lockFile}" ]]; then
    if kill -s 0 "$(<"${lockFile}")" > /dev/null 2>&1; then
        echo "Lockfile present, refusing to run"
        exit 0
    else
        echo "Removing stale lockfile for PID $(<"${lockFile}")"
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
    2) logLevel="[warn] ";; # Warnings
    3) logLevel="[info] ";; # Informational
    4) logLevel="[verb] ";; # Verbose
    5) logLevel="[DEBUG]";; # Debug
esac
if [[ "${1}" -le "${outputVerbosity}" ]]; then
    echo "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   ${logLevel} ${2}"
fi
if [[ "${1}" -le "1" ]]; then
    errorArr+=("${2}")
fi
}

function removeLock {
if rm -f "${lockFile}"; then
    if ! [[ "${1}" == "silent" ]]; then
        printOutput "4" "Lockfile removed"
    fi
else
    printOutput "1" "Unable to remove lockfile"
fi
}

function badExit {
apiCount
if ! rm -rf "${tmpDir}"; then
    printOutput "1" "Failed to clean up tmp folder [${tmpDir}]"
fi
removeLock
if [[ -z "${2}" ]]; then
    printOutput "0" "Received signal: ${1}"
    exit "255"
else
    if [[ "${telegramErrorMessages,,}" =~ ^(yes|true)$ ]]; then
        sendTelegramMessage "<b>${0##*/}</b>${lineBreak}${lineBreak}Error Code ${1}:${lineBreak}${2}" "${telegramErrorChannel}"
    fi
    printOutput "1" "${2} [Error code: ${1}]"
    exit "${1}"
fi
}

function cleanExit {
if [[ "${1}" == "silent" ]]; then
    rm -rf "${tmpDir}"
    removeLock "--silent"
else
    apiCount
    if ! rm -rf "${tmpDir}"; then
        printOutput "1" "Failed to clean up tmp folder [${tmpDir}]"
    fi
    if [[ "${#errorArr[@]}" -ne "0" ]]; then
        printOutput "1" "=== Error Log ==="
        for i in "${errorArr[@]}"; do
            printOutput "1" "${i}"
        done
    fi
    printOutput "3" "Script executed in $(timeDiff "${scriptStart}")"
    removeLock
fi
exit 0
}

function callCurl {
# URL to call should be ${1}
if [[ -z "${1}" ]]; then
    badExit "1" "No input URL provided for GET"
fi
curlOutput="$(curl -skL -m 15 "${1}" 2>&1)"
curlExitCode="${?}"
if [[ "${curlExitCode}" -eq "28" ]]; then
    printOutput "2" "Curl timed out, waiting 10 seconds then trying again"
    sleep 10
    curlOutput="$(curl -skL "${1}" 2>&1)"
    curlExitCode="${?}"
fi
if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    while read -r i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    badExit "2" "Bad curl output"
fi
}

function timeDiff {
# Start time should be passed as ${1}
# End time can be passed as ${2}
# If no end time is defined, will use the time the function is called as the end time
# Time should be provided via: startTime="$(($(date +%s%N)/1000000))"
if [[ -z "${1}" ]]; then
    echo "No start time provided"
    return 1
else
    startTime="${1}"
fi
if [[ -z "${2}" ]]; then
    endTime="$(($(date +%s%N)/1000000))"
fi

if [[ "$(( ${endTime:0:10} - ${startTime:0:10} ))" -le "5" ]]; then
    printf "%sms\n" "$(( endTime - startTime ))"
else
    local T="$(( ${endTime:0:10} - ${startTime:0:10} ))"
    local D="$((T/60/60/24))"
    local H="$((T/60/60%24))"
    local M="$((T/60%60))"
    local S="$((T%60))"
    (( D > 0 )) && printf '%dd' "${D}"
    (( H > 0 )) && printf '%dh' "${H}"
    (( M > 0 )) && printf '%dm' "${M}"
    (( D > 0 || H > 0 || M > 0 ))
    printf '%ds\n' "${S}"
fi
}

function msToTime {
if [[ "${1}" -le "5" ]]; then
    printf "%sms\n" "$(( endTime - startTime ))"
else
    local T="$(( ${1} / 1000 ))"
    local D="$((T/60/60/24))"
    local H="$((T/60/60%24))"
    local M="$((T/60%60))"
    local S="$((T%60))"
    (( D > 0 )) && printf '%dd' "${D}"
    (( H > 0 )) && printf '%dh' "${H}"
    (( M > 0 )) && printf '%dm' "${M}"
    (( D > 0 || H > 0 || M > 0 ))
    printf '%ds\n' "${S}"
fi
}

function sendTelegramMessage {
# Message to send should be passed as function positional parameter #1
# We can pass an "Admin channel" as positional parameter #2 for the case of sending error messages
callCurl "https://api.telegram.org/bot${telegramBotId}/getMe"
if ! [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
    printOutput "1" "Telegram bot API check failed"
else
    printOutput "4" "Telegram bot API key authenticated [$(yq -p json ".result.username" <<<"${curlOutput}")]"
    for chanId in "${telegramChannelId[@]}"; do
        if [[ -n "${2}" ]]; then
            chanId="${2}"
        fi
        callCurl "https://api.telegram.org/bot${telegramBotId}/getChat?chat_id=${telegramChannelId}"
        if [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
            printOutput "4" "Telegram channel authenticated [$(yq -p json ".result.title" <<<"${curlOutput}")]"
            msgEncoded="$(rawurlencode "${1}")"
            callCurl"https://api.telegram.org/bot${telegramBotId}/sendMessage?chat_id=${chanId}&parse_mode=html&text=${msgEncoded}"
            # Check to make sure Telegram returned a true value for ok
            if ! [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
                printOutput "1" "Failed to send Telegram message:"
                printOutput "1" ""
                while read -r i; do
                    printOutput "1" "${i}"
                done < <(yq -p json "." <<<"${curlOutput}")
                printOutput "1" ""
            else
                printOutput "4" "Telegram message sent successfully"
            fi
        else
            printOutput "1" "Telegram channel check failed"
        fi
        if [[ -n "${2}" ]]; then
            break
        fi
    done
fi
}

#############################
##     Unique Functions    ##
#############################
function getContainerIp {
if ! [[ "${1}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
    # Container name should be passed as positional paramter #1
    # It will return the variable ${containerIp} if successful
    printOutput "3" "Attempting to automatically determine IP address for: ${1}"

    if [[ "${1%%:*}" == "docker" ]]; then
        unset containerNetworking
        while read -r i; do
            if [[ -n "${i}" ]]; then
                containerNetworking+=("${i}")
            fi
        done < <(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "${1#*:}")
        if [[ "${#containerNetworking[@]}" -eq "0" ]]; then
            printOutput "3" "No network type defined. Checking to see if networking is through another container."
            containerIp="$(docker inspect "${1#*:}" | yq -p json ".[].HostConfig.NetworkMode")"
            printOutput "3" "Host config network mode: ${containerIp}"
            if [[ "${containerIp%%:*}" == "container" ]]; then
                printOutput "3" "Networking routed through another container. Retrieving IP address."
                containerIp="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${containerIp#container:}")"
            else
                printOutput "1" "Unable to determine networking type"
                unset containerIp
            fi
        else
            printOutput "3" "Container is utilizing ${#containerNetworking[@]} network type(s): ${containerNetworking[*]}"
            for i in "${containerNetworking[@]}"; do
                if [[ "${i}" == "host" ]]; then
                    printOutput "3" "Networking type: ${i}"
                    containerIp="127.0.0.1"
                else
                    printOutput "3" "Networking type: ${i}"
                    containerIp="$(docker inspect "${1#*:}" | yq -p json ".[] | .NetworkSettings.Networks.${i}.IPAddress")"
                    if [[ "${containerIp}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
                        break
                    fi
                fi
            done
        fi
    else
        badExit "3" "Unknown container daemon: ${1%%:*}"
    fi
else
    containerIp="${1}"
fi

if [[ -z "${containerIp}" ]] || ! [[ "${containerIp}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
    badExit "4" "Unable to determine IP address via networking mode: ${i}"
else
    printOutput "3" "Container IP address: ${containerIp}"
fi
}

function apiCount {
# Notify of how many API calls were made
if [[ "${apiCallsYouTube}" -ne "0" ]]; then
    printOutput "3" "Made [${apiCallsYouTube}] API calls to YouTube"
fi
if [[ "${apiCallsLemnos}" -ne "0" ]]; then
    printOutput "3" "Made [${apiCallsLemnos}] API calls to LemnosLife"
fi
}

function rawurlencode {
local string="${1}"
local strlen="${#string}"
local encoded=""
local pos c o

for (( pos=0 ; pos<strlen ; pos++ )); do
    c="${string:$pos:1}"
    case "${c}" in
        [-_.~a-zA-Z0-9] ) o="${c}" ;;
        * ) printf -v o '%%%02x' "'${c}"
    esac
    encoded+="${o}"
done
echo "${encoded}"
}

function callCurlPost {
# URL to call should be ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "No input URL provided for POST"
    return 1
fi
# ${2} could be --data-binary and ${3} could be an image to be uploaded
if [[ "${2}" == "--data-binary" ]]; then
    curlOutput="$(curl -skL -X POST "${1}" --data-binary "${3}" 2>&1)"
else
    curlOutput="$(curl -skL -X POST "${1}" 2>&1)"
fi
curlExitCode="${?}"
if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    while read -r i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    return 1
fi
}

function callCurlDownload {
# URL to call should be $1, output should be $2
if [[ -z "${1}" ]]; then
    badExit "5" "No input URL provided for download"
elif [[ -z "${2}" ]]; then
    badExit "6" "No output path provided for download"
fi
printOutput "5" "Issuing curl command [curl -skL -m 15 \"${1}\" -o \"${2}\"]"
curlOutput="$(curl -skL -m 15 "${1}" -o "${2}" 2>&1)"
curlExitCode="${?}"
if [[ "${curlExitCode}" -eq "28" ]]; then
    printOutput "2" "Curl download call returned exit code 28 -- Waiting 5 seconds and reattempting download"
    sleep 5
    curlOutput="$(curl -skL -m 15 "${1}" -o "${2}" 2>&1)"
    curlExitCode="${?}"
fi
if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl download call returned non-zero exit code ${curlExitCode}"
    while read -r i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    badExit "7" "Bad curl output"
fi
}

function callCurlPut {
# URL to call should be $1
if [[ -z "${1}" ]]; then
    badExit "8" "No input URL provided for PUT"
fi
printOutput "5" "Issuing curl command [curl -skL -X PUT \"${1}\"]"
curlOutput="$(curl -skL -X PUT "${1}" 2>&1)"
curlExitCode="${?}"
if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    while read -r i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    return 1
fi
}

function callCurlDelete {
# URL to call should be $1
if [[ -z "${1}" ]]; then
    badExit "9" "No input URL provided for DELETE"
fi
curlOutput="$(curl -skL -X DELETE "${1}" 2>&1)"
curlExitCode="${?}"
if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    while read -r i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    badExit "10" "Bad curl output"
fi
}

function randomSleep {
# ${1} is minumum seconds, ${2} is maximum
# If no min/max set, min=5 max=30
if [[ -z "${1}" ]]; then
    sleepTime="$(shuf -i 5-30 -n 1)"
else
    sleepTime="$(shuf -i "${1}"-"${2}" -n 1)"
fi
printOutput "4" "Pausing for ${sleepTime} seconds before continuing"
sleep "${sleepTime}"
}

function validateInterger {
# ${1} is the thing we want to validate
if [[ -z "${1}" ]]; then
    printOutput "1" "No data provided to validate interger"
elif [[ "${1}" =~ ^[0-9]+$ ]]; then
    true
elif ! [[ "${1}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Data [${1}] failed to validate as an interger"
    return 1
else
    badExit "11" "Impossible condition"
fi
}

function refreshLibrary {
# Issue a "Scan Library" command -- The desired library ID must be passed as ${1}
if [[ -z "${1}" ]]; then
    badExit "12" "No library ID passed to be scanned"
fi
printOutput "3" "Issuing a 'Scan Library' command to Plex for library ID [${1}]"
callCurl "${plexAdd}/library/sections/${1}/refresh?X-Plex-Token=${plexToken}"
}

function updateAristRatingKey {
# Channel ID should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "No channel ID passed for artist rating key update"
    return 1
fi
chanName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${1}';")"
if [[ -z "${chanName}" ]]; then
    printOutput "1" "Unable to retrieve channel name from database via channel ID [${1}]"
    return 1
fi
printOutput "3" "Retrieving rating key from Plex for artist [${chanName}] with channel ID [${1}]"
# Can we take the easy way out? Try to match the series by name
lookupMatch="0"
# Get a list of all the series in the video library
callCurl "${plexAdd}/library/sections/${audioLibraryId}/all?X-Plex-Token=${plexToken}"
# See if we can flatly match any of these via ${chanName}
artistRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select( .\"+@title\" == \"${chanName}\") | .\"+@ratingKey\"" <<<"${curlOutput}")"
if [[ -n "${artistRatingKey}" ]]; then
    # We could!
    # Validate it
    if ! validateInterger "${artistRatingKey}"; then
        printOutput "1" "Artist rating key [${artistRatingKey}] failed to validate -- Unable to continue"
        return 1
    fi
    
    printOutput "5" "Located artist rating key [${artistRatingKey}] via most efficient lookup method"
    dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_channel WHERE CHANNEL_ID = '${1}';")"
    if [[ "${dbCount}" -eq "0" ]]; then
        # It does not exist in the database, use an 'insert'
        if sqDb "INSERT INTO audio_rating_key_by_channel (RATING_KEY, CHANNEL_ID, UPDATED) VALUES (${artistRatingKey}, '${1}', $(date +%s));"; then
            printOutput "5" "Added artist rating key [${artistRatingKey}] to database"
        else
            badExit "13" "Adding artist rating key [${artistRatingKey}] to database failed"
        fi
    elif [[ "${dbCount}" -eq "1" ]]; then
        # It exists in the database, use an 'update'
        if sqDb "UPDATE audio_rating_key_by_channel SET RATING_KEY = ${artistRatingKey}, UPDATED = $(date +%s) WHERE CHANNEL_ID = '${1}';"; then
            printOutput "5" "Added artist rating key [${artistRatingKey}] to database"
        else
            badExit "14" "Adding artist rating key [${artistRatingKey}] to database failed"
        fi
    else
        badExit "15" "Database count for channel ID [${1}] in audio_rating_key_by_channel table returned greater than 1 -- Possible database corruption"
    fi
    lookupMatch="1"
else
    # We could not
    # Best way would be the first episode of the first season of the channel ID in question
    firstEpisode="$(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${1}' ORDER BY TIMESTAMP ASC LIMIT 1;")"
    # Having the year would help as we can skip series which do not have the first year season we want
    firstYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${firstEpisode}';")"
    # To do this, we need to find a matching episode by YT ID in Plex
    # The "lazy" way to do this is to only compare items which have the same first character as our channel name
    chanNameCompare="${chanName:0:1}"
    # Don't recycle old variable data
    unset plexTitleArr notSearchedArr
    # Extract a list of item titles from Plex, to an array
    readarray -t plexTitleArr <<<"$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@title\"" <<<"${curlOutput}")"
    for z in "${!plexTitleArr[@]}"; do
        # Get the first letter
        plexNameCompare="${plexTitleArr[${z}]:0:1}"
        # Compare it to the first letter of our series
        if [[ "${plexNameCompare^}" == "${chanNameCompare^}" ]]; then
            # The first characters match, get artist's rating key so we can investigate further
            artistRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select( .\"+@title\" == \"${plexTitleArr[${z}]}\") | .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -z "${artistRatingKey}" ]]; then
                printOutput "1" "Failed to retrieve rating key for [${plexTitleArr[${z}]}] -- Skipping series lookup"
                continue
            elif ! [[ "${artistRatingKey}" =~ ^[0-9]+$ ]]; then
                printOutput "1" "Rating key for [${plexTitleArr[${z}]}] returned non-interger [${artistRatingKey}] -- Skipping series lookup"
                continue
            fi
            # Get the rating key of a season that matches our video year
            callCurl "${plexAdd}/library/metadata/${artistRatingKey}/children?X-Plex-Token=${plexToken}"
            seasonRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@index\" == \"${firstYear}\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
            
            if ! validateInterger "${seasonRatingKey}"; then
                printOutput "1" "Variable seasonRatingKey [${seasonRatingKey}] failed to validate -- Unable to continue"
                return 1
            fi
            if [[ -n "${seasonRatingKey}" ]]; then
                callCurl "${plexAdd}/library/metadata/${seasonRatingKey}/children?X-Plex-Token=${plexToken}"
                # Get the YT ID from the file path of the first episode of the first season
                firstEpisodeId="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                firstEpisodeId="${firstEpisodeId%\]\.*}"
                firstEpisodeId="${firstEpisodeId##*\[}"
                if [[ -z "${firstEpisodeId}" ]]; then
                    printOutput "1" "Failed to isolite ID for first episode of [${plexTitleArr[${z}]}] season [${firstYear}] -- Skipping series lookup"
                    continue
                fi
                # We have now extracted the ID of the first episode of the first season. Compare it to ours, and hope for a match.
                if [[ "${firstEpisodeId}" == "${firstEpisode}" ]]; then
                    # We've matched!
                    lookupMatch="1"
                    printOutput "5" "Located artist rating key [${artistRatingKey}] via semi-efficient lookup method"
                    # While we're already here, grab the rating key for the individual episode/file
                    fileRatingKeyTmp="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
                    audioFileRatingKey["_${firstEpisode}"]="${fileRatingKeyTmp}"

                    # Add the artist rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_channel WHERE CHANNEL_ID = '${1}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # It does not exist in the database, use an 'insert'
                        if sqDb "INSERT INTO audio_rating_key_by_channel (RATING_KEY, CHANNEL_ID, UPDATED) VALUES (${artistRatingKey}, '${1}', $(date +%s));"; then
                            printOutput "5" "Added artist rating key [${artistRatingKey}] to database"
                        else
                            badExit "16" "Adding artist rating key [${artistRatingKey}] to database failed"
                        fi
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, use an 'update'
                        if sqDb "UPDATE audio_rating_key_by_channel SET RATING_KEY = ${artistRatingKey}, UPDATED = $(date +%s) WHERE CHANNEL_ID = '${1}';"; then
                            printOutput "5" "Added artist rating key [${artistRatingKey}] to database"
                        else
                            badExit "17" "Adding artist rating key [${artistRatingKey}] to database failed"
                        fi
                    else
                        badExit "18" "Database count for channel ID [${1}] in audio_rating_key_by_channel table returned greater than 1 -- Possible database corruption"
                    fi

                    # Add the artist's season rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_album WHERE ID = '${firstEpisode}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # It does not exist in the database, use an 'insert'
                        if sqDb "INSERT INTO audio_rating_key_by_album (RATING_KEY, ID, UPDATED) VALUES (${seasonRatingKey}, '${firstEpisode}', $(date +%s));"; then
                            printOutput "5" "Added season rating key [${seasonRatingKey}] to database"
                        else
                            badExit "19" "Adding season rating key [${seasonRatingKey}] to database failed"
                        fi
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, use an 'update'
                        if sqDb "UPDATE audio_rating_key_by_album SET RATING_KEY = ${artistRatingKey}, UPDATED = $(date +%s) WHERE ID = '${firstEpisode}';"; then
                            printOutput "5" "Added season rating key [${seasonRatingKey}] to database"
                        else
                            badExit "20" "Adding season rating key [${seasonRatingKey}] to database failed"
                        fi
                    else
                        badExit "21" "Database count for ID [${firstEpisode}] in audio_rating_key_by_album table returned greater than 1 -- Possible database corruption"
                    fi

                    # Add the artist's episode rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_item WHERE ID = ${fileRatingKeyTmp};")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # It does not exist in the database, use an 'insert'
                        if sqDb "INSERT INTO audio_rating_key_by_item (RATING_KEY, ID, UPDATED) VALUES ('${fileRatingKeyTmp}', '${firstEpisodeId}', $(date +%s));"; then
                            printOutput "5" "Added artist rating key [${fileRatingKeyTmp}] to database"
                        else
                            badExit "22" "Adding artist rating key [${fileRatingKeyTmp}] to database failed"
                        fi
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, use an 'update'
                        if sqDb "UPDATE audio_rating_key_by_item SET RATING_KEY = '${fileRatingKeyTmp}', UPDATED = $(date +%s) WHERE ID = '${firstEpisodeId}';"; then
                            printOutput "5" "Added artist rating key [${fileRatingKeyTmp}] to database"
                        else
                            badExit "23" "Adding artist rating key [${fileRatingKeyTmp}] to database failed"
                        fi
                    else
                        badExit "24" "Database count for artist ID [${fileRatingKeyTmp}] in audio_rating_key_by_item table returned greater than 1 -- Possible database corruption"
                    fi

                    # Break the loop
                    break
                fi
            fi
        else
            notSearchedArr+=("${z}")
        fi
    done

    # If we've gotten this far, and not matched anything, we should do an inefficient search with the leftover titles from the notSearchedArr[@]
    if [[ "${lookupMatch}" -eq "0" ]]; then
        # We may have some unwanted data from some other lookup for ${curlOutput}, so call that endpoint again
        callCurl "${plexAdd}/library/sections/${audioLibraryId}/all?X-Plex-Token=${plexToken}"
        for z in "${notSearchedArr[@]}"; do
            artistRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select( .\"+@title\" == \"${plexTitleArr[${z}]}\") | .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -n "${artistRatingKey}" ]]; then
                printOutput "5" "Attempting lookup with artist rating key [${artistRatingKey}]"
            else
                continue
            fi
            # Get the rating key of a season that matches our video year
            callCurl "${plexAdd}/library/metadata/${artistRatingKey}/children?X-Plex-Token=${plexToken}"
            seasonRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@index\" == \"${firstYear}\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
            printOutput "5" "Retrieved album rating key [${seasonRatingKey}]"
            if [[ -n "${seasonRatingKey}" ]]; then
                callCurl "${plexAdd}/library/metadata/${seasonRatingKey}/children?X-Plex-Token=${plexToken}"
                # Get the YT ID from the file path of the first episode of the first season
                firstEpisodeId="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                firstEpisodeId="${firstEpisodeId%\]\.*}"
                firstEpisodeId="${firstEpisodeId##*\[}"
                # We have now extracted the ID of the first episode of the first season. Compare it to ours, and pray for a match.
                if [[ "${firstEpisodeId}" == "${firstEpisode}" ]]; then
                    lookupMatch="1"
                    printOutput "5" "Located artist rating key [${artistRatingKey}] via least efficient lookup method"
                    fileRatingKeyTmp="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
                    audioFileRatingKey["_${firstEpisodeId}"]="${fileRatingKeyTmp}"

                    # Add the artist rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_channel WHERE CHANNEL_ID = '${1}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # It does not exist in the database, use an 'insert'
                        if sqDb "INSERT INTO audio_rating_key_by_channel (RATING_KEY, CHANNEL_ID, UPDATED) VALUES (${artistRatingKey}, '${1}', $(date +%s));"; then
                            printOutput "5" "Added artist rating key [${artistRatingKey}] to database"
                        else
                            badExit "25" "Adding artist rating key [${artistRatingKey}] to database failed"
                        fi
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, use an 'update'
                        if sqDb "UPDATE audio_rating_key_by_channel SET RATING_KEY = ${artistRatingKey}, UPDATED = $(date +%s) WHERE CHANNEL_ID = '${1}';"; then
                            printOutput "5" "Added artist rating key [${artistRatingKey}] to database"
                        else
                            badExit "26" "Adding artist rating key [${artistRatingKey}] to database failed"
                        fi
                    else
                        badExit "27" "Database count for channel ID [${1}] in audio_rating_key_by_channel table returned greater than 1 -- Possible database corruption"
                    fi

                    # Add the artist's season rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_album WHERE CHANNEL_ID = '${1}' AND YEAR = ${vidYear};")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # It does not exist in the database, use an 'insert'
                        if sqDb "INSERT INTO audio_rating_key_by_album (RATING_KEY, YEAR, CHANNEL_ID, UPDATED) VALUES (${seasonRatingKey}, ${vidYear}, '${1}', $(date +%s));"; then
                            printOutput "5" "Added season rating key [${seasonRatingKey}] to database"
                        else
                            badExit "28" "Adding season rating key [${seasonRatingKey}] to database failed"
                        fi
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, use an 'update'
                        if sqDb "UPDATE audio_rating_key_by_album SET RATING_KEY = ${artistRatingKey}, UPDATED = $(date +%s) WHERE CHANNEL_ID = '${1}' AND YEAR = ${vidYear};"; then
                            printOutput "5" "Added season rating key [${seasonRatingKey}] to database"
                        else
                            badExit "29" "Adding season rating key [${seasonRatingKey}] to database failed"
                        fi
                    else
                        badExit "30" "Database count for channel ID [${1}] in audio_rating_key_by_channel table returned greater than 1 -- Possible database corruption"
                    fi

                    # Add the artist's episode rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_item WHERE ID = '${fileRatingKeyTmp}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # It does not exist in the database, use an 'insert'
                        if sqDb "INSERT INTO audio_rating_key_by_item (RATING_KEY, ID, UPDATED) VALUES ('${fileRatingKeyTmp}', '${firstEpisodeId}', $(date +%s));"; then
                            printOutput "5" "Added artist rating key [${fileRatingKeyTmp}] to database"
                        else
                            badExit "31" "Adding artist rating key [${fileRatingKeyTmp}] to database failed"
                        fi
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, use an 'update'
                        if sqDb "UPDATE audio_rating_key_by_item SET RATING_KEY = '${fileRatingKeyTmp}', UPDATED = $(date +%s) WHERE ID = '${firstEpisodeId}';"; then
                            printOutput "5" "Added artist rating key [${fileRatingKeyTmp}] to database"
                        else
                            badExit "32" "Adding artist rating key [${fileRatingKeyTmp}] to database failed"
                        fi
                    else
                        badExit "33" "Database count for artist ID [${fileRatingKeyTmp}] in audio_rating_key_by_item table returned greater than 1 -- Possible database corruption"
                    fi

                fi
            fi
        done
    fi

    if [[ "${lookupMatch}" -eq "0" ]]; then
        printOutput "1" "Unable to locate rating key for series [${chanName}]"
    fi
fi
}

function assignTitle {
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a file ID please"
fi
if [[ -z "${titleById[_${1}]}" ]]; then
    titleById["_${1}"]="$(sqDb "SELECT TITLE FROM source_videos WHERE ID = '${1}';")"
fi
}

function getVideoFileRatingKey {
# File ID should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a file ID please"
    return 1
fi
if [[ -n "${videoFileRatingKey[_${1}]}" ]]; then
    # We already have it
    # Validate it
    if ! validateInterger "${videoFileRatingKey[_${1}]}"; then
        printOutput "1" "Variable videoFileRatingKey[_${1}] [${videoFileRatingKey[_${1}]}] failed to validate -- Unable to continue"
        return 1
    fi
    callCurl "${plexAdd}/library/metadata/${videoFileRatingKey[_${1}]}?X-Plex-Token=${plexToken}"
    verifyId="$(yq -p xml ".MediaContainer.Video.Media.Part.\"+@file\"" <<<"${curlOutput}")"
    verifyId="${verifyId%\]\.*}"
    verifyId="${verifyId##*\[}"
    if [[ "${verifyId}" == "${1}" ]]; then
        # We're good
        return 0
    fi
else
    # We don't have it. Maybe the database does?
    videoFileRatingKey["_${1}"]="$(sqDb "SELECT RATING_KEY FROM video_rating_key_by_item WHERE ID = '${1}';")"
    if [[ -n "${videoFileRatingKey[_${1}]}" ]]; then
        # Validate it
        if ! validateInterger "${videoFileRatingKey[_${1}]}"; then
            printOutput "1" "Variable videoFileRatingKey[_${1}] [${videoFileRatingKey[_${1}]}] failed to validate -- Unable to continue"
            return 1
        fi
        callCurl "${plexAdd}/library/metadata/${videoFileRatingKey[_${1}]}?X-Plex-Token=${plexToken}"
        verifyId="$(yq -p xml ".MediaContainer.Video.Media.Part.\"+@file\"" <<<"${curlOutput}")"
        verifyId="${verifyId%\]\.*}"
        verifyId="${verifyId##*\[}"
        if [[ "${verifyId}" == "${1}" ]]; then
            # We're good
            # Grab the title
            assignTitle "${1}"
            return 0
        fi
    fi
fi

# Get the channel ID of our file ID
local channelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${1}';")"
if [[ -z "${channelId}" ]]; then
    printOutput "1" "Unable to retrieve channel ID for file ID [${1}] -- Possible database corruption"
    return 1
fi
# Get the rating key for this series
local showRatingKey="$(sqDb "SELECT RATING_KEY FROM video_rating_key_by_channel WHERE CHANNEL_ID = '${channelId}';")"
if [[ -z "${showRatingKey}" ]]; then
    updateShowRatingKey "${channelId}"
    local showRatingKey="$(sqDb "SELECT RATING_KEY FROM video_rating_key_by_channel WHERE CHANNEL_ID = '${channelId}';")"
    if [[ -z "${showRatingKey}" ]]; then
        printOutput "1" "Unable to retrieve series rating key for channel ID [${channelId}]"
        return 1
    fi
fi
# Get the rating key for the season
local vidYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${1}';")"
if [[ -z "${vidYear}" ]]; then
    printOutput "1" "Unable to retrieve year for file ID [${1}] -- Possible database corruption"
    return 1
fi
local seasonRatingKey="$(sqDb "SELECT RATING_KEY FROM video_rating_key_by_season WHERE CHANNEL_ID = '${channelId}' AND YEAR = ${vidYear};")"
if [[ -z "${seasonRatingKey}" ]]; then
    updateSeasonRatingKey "${channelId}" "${vidYear}" "${showRatingKey}"
    local seasonRatingKey="$(sqDb "SELECT RATING_KEY FROM video_rating_key_by_season WHERE CHANNEL_ID = '${channelId}' AND YEAR = ${vidYear};")"
    if [[ -z "${seasonRatingKey}" ]]; then
        printOutput "1" "Unable to retrieve series rating key for channel ID [${channelId}] year [${vidYear}]"
        return 1
    fi
fi
# Get the rating key for the file ID
callCurl "${plexAdd}/library/metadata/${seasonRatingKey}/children/?X-Plex-Token=${plexToken}"
readarray -t fileRatingKeys < <(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
for fileRatingKeyTmp in "${fileRatingKeys[@]}"; do
    if ! validateInterger "${fileRatingKeyTmp}"; then
        printOutput "1" "Variable fileRatingKeyTmp [${fileRatingKeyTmp}] failed to validate -- Unable to continue"
        return 1
    fi
    local fileId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${fileRatingKeyTmp}\" ) .Media.Part.\"+@file\"" <<<"${curlOutput}")"
    local fileId="${fileId%\]\.*}"
    local fileId="${fileId##*\[}"
    if [[ "${fileId}" == "${1}" ]]; then
        # We've matched
        videoFileRatingKey["_${1}"]="${fileRatingKeyTmp}"
        # Grab the title
        assignTitle "${1}"
        # Load it into the database
        local dbCount="$(sqDb "SELECT COUNT(1) FROM video_rating_key_by_item WHERE RATING_KEY = ${fileRatingKeyTmp};")"
        if [[ "${dbCount}" -eq "1" ]]; then
            # Drop that outdated record
            sqDb "DELETE FROM video_rating_key_by_item WHERE RATING_KEY = ${fileRatingKeyTmp};"
        elif [[ "${dbCount}" -gt "1" ]]; then
            printOutput "1" "Received count [${dbCount}] from database -- Possibly corrupted"
            sqDb "DELETE FROM video_rating_key_by_item WHERE RATING_KEY = ${fileRatingKeyTmp};"
        else
            badExit "34" "Unexpected database count [${dbCount}] for file ID [${fileRatingKeyTmp}]"
        fi
        # Now we can insert
        if sqDb "INSERT INTO video_rating_key_by_item (RATING_KEY, ID, UPDATED) VALUES (${fileRatingKeyTmp}, '${1}', $(date +%s));"; then
            printOutput "5" "Added item rating key [${fileRatingKeyTmp}] to database"
        else
            badExit "35" "Adding item rating key [${fileRatingKeyTmp}] to database failed"
        fi
        break
    fi
done
}

function updateSeasonRatingKey {
# Channel ID is ${1}
# Season year is ${2}
# Show rating key is ${3}
callCurl "${plexAdd}/library/metadata/${3}/children/?X-Plex-Token=${plexToken}"
local seasonRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@index\" == \"${2}\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
if ! validateInterger "${seasonRatingKey}"; then
    printOutput "1" "Variable seasonRatingKey [${seasonRatingKey}] failed to validate -- Unable to continue"
    return 1
fi

# Add it to the database
local dbCount="$(sqDb "SELECT COUNT(1) FROM video_rating_key_by_season WHERE RATING_KEY = ${seasonRatingKey};")"
if [[ "${dbCount}" -eq "0" ]]; then
    # Expected output
    true
elif [[ "${dbCount}" -eq "1" ]]; then
    # Drop the stale rating key
    if ! sqDb "DELETE FROM video_rating_key_by_season WHERE RATING_KEY = ${seasonRatingKey};"; then
        badExit "36" "Failed to remove stale season rating key [${seasonRatingKey}] from video_rating_key_by_season -- Database likely corrupt"
    fi
else
    badExit "37" "Database count for rating key [${seasonRatingKey}] in video_rating_key_by_season table returned unexpected output [${dbCount}] -- Possible database corruption"
fi

# Insert
if sqDb "INSERT INTO video_rating_key_by_season (RATING_KEY, CHANNEL_ID, YEAR, UPDATED) VALUES (${seasonRatingKey}, '${1}', ${2}, $(date +%s));"; then
    printOutput "5" "Added season rating key [${seasonRatingKey}] year [${2}] to database"
else
    badExit "38" "Adding season rating key [${seasonRatingKey}] year [${2}] to database failed"
fi
}

function updateShowRatingKey {
# Channel ID should be passed as ${1}
if [[ -z "${1}" ]]; then
    badExit "39" "No channel ID passed for show rating key update"
fi
chanName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${1}';")"
printOutput "3" "Retrieving rating key from Plex for show [${chanName}] with channel ID [${1}]"
# Can we take the easy way out? Try to match the series by name
lookupMatch="0"
# Get a list of all the series in the video library
callCurl "${plexAdd}/library/sections/${videoLibraryId}/all?X-Plex-Token=${plexToken}"
# See if we can flatly match any of these via ${chanName}
showRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select( .\"+@title\" == \"${chanName}\") | .\"+@ratingKey\"" <<<"${curlOutput}")"
if [[ -n "${showRatingKey}" ]]; then
    # We could!
    printOutput "5" "Located show rating key [${showRatingKey}] via most efficient lookup method"
    dbCount="$(sqDb "SELECT COUNT(1) FROM video_rating_key_by_channel WHERE CHANNEL_ID = '${1}';")"
    if [[ "${dbCount}" -eq "0" ]]; then
        # Expected output
        true
    elif [[ "${dbCount}" -eq "1" ]]; then
        # Drop the stale rating key
        if ! sqDb "DELETE FROM video_rating_key_by_channel WHERE RATING_KEY = ${showRatingKey};"; then
            badExit "40" "Failed to remove stale series rating key [${showRatingKey}] from video_rating_key_by_channel -- Database likely corrupt"
        fi
    else
        badExit "41" "Database count for series rating key [${showRatingKey}] in video_rating_key_by_channel table returned unexpected output [${dbCount}] -- Possible database corruption"
    fi
    if sqDb "INSERT INTO video_rating_key_by_channel (RATING_KEY, CHANNEL_ID, UPDATED) VALUES (${showRatingKey}, '${1}', $(date +%s));"; then
        printOutput "5" "Added show rating key [${showRatingKey}] to database"
    else
        badExit "42" "Adding show rating key [${showRatingKey}] to database failed"
    fi
    lookupMatch="1"
else
    # We could not
    # Best way would be the first episode of the first season of the channel ID in question
    firstEpisode="$(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${1}' ORDER BY TIMESTAMP ASC LIMIT 1;")"
    # Having the year would help as we can skip series which do not have the first year season we want
    firstYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${firstEpisode}';")"
    # To do this, we need to find a matching episode by YT ID in Plex
    # The "lazy" way to do this is to only compare items which have the same first character as our channel name
    chanNameCompare="${chanName:0:1}"
    # Don't recycle old variable data
    unset plexTitleArr notSearchedArr
    # Extract a list of item titles from Plex, to an array
    readarray -t plexTitleArr <<<"$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@title\"" <<<"${curlOutput}")"
    for z in "${!plexTitleArr[@]}"; do
        # Get the first letter
        plexNameCompare="${plexTitleArr[${z}]:0:1}"
        # Compare it to the first letter of our series
        if [[ "${plexNameCompare^}" == "${chanNameCompare^}" ]]; then
            # The first characters match, get show's rating key so we can investigate further
            showRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select( .\"+@title\" == \"${plexTitleArr[${z}]}\") | .\"+@ratingKey\"" <<<"${curlOutput}")"
            if ! validateInterger "${showRatingKey}"; then
                printOutput "1" "Variable showRatingKey [${showRatingKey}] failed to validate -- Unable to continue"
                return 1
            fi
            # Get the rating key of a season that matches our video year
            callCurl "${plexAdd}/library/metadata/${showRatingKey}/children?X-Plex-Token=${plexToken}"
            seasonRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@index\" == \"${firstYear}\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
            if ! validateInterger "${seasonRatingKey}"; then
                printOutput "1" "Variable seasonRatingKey [${seasonRatingKey}] failed to validate -- Unable to continue"
                return 1
            fi
            if [[ -n "${seasonRatingKey}" ]]; then
                callCurl "${plexAdd}/library/metadata/${seasonRatingKey}/children?X-Plex-Token=${plexToken}"
                # Get the YT ID from the file path of the first episode of the first season
                firstEpisodeId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                firstEpisodeId="${firstEpisodeId%\]\.*}"
                firstEpisodeId="${firstEpisodeId##*\[}"
                if [[ -z "${firstEpisodeId}" ]]; then
                    printOutput "1" "Failed to isolite ID for first episode of [${plexTitleArr[${z}]}] season [${firstYear}] -- Skipping series lookup"
                    continue
                fi
                # We have now extracted the ID of the first episode of the first season. Compare it to ours, and hope for a match.
                if [[ "${firstEpisodeId}" == "${firstEpisode}" ]]; then
                    # We've matched!
                    lookupMatch="1"
                    printOutput "5" "Located show rating key [${showRatingKey}] via semi-efficient lookup method"
                    # While we're already here, grab the rating key for the individual episode/file
                    fileRatingKeyTmp="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
                    videoFileRatingKey["_${firstEpisodeId}"]="${fileRatingKeyTmp}"

                    # Add the show rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM video_rating_key_by_channel WHERE RATING_KEY = '${showRatingKey}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Expected output
                        true
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, delete the stale entry
                        if sqDb "DELETE FROM video_rating_key_by_channel WHERE RATING_KEY = ${showRatingKey};"; then
                            printOutput "5" "Removed stale rating key [${showRatingKey}] from video_rating_key_by_channel"
                        else
                            badExit "43" "Failed to remove stale rating key [${showRatingKey}] from video_rating_key_by_channel -- Possible database corruption"
                        fi
                        if sqDb "DELETE FROM video_rating_key_by_channel WHERE CHANNEL_ID = ${1};"; then
                            printOutput "5" "Removed stale rating keys containing channel ID [${1}] from video_rating_key_by_channel"
                        else
                            badExit "44" "Failed to remove stale rating keys containing channel ID [${1}] from video_rating_key_by_channel -- Possible database corruption"
                        fi
                    else
                        badExit "45" "Database count for rating key [${showRatingKey}] in video_rating_key_by_channel table returned greater than 1 -- Possible database corruption"
                    fi
                    # Insert
                    if sqDb "INSERT INTO video_rating_key_by_channel (RATING_KEY, CHANNEL_ID, UPDATED) VALUES (${showRatingKey}, '${1}', $(date +%s));"; then
                        printOutput "5" "Added series rating key [${showRatingKey}] to database"
                    else
                        badExit "46" "Adding series rating key [${showRatingKey}] to database failed"
                    fi
                    
                    # Add the season rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM video_rating_key_by_season WHERE RATING_KEY = '${seasonRatingKey}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Expected output
                        true
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, delete the stale entry
                        if sqDb "DELETE FROM video_rating_key_by_season WHERE RATING_KEY = ${seasonRatingKey};"; then
                            printOutput "5" "Removed stale rating key [${seasonRatingKey}] from video_rating_key_by_season"
                        else
                            badExit "47" "Failed to remove stale rating key [${seasonRatingKey}] from video_rating_key_by_season -- Possible database corruption"
                        fi
                        if sqDb "DELETE FROM video_rating_key_by_season WHERE CHANNEL_ID = ${1};"; then
                            printOutput "5" "Removed stale rating keys containing channel ID [${1}] from video_rating_key_by_season"
                        else
                            badExit "48" "Failed to remove stale rating keys containing channel ID [${1}] from video_rating_key_by_season -- Possible database corruption"
                        fi
                    else
                        badExit "49" "Database count for rating key [${seasonRatingKey}] in video_rating_key_by_season table returned greater than 1 -- Possible database corruption"
                    fi
                    # Insert
                    if sqDb "INSERT INTO video_rating_key_by_season (RATING_KEY, YEAR, CHANNEL_ID, UPDATED) VALUES (${seasonRatingKey}, ${vidYear}, '${1}', $(date +%s));"; then
                        printOutput "5" "Added season rating key [${seasonRatingKey}] to database"
                    else
                        badExit "50" "Adding season rating key [${seasonRatingKey}] to database failed"
                    fi
                    
                    # Add the show's episode rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM video_rating_key_by_item WHERE RATING_KEY = '${fileRatingKeyTmp}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Expected output
                        true
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, delete the stale entry
                        if sqDb "DELETE FROM video_rating_key_by_item WHERE RATING_KEY = ${fileRatingKeyTmp};"; then
                            printOutput "5" "Removed stale rating key [${fileRatingKeyTmp}] from video_rating_key_by_item"
                        else
                            badExit "51" "Failed to remove stale rating key [${fileRatingKeyTmp}] from video_rating_key_by_item -- Possible database corruption"
                        fi
                        if sqDb "DELETE FROM video_rating_key_by_item WHERE ID = ${firstEpisodeId};"; then
                            printOutput "5" "Removed stale rating keys containing file ID [${firstEpisodeId}] from video_rating_key_by_item"
                        else
                            badExit "52" "Failed to remove stale rating keys containing file ID [${firstEpisodeId}] from video_rating_key_by_season -- Possible database corruption"
                        fi
                    else
                        badExit "53" "Database count for item episode key [${fileRatingKeyTmp}] in video_rating_key_by_item table returned greater than 1 -- Possible database corruption"
                    fi
                    # Insert
                    if sqDb "INSERT INTO video_rating_key_by_item (RATING_KEY, ID, UPDATED) VALUES ('${fileRatingKeyTmp}', '${firstEpisodeId}', $(date +%s));"; then
                        printOutput "5" "Added show rating key [${fileRatingKeyTmp}] to database"
                    else
                        badExit "54" "Adding show rating key [${fileRatingKeyTmp}] to database failed"
                    fi

                    # Break the loop
                    break
                fi
            fi
        else
            notSearchedArr+=("${z}")
        fi
    done

    # If we've gotten this far, and not matched anything, we should do an inefficient search with the leftover titles from the notSearchedArr[@]
    if [[ "${lookupMatch}" -eq "0" ]]; then
        # We may have some unwanted data from some other lookup for ${curlOutput}, so call that endpoint again
        callCurl "${plexAdd}/library/sections/${videoLibraryId}/all?X-Plex-Token=${plexToken}"
        for z in "${notSearchedArr[@]}"; do
            showRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select( .\"+@title\" == \"${plexTitleArr[${z}]}\") | .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -n "${showRatingKey}" ]]; then
                printOutput "5" "Attempting lookup with show rating key [${showRatingKey}]"
            else
                continue
            fi
            # Get the rating key of a season that matches our video year
            callCurl "${plexAdd}/library/metadata/${showRatingKey}/children?X-Plex-Token=${plexToken}"
            seasonRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@index\" == \"${firstYear}\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -n "${seasonRatingKey}" ]]; then
                printOutput "5" "Retrieved season rating key [${seasonRatingKey}]"
                callCurl "${plexAdd}/library/metadata/${seasonRatingKey}/children?X-Plex-Token=${plexToken}"
                # Get the YT ID from the file path of the first episode of the first season
                firstEpisodeId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                firstEpisodeId="${firstEpisodeId%\]\.*}"
                firstEpisodeId="${firstEpisodeId##*\[}"
                # We have now extracted the ID of the first episode of the first season. Compare it to ours, and pray for a match.
                if [[ "${firstEpisodeId}" == "${firstEpisode}" ]]; then
                    lookupMatch="1"
                    printOutput "5" "Located show rating key [${showRatingKey}] via least efficient lookup method"
                    fileRatingKeyTmp="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
                    videoFileRatingKey["_${firstEpisodeId}"]="${fileRatingKeyTmp}"

                    # Add the show rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM video_rating_key_by_channel WHERE RATING_KEY = '${showRatingKey}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Expected output
                        true
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, delete the stale entry
                        if sqDb "DELETE FROM video_rating_key_by_channel WHERE RATING_KEY = ${showRatingKey};"; then
                            printOutput "5" "Removed stale rating key [${showRatingKey}] from video_rating_key_by_channel"
                        else
                            badExit "55" "Failed to remove stale rating key [${showRatingKey}] from video_rating_key_by_channel -- Possible database corruption"
                        fi
                        if sqDb "DELETE FROM video_rating_key_by_channel WHERE CHANNEL_ID = ${1};"; then
                            printOutput "5" "Removed stale rating keys containing channel ID [${1}] from video_rating_key_by_channel"
                        else
                            badExit "56" "Failed to remove stale rating keys containing channel ID [${1}] from video_rating_key_by_channel -- Possible database corruption"
                        fi
                    else
                        badExit "57" "Database count for rating key [${showRatingKey}] in video_rating_key_by_channel table returned greater than 1 -- Possible database corruption"
                    fi
                    # Insert
                    if sqDb "INSERT INTO video_rating_key_by_channel (RATING_KEY, CHANNEL_ID, UPDATED) VALUES (${showRatingKey}, '${1}', $(date +%s));"; then
                        printOutput "5" "Added series rating key [${showRatingKey}] to database"
                    else
                        badExit "58" "Adding series rating key [${showRatingKey}] to database failed"
                    fi
                    
                    # Add the season rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM video_rating_key_by_season WHERE RATING_KEY = '${seasonRatingKey}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Expected output
                        true
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, delete the stale entry
                        if sqDb "DELETE FROM video_rating_key_by_season WHERE RATING_KEY = ${seasonRatingKey};"; then
                            printOutput "5" "Removed stale rating key [${seasonRatingKey}] from video_rating_key_by_season"
                        else
                            badExit "59" "Failed to remove stale rating key [${seasonRatingKey}] from video_rating_key_by_season -- Possible database corruption"
                        fi
                        if sqDb "DELETE FROM video_rating_key_by_season WHERE CHANNEL_ID = ${1};"; then
                            printOutput "5" "Removed stale rating keys containing channel ID [${1}] from video_rating_key_by_season"
                        else
                            badExit "60" "Failed to remove stale rating keys containing channel ID [${1}] from video_rating_key_by_season -- Possible database corruption"
                        fi
                    else
                        badExit "61" "Database count for rating key [${seasonRatingKey}] in video_rating_key_by_season table returned greater than 1 -- Possible database corruption"
                    fi
                    # Insert
                    if sqDb "INSERT INTO video_rating_key_by_season (RATING_KEY, YEAR, CHANNEL_ID, UPDATED) VALUES (${seasonRatingKey}, ${vidYear}, '${1}', $(date +%s));"; then
                        printOutput "5" "Added season rating key [${seasonRatingKey}] to database"
                    else
                        badExit "62" "Adding season rating key [${seasonRatingKey}] to database failed"
                    fi
                    
                    # Add the show's episode rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM video_rating_key_by_item WHERE RATING_KEY = '${fileRatingKeyTmp}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Expected output
                        true
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, delete the stale entry
                        if sqDb "DELETE FROM video_rating_key_by_item WHERE RATING_KEY = ${fileRatingKeyTmp};"; then
                            printOutput "5" "Removed stale rating key [${fileRatingKeyTmp}] from video_rating_key_by_item"
                        else
                            badExit "63" "Failed to remove stale rating key [${fileRatingKeyTmp}] from video_rating_key_by_item -- Possible database corruption"
                        fi
                        if sqDb "DELETE FROM video_rating_key_by_item WHERE ID = ${firstEpisodeId};"; then
                            printOutput "5" "Removed stale rating keys containing file ID [${firstEpisodeId}] from video_rating_key_by_item"
                        else
                            badExit "64" "Failed to remove stale rating keys containing file ID [${firstEpisodeId}] from video_rating_key_by_season -- Possible database corruption"
                        fi
                    else
                        badExit "65" "Database count for item episode key [${fileRatingKeyTmp}] in video_rating_key_by_item table returned greater than 1 -- Possible database corruption"
                    fi
                    # Insert
                    if sqDb "INSERT INTO video_rating_key_by_item (RATING_KEY, ID, UPDATED) VALUES ('${fileRatingKeyTmp}', '${firstEpisodeId}', $(date +%s));"; then
                        printOutput "5" "Added show rating key [${fileRatingKeyTmp}] to database"
                    else
                        badExit "66" "Adding show rating key [${fileRatingKeyTmp}] to database failed"
                    fi
                    
                    # Break the loop
                    break
                fi
            fi
        done
    fi

    if [[ "${lookupMatch}" -eq "0" ]]; then
        printOutput "1" "Unable to locate rating key for series [${chanName}]"
        return 1
    fi
fi
if [[ -z "${videoFileRatingKey[_${1}]}" ]]; then
    printOutput "1" "Rating key lookup for file ID [${1}] failed -- Is Plex aware of the file? If so, repair rating keys with the '-r' flag."
    return 1
fi
}

### BEGIN UNTESTED 
function getAudioFileRatingKey {
# File ID should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a file ID please"
    return 1
fi
if [[ -n "${audioFileRatingKey[_${1}]}" ]]; then
    # We already have it
    # Validate it
    if ! validateInterger "${audioFileRatingKey[_${1}]}"; then
        printOutput "1" "Variable audioFileRatingKey[_${1}] [${audioFileRatingKey[_${1}]}] failed to validate -- Unable to continue"
        return 1
    fi
    callCurl "${plexAdd}/library/metadata/${audioFileRatingKey[_${1}]}?X-Plex-Token=${plexToken}"
    verifyId="$(yq -p xml ".MediaContainer.Track.Media.Part.\"+@file\"" <<<"${curlOutput}")"
    verifyId="${verifyId%\]\.*}"
    verifyId="${verified##*\[}"
    if [[ "${verifyId}" == "${1}" ]]; then
        # We're good
        return 0
    fi
else
    audioFileRatingKey["_${1}"]="$(sqDb "SELECT RATING_KEY FROM audio_rating_key_by_item WHERE ID = '${1}';")"
    if [[ -n "${audioFileRatingKey[_${1}]}" ]]; then
        # Validate it
        if ! validateInterger "${audioFileRatingKey[_${1}]}"; then
            printOutput "1" "Variable audioFileRatingKey[_${1}] [${audioFileRatingKey[_${1}]}] failed to validate -- Unable to continue"
            return 1
        fi
        callCurl "${plexAdd}/library/metadata/${audioFileRatingKey[_${1}]}?X-Plex-Token=${plexToken}"
        verifyId="$(yq -p xml ".MediaContainer.Track.Media.Part.\"+@file\"" <<<"${curlOutput}")"
        verifyId="${verifyId%\]\.*}"
        verifyId="${verified##*\[}"
        if [[ "${verifyId}" == "${1}" ]]; then
            # We're good
            return 0
        fi
    fi
fi

# Get the channel ID of our file ID
local channelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${1}';")"
if [[ -z "${channelId}" ]]; then
    printOutput "1" "Unable to retrieve channel ID for file ID [${1}] -- Possible database corruption"
    return 1
fi
# Get the rating key for this artist
local showRatingKey="$(sqDb "SELECT RATING_KEY FROM audio_rating_key_by_channel WHERE CHANNEL_ID = '${channelId}';")"
if [[ -z "${showRatingKey}" ]]; then
    updateArtistRatingKey "${channelId}"
    local showRatingKey="$(sqDb "SELECT RATING_KEY FROM audio_rating_key_by_channel WHERE CHANNEL_ID = '${channelId}';")"
    if [[ -z "${showRatingKey}" ]]; then
        printOutput "1" "Unable to retrieve artist rating key for channel ID [${channelId}]"
        return 1
    fi
fi
# Get the rating key for the album
local vidYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${1}';")"
if [[ -z "${vidYear}" ]]; then
    printOutput "1" "Unable to retrieve year for file ID [${1}] -- Possible database corruption"
    return 1
fi
local albumRatingKey="$(sqDb "SELECT RATING_KEY FROM audio_rating_key_by_album WHERE ID = '${1}' AND YEAR = ${vidYear};")"
if [[ -z "${albumRatingKey}" ]]; then
    updateAlbumRatingKey "${1}" "${vidYear}" "${showRatingKey}"
    local albumRatingKey="$(sqDb "SELECT RATING_KEY FROM audio_rating_key_by_album WHERE ID = '${1}' AND YEAR = ${vidYear};")"
    if [[ -z "${albumRatingKey}" ]]; then
        printOutput "1" "Unable to retrieve artist rating key for ID [${1}] year [${vidYear}]"
        return 1
    fi
fi
# Get the rating key for the file ID
callCurl "${plexAdd}/library/metadata/${albumRatingKey}/children/?X-Plex-Token=${plexToken}"
readarray -t fileRatingKeys < <(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
for fileRatingKeyTmp in "${fileRatingKeys[@]}"; do
    if ! validateInterger "${fileRatingKeyTmp}"; then
        printOutput "1" "Variable fileRatingKeyTmp [${fileRatingKeyTmp}] failed to validate -- Unable to continue"
        return 1
    fi
    local fileId="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"10107\" ) .Media.Part.\"+@file\"" <<<"${curlOutput}")"
    local fileId="${fileId%\]\.*}"
    local fileId="${fileId##*\[}"
    if [[ "${fileId}" == "${1}" ]]; then
        # We've matched
        audioFileRatingKey["_${1}"]="${fileRatingKeyTmp}"
        # Load it into the database
        local dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_item WHERE RATING_KEY = ${fileRatingKeyTmp};")"
        if [[ "${dbCount}" -eq "1" ]]; then
            # Drop that outdated record
            sqDb "DELETE FROM audio_rating_key_by_item WHERE RATING_KEY = ${fileRatingKeyTmp};"
        elif [[ "${dbCount}" -gt "1" ]]; then
            printOutput "1" "Received count [${dbCount}] from database -- Possibly corrupted"
            sqDb "DELETE FROM audio_rating_key_by_item WHERE RATING_KEY = ${fileRatingKeyTmp};"
        else
            badExit "67" "Received unexpected count [${dbCount}] from database for fileRatingKeyTmp [${fileRatingKeyTmp}] -- Database possibly corrupted"
        fi
        # Now we can insert
        if sqDb "INSERT INTO audio_rating_key_by_item (RATING_KEY, ID, UPDATED) VALUES (${fileRatingKeyTmp}, '${1}', $(date +%s));"; then
            printOutput "5" "Added item rating key [${fileRatingKeyTmp}] year [${2}] to database"
        else
            badExit "68" "Adding item rating key [${fileRatingKeyTmp}] year [${2}] to database failed"
        fi
        break
    fi
done
}

function updateAlbumRatingKey {
# Channel ID is ${1}
# Season year is ${2}
# Show rating key is ${3}
callCurl "${plexAdd}/library/metadata/${3}/children/?X-Plex-Token=${plexToken}"
local albumRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@index\" == \"${2}\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"

if ! validateInterger "${albumRatingKey}"; then
    printOutput "1" "Variable albumRatingKey [${albumRatingKey}] failed to validate -- Unable to continue"
    return 1
fi

# Add it to the database
local dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_album WHERE RATING_KEY = ${albumRatingKey};")"
if [[ "${dbCount}" -eq "0" ]]; then
    # Expected output
    true
elif [[ "${dbCount}" -eq "1" ]]; then
    # Drop the stale rating key
    if ! sqDb "DELETE FROM audio_rating_key_by_album WHERE RATING_KEY = ${albumRatingKey};"; then
        badExit "69" "Failed to remove stale album rating key [${albumRatingKey}] from audio_rating_key_by_album -- Database likely corrupt"
    fi
else
    badExit "70" "Database count for rating key [${albumRatingKey}] in audio_rating_key_by_album table returned unexpected output [${dbCount}] -- Possible database corruption"
fi

# Insert
if sqDb "INSERT INTO audio_rating_key_by_album (RATING_KEY, CHANNEL_ID, YEAR, UPDATED) VALUES (${albumRatingKey}, '${1}', ${2}, $(date +%s));"; then
    printOutput "5" "Added album rating key [${albumRatingKey}] year [${2}] to database"
else
    badExit "71" "Adding album rating key [${albumRatingKey}] year [${2}] to database failed"
fi
}

function updateArtistRatingKey {
# Channel ID should be passed as ${1}
if [[ -z "${1}" ]]; then
    badExit "72" "No channel ID passed for show rating key update"
fi
chanName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${1}';")"
printOutput "3" "Retrieving rating key from Plex for show [${chanName}] with channel ID [${1}]"
# Can we take the easy way out? Try to match the artist by name
lookupMatch="0"
# Get a list of all the artist in the audio library
callCurl "${plexAdd}/library/sections/${audioLibraryId}/all?X-Plex-Token=${plexToken}"
# See if we can flatly match any of these via ${chanName}
showRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select( .\"+@title\" == \"${chanName}\") | .\"+@ratingKey\"" <<<"${curlOutput}")"
if [[ -n "${showRatingKey}" ]]; then
    # We could!
    printOutput "5" "Located show rating key [${showRatingKey}] via most efficient lookup method"
    dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_channel WHERE CHANNEL_ID = '${1}';")"
    if [[ "${dbCount}" -eq "0" ]]; then
        # Expected output
        true
    elif [[ "${dbCount}" -eq "1" ]]; then
        # Drop the stale rating key
        if ! sqDb "DELETE FROM audio_rating_key_by_channel WHERE RATING_KEY = ${showRatingKey};"; then
            badExit "73" "Failed to remove stale artist rating key [${showRatingKey}] from audio_rating_key_by_channel -- Database likely corrupt"
        fi
    else
        badExit "74" "Database count for artist rating key [${showRatingKey}] in audio_rating_key_by_channel table returned unexpected output [${dbCount}] -- Possible database corruption"
    fi
    if sqDb "INSERT INTO audio_rating_key_by_channel (RATING_KEY, CHANNEL_ID, UPDATED) VALUES (${showRatingKey}, '${1}', $(date +%s));"; then
        printOutput "5" "Added show rating key [${showRatingKey}] to database"
    else
        badExit "75" "Adding show rating key [${showRatingKey}] to database failed"
    fi
    lookupMatch="1"
else
    # We could not
    # Best way would be the first episode of the first album of the channel ID in question
    firstEpisode="$(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${1}' ORDER BY TIMESTAMP ASC LIMIT 1;")"
    # Having the year would help as we can skip artist which do not have the first year album we want
    firstYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${firstEpisode}';")"
    # To do this, we need to find a matching episode by YT ID in Plex
    # The "lazy" way to do this is to only compare items which have the same first character as our channel name
    chanNameCompare="${chanName:0:1}"
    # Don't recycle old variable data
    unset plexTitleArr notSearchedArr
    # Extract a list of item titles from Plex, to an array
    readarray -t plexTitleArr <<<"$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@title\"" <<<"${curlOutput}")"
    for z in "${!plexTitleArr[@]}"; do
        # Get the first letter
        plexNameCompare="${plexTitleArr[${z}]:0:1}"
        # Compare it to the first letter of our artist
        if [[ "${plexNameCompare^}" == "${chanNameCompare^}" ]]; then
            # The first characters match, get show's rating key so we can investigate further
            showRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select( .\"+@title\" == \"${plexTitleArr[${z}]}\") | .\"+@ratingKey\"" <<<"${curlOutput}")"
            if ! validateInterger "${showRatingKey}"; then
                printOutput "1" "Variable showRatingKey [${showRatingKey}] failed to validate -- Unable to continue"
                return 1
            fi
            # Get the rating key of a album that matches our audio year
            callCurl "${plexAdd}/library/metadata/${showRatingKey}/children?X-Plex-Token=${plexToken}"
            albumRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@index\" == \"${firstYear}\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
            if ! validateInterger "${albumRatingKey}"; then
                printOutput "1" "Variable albumRatingKey [${albumRatingKey}] failed to validate -- Unable to continue"
                return 1
            fi
            if [[ -n "${albumRatingKey}" ]]; then
                callCurl "${plexAdd}/library/metadata/${albumRatingKey}/children?X-Plex-Token=${plexToken}"
                # Get the YT ID from the file path of the first episode of the first album
                firstEpisodeId="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                firstEpisodeId="${firstEpisodeId%\]\.*}"
                firstEpisodeId="${firstEpisodeId##*\[}"
                if [[ -z "${firstEpisodeId}" ]]; then
                    printOutput "1" "Failed to isolite ID for first episode of [${plexTitleArr[${z}]}] album [${firstYear}] -- Skipping artist lookup"
                    continue
                fi
                # We have now extracted the ID of the first episode of the first album. Compare it to ours, and hope for a match.
                if [[ "${firstEpisodeId}" == "${firstEpisode}" ]]; then
                    # We've matched!
                    lookupMatch="1"
                    printOutput "5" "Located show rating key [${showRatingKey}] via semi-efficient lookup method"
                    # While we're already here, grab the rating key for the individual episode/file
                    fileRatingKeyTmp="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
                    audioFileRatingKey["_${firstEpisodeId}"]="${fileRatingKeyTmp}"

                    # Add the show rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_channel WHERE RATING_KEY = '${showRatingKey}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Expected output
                        true
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, delete the stale entry
                        if sqDb "DELETE FROM audio_rating_key_by_channel WHERE RATING_KEY = ${showRatingKey};"; then
                            printOutput "5" "Removed stale rating key [${showRatingKey}] from audio_rating_key_by_channel"
                        else
                            badExit "76" "Failed to remove stale rating key [${showRatingKey}] from audio_rating_key_by_channel -- Possible database corruption"
                        fi
                        if sqDb "DELETE FROM audio_rating_key_by_channel WHERE CHANNEL_ID = ${1};"; then
                            printOutput "5" "Removed stale rating keys containing channel ID [${1}] from audio_rating_key_by_channel"
                        else
                            badExit "77" "Failed to remove stale rating keys containing channel ID [${1}] from audio_rating_key_by_channel -- Possible database corruption"
                        fi
                    else
                        badExit "78" "Database count for rating key [${showRatingKey}] in audio_rating_key_by_channel table returned greater than 1 -- Possible database corruption"
                    fi
                    # Insert
                    if sqDb "INSERT INTO audio_rating_key_by_channel (RATING_KEY, CHANNEL_ID, UPDATED) VALUES (${showRatingKey}, '${1}', $(date +%s));"; then
                        printOutput "5" "Added artist rating key [${showRatingKey}] to database"
                    else
                        badExit "79" "Adding artist rating key [${showRatingKey}] to database failed"
                    fi
                    
                    # Add the album rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_album WHERE RATING_KEY = '${albumRatingKey}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Expected output
                        true
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, delete the stale entry
                        if sqDb "DELETE FROM audio_rating_key_by_album WHERE RATING_KEY = ${albumRatingKey};"; then
                            printOutput "5" "Removed stale rating key [${albumRatingKey}] from audio_rating_key_by_album"
                        else
                            badExit "80" "Failed to remove stale rating key [${albumRatingKey}] from audio_rating_key_by_album -- Possible database corruption"
                        fi
                        if sqDb "DELETE FROM audio_rating_key_by_album WHERE CHANNEL_ID = ${1};"; then
                            printOutput "5" "Removed stale rating keys containing channel ID [${1}] from audio_rating_key_by_album"
                        else
                            badExit "81" "Failed to remove stale rating keys containing channel ID [${1}] from audio_rating_key_by_album -- Possible database corruption"
                        fi
                    else
                        badExit "82" "Database count for rating key [${albumRatingKey}] in audio_rating_key_by_album table returned greater than 1 -- Possible database corruption"
                    fi
                    # Insert
                    if sqDb "INSERT INTO audio_rating_key_by_album (RATING_KEY, YEAR, CHANNEL_ID, UPDATED) VALUES (${albumRatingKey}, ${vidYear}, '${1}', $(date +%s));"; then
                        printOutput "5" "Added album rating key [${albumRatingKey}] to database"
                    else
                        badExit "83" "Adding album rating key [${albumRatingKey}] to database failed"
                    fi
                    
                    # Add the show's episode rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_item WHERE RATING_KEY = '${fileRatingKeyTmp}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Expected output
                        true
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, delete the stale entry
                        if sqDb "DELETE FROM audio_rating_key_by_item WHERE RATING_KEY = ${fileRatingKeyTmp};"; then
                            printOutput "5" "Removed stale rating key [${fileRatingKeyTmp}] from audio_rating_key_by_item"
                        else
                            badExit "84" "Failed to remove stale rating key [${fileRatingKeyTmp}] from audio_rating_key_by_item -- Possible database corruption"
                        fi
                        if sqDb "DELETE FROM audio_rating_key_by_item WHERE ID = ${firstEpisodeId};"; then
                            printOutput "5" "Removed stale rating keys containing file ID [${firstEpisodeId}] from audio_rating_key_by_item"
                        else
                            badExit "85" "Failed to remove stale rating keys containing file ID [${firstEpisodeId}] from audio_rating_key_by_album -- Possible database corruption"
                        fi
                    else
                        badExit "86" "Database count for item episode key [${fileRatingKeyTmp}] in audio_rating_key_by_item table returned greater than 1 -- Possible database corruption"
                    fi
                    # Insert
                    if sqDb "INSERT INTO audio_rating_key_by_item (RATING_KEY, ID, UPDATED) VALUES ('${fileRatingKeyTmp}', '${firstEpisodeId}', $(date +%s));"; then
                        printOutput "5" "Added show rating key [${fileRatingKeyTmp}] to database"
                    else
                        badExit "87" "Adding show rating key [${fileRatingKeyTmp}] to database failed"
                    fi

                    # Break the loop
                    break
                fi
            fi
        else
            notSearchedArr+=("${z}")
        fi
    done

    # If we've gotten this far, and not matched anything, we should do an inefficient search with the leftover titles from the notSearchedArr[@]
    if [[ "${lookupMatch}" -eq "0" ]]; then
        # We may have some unwanted data from some other lookup for ${curlOutput}, so call that endpoint again
        callCurl "${plexAdd}/library/sections/${audioLibraryId}/all?X-Plex-Token=${plexToken}"
        for z in "${notSearchedArr[@]}"; do
            showRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select( .\"+@title\" == \"${plexTitleArr[${z}]}\") | .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -n "${showRatingKey}" ]]; then
                printOutput "5" "Attempting lookup with show rating key [${showRatingKey}]"
            else
                continue
            fi
            # Get the rating key of a album that matches our audio year
            callCurl "${plexAdd}/library/metadata/${showRatingKey}/children?X-Plex-Token=${plexToken}"
            albumRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@index\" == \"${firstYear}\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -n "${albumRatingKey}" ]]; then
                printOutput "5" "Retrieved album rating key [${albumRatingKey}]"
                callCurl "${plexAdd}/library/metadata/${albumRatingKey}/children?X-Plex-Token=${plexToken}"
                # Get the YT ID from the file path of the first episode of the first album
                firstEpisodeId="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                firstEpisodeId="${firstEpisodeId%\]\.*}"
                firstEpisodeId="${firstEpisodeId##*\[}"
                # We have now extracted the ID of the first episode of the first album. Compare it to ours, and pray for a match.
                if [[ "${firstEpisodeId}" == "${firstEpisode}" ]]; then
                    lookupMatch="1"
                    printOutput "5" "Located show rating key [${showRatingKey}] via least efficient lookup method"
                    fileRatingKeyTmp="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
                    audioFileRatingKey["_${firstEpisodeId}"]="${fileRatingKeyTmp}"

                    # Add the show rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_channel WHERE RATING_KEY = '${showRatingKey}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Expected output
                        true
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, delete the stale entry
                        if sqDb "DELETE FROM audio_rating_key_by_channel WHERE RATING_KEY = ${showRatingKey};"; then
                            printOutput "5" "Removed stale rating key [${showRatingKey}] from audio_rating_key_by_channel"
                        else
                            badExit "88" "Failed to remove stale rating key [${showRatingKey}] from audio_rating_key_by_channel -- Possible database corruption"
                        fi
                        if sqDb "DELETE FROM audio_rating_key_by_channel WHERE CHANNEL_ID = ${1};"; then
                            printOutput "5" "Removed stale rating keys containing channel ID [${1}] from audio_rating_key_by_channel"
                        else
                            badExit "89" "Failed to remove stale rating keys containing channel ID [${1}] from audio_rating_key_by_channel -- Possible database corruption"
                        fi
                    else
                        badExit "90" "Database count for rating key [${showRatingKey}] in audio_rating_key_by_channel table returned greater than 1 -- Possible database corruption"
                    fi
                    # Insert
                    if sqDb "INSERT INTO audio_rating_key_by_channel (RATING_KEY, CHANNEL_ID, UPDATED) VALUES (${showRatingKey}, '${1}', $(date +%s));"; then
                        printOutput "5" "Added artist rating key [${showRatingKey}] to database"
                    else
                        badExit "91" "Adding artist rating key [${showRatingKey}] to database failed"
                    fi
                    
                    # Add the album rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_album WHERE RATING_KEY = '${albumRatingKey}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Expected output
                        true
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, delete the stale entry
                        if sqDb "DELETE FROM audio_rating_key_by_album WHERE RATING_KEY = ${albumRatingKey};"; then
                            printOutput "5" "Removed stale rating key [${albumRatingKey}] from audio_rating_key_by_album"
                        else
                            badExit "92" "Failed to remove stale rating key [${albumRatingKey}] from audio_rating_key_by_album -- Possible database corruption"
                        fi
                        if sqDb "DELETE FROM audio_rating_key_by_album WHERE CHANNEL_ID = ${1};"; then
                            printOutput "5" "Removed stale rating keys containing channel ID [${1}] from audio_rating_key_by_album"
                        else
                            badExit "93" "Failed to remove stale rating keys containing channel ID [${1}] from audio_rating_key_by_album -- Possible database corruption"
                        fi
                    else
                        badExit "94" "Database count for rating key [${albumRatingKey}] in audio_rating_key_by_album table returned greater than 1 -- Possible database corruption"
                    fi
                    # Insert
                    if sqDb "INSERT INTO audio_rating_key_by_album (RATING_KEY, YEAR, CHANNEL_ID, UPDATED) VALUES (${albumRatingKey}, ${vidYear}, '${1}', $(date +%s));"; then
                        printOutput "5" "Added album rating key [${albumRatingKey}] to database"
                    else
                        badExit "95" "Adding album rating key [${albumRatingKey}] to database failed"
                    fi
                    
                    # Add the show's episode rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_item WHERE RATING_KEY = '${fileRatingKeyTmp}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Expected output
                        true
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, delete the stale entry
                        if sqDb "DELETE FROM audio_rating_key_by_item WHERE RATING_KEY = ${fileRatingKeyTmp};"; then
                            printOutput "5" "Removed stale rating key [${fileRatingKeyTmp}] from audio_rating_key_by_item"
                        else
                            badExit "96" "Failed to remove stale rating key [${fileRatingKeyTmp}] from audio_rating_key_by_item -- Possible database corruption"
                        fi
                        if sqDb "DELETE FROM audio_rating_key_by_item WHERE ID = ${firstEpisodeId};"; then
                            printOutput "5" "Removed stale rating keys containing file ID [${firstEpisodeId}] from audio_rating_key_by_item"
                        else
                            badExit "97" "Failed to remove stale rating keys containing file ID [${firstEpisodeId}] from audio_rating_key_by_album -- Possible database corruption"
                        fi
                    else
                        badExit "98" "Database count for item episode key [${fileRatingKeyTmp}] in audio_rating_key_by_item table returned greater than 1 -- Possible database corruption"
                    fi
                    # Insert
                    if sqDb "INSERT INTO audio_rating_key_by_item (RATING_KEY, ID, UPDATED) VALUES ('${fileRatingKeyTmp}', '${firstEpisodeId}', $(date +%s));"; then
                        printOutput "5" "Added show rating key [${fileRatingKeyTmp}] to database"
                    else
                        badExit "99" "Adding show rating key [${fileRatingKeyTmp}] to database failed"
                    fi
                    
                    # Break the loop
                    break
                fi
            fi
        done
    fi

    if [[ "${lookupMatch}" -eq "0" ]]; then
        printOutput "1" "Unable to locate rating key for artist [${chanName}]"
        return 1
    fi
fi
if [[ -z "${audioFileRatingKey[_${1}]}" ]]; then
    printOutput "1" "Rating key lookup for file ID [${1}] failed -- Is Plex aware of the file? If so, repair rating keys with the '-r' flag."
    return 1
fi
}
### END UNTESTED

function getChannelInfo {
# It does not, we should add it.
# Get the channel info from the YouTube API
printOutput "5" "Calling API for channel info [${1}]"
ytApiCall "channels?id=${1}&part=snippet,statistics,brandingSettings"
apiResults="$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")"

if ! validateInterger "${apiResults}"; then
    printOutput "1" "Variable apiResults [${apiResults}] failed to validate -- Unable to continue"
    return 1
fi

if [[ "${apiResults}" -eq "0" ]]; then
    printOutput "1" "API lookup for channel info returned zero results -- Skipping"
    return 1
fi

# Get the channel name
chanName="$(yq -p json ".items[0].snippet.title" <<<"${curlOutput}")"
# Validate it
if [[ -z "${chanName}" ]]; then
    ### SKIP CONDITION
    printOutput "1" "No channel title returned from API lookup for channel ID [${1}] -- Skipping"
    return 1
fi
# Store the channel name for our directory name
channelNameClean="${chanName}"
# Store the channel name for stdout
chanNameOrig="${chanName}"
# Clean the name up for sqlite
chanName="${chanName//\'/\'\'}"

# Get the channel creation date
chanDate="$(yq -p json ".items[0].snippet.publishedAt" <<<"${curlOutput}")"
# Convert the date to a Unix timestamp
chanEpochDate="$(date --date="${chanDate}" "+%s")"
if ! [[ "${chanEpochDate}" =~ ^[0-9]+$ ]]; then
    ### SKIP CONDITION
    printOutput "1" "Unable to convert creation date to unix epoch timestamp [${chanDate}][${chanEpochDate}] for channel ID [${1}] -- Skipping"
    return 1
fi

# Get the channel sub count
chanSubs="$(yq -p json ".items[0].statistics.subscriberCount" <<<"${curlOutput}")"
if [[ "${chanSubs}" == "null" ]]; then
    chanSubs="0"
elif ! [[ "${chanSubs}" =~ ^[0-9]+$ ]]; then
    ### SKIP CONDITION
    printOutput "1" "Invalid subscriber count returned [${chanSubs}] for channel ID [${1}] -- Skipping"
    return 1
fi
if [[ "${chanSubs}" -ge "1000" ]]; then
    chanSubs="$(printf "%'d" "${chanSubs}")"
fi

# Get the channel country
chanCountry="$(yq -p json ".items[0].snippet.country" <<<"${curlOutput}")"
if [[ "${chanCountry}" == "null" ]]; then
    chanCountry="an unknown country"
else
    # Safety check is done within this function
    if ! getChannelCountry "${chanCountry}"; then
        ### SKIP CONDITION
        printOutput "1" "Unknown country code [${chanCountry}] for channel ID [${1}] -- Skipping";
        return 1
    fi
fi
# Probably unnecessary -- Clean the country up for sqlite
chanCountry="${chanCountry//\'/\'\'}"

# Get the channel custom URL
chanUrl="$(yq -p json ".items[0].snippet.customUrl" <<<"${curlOutput}")"
if ! [[ "${chanUrl}" =~ ^@([A-Z]|[a-z]|[0-9]|\.|-|_)+$ ]]; then
    ### SKIP CONDITION
    printOutput "1" "Bad custom URL [${chanUrl}] returned for channel ID [${1}] -- Skipping"
    return 1
fi
# Probably unnecessary -- Clean the URL up for sqlite
chanUrl="${chanUrl//\'/\'\'}"

# Get the channel video count
chanVids="$(yq -p json ".items[0].statistics.videoCount" <<<"${curlOutput}")"
if [[ "${chanVids}" == "null" ]]; then
    chanVids="0"
elif ! [[ "${chanVids}" =~ ^[0-9]+$ ]]; then
    ### SKIP CONDITION
    printOutput "1" "Invalid video count returned [${chanVids}] for channel ID [${1}] -- Skipping"
    return 1
fi
if [[ "${chanVids}" -ge "1000" ]]; then
    chanVids="$(printf "%'d" "${chanVids}")"
fi

# Get the channel view count
chanViews="$(yq -p json ".items[0].statistics.viewCount" <<<"${curlOutput}")"
if [[ "${chanViews}" == "null" ]]; then
    chanViews="0"
elif ! [[ "${chanViews}" =~ ^[0-9]+$ ]]; then
    ### SKIP CONDITION
    printOutput "1" "Invalid view count returned [${chanViews}] for channel ID [${1}] -- Skipping"
    return 1
fi
if [[ "${chanViews}" -ge "1000" ]]; then
    chanViews="$(printf "%'d" "${chanViews}")"
fi

# Get the channel description
chanDesc="$(yq -p json ".items[0].snippet.description" <<<"${curlOutput}")"
if [[ -z "${chanDesc}" || "${chanDesc}" == "null" ]]; then
    # No channel description set
    chanDesc="https://www.youtube.com/${chanUrl}${lineBreak}${chanSubs} subscribers${lineBreak}${chanVids} videos${lineBreak}${chanViews} views${lineBreak}Joined YouTube $(date --date="@${chanEpochDate}" "+%b. %d, %Y")${lineBreak}Based in ${chanCountry}${lineBreak}Channel description and statistics last updated $(date)"
else
    chanDesc="${chanDesc}${lineBreak}-----${lineBreak}https://www.youtube.com/${chanUrl}${lineBreak}${chanSubs} subscribers${lineBreak}${chanVids} videos${lineBreak}${chanViews} views${lineBreak}Joined YouTube $(date --date="@${chanEpochDate}" "+%b. %d, %Y")${lineBreak}Based in ${chanCountry}${lineBreak}Channel description and statistics last updated $(date)"
fi
# Clean the description up for sqlite
chanDesc="${chanDesc//\'/\'\'}"

# Define our video path and audio path with filesystem safe characters
# Trim any leading spaces and/or periods
while [[ "${channelNameClean:0:1}" =~ ^( |\.)$ ]]; do
    channelNameClean="${channelNameClean# }"
    channelNameClean="${channelNameClean#\.}"
done
# Trim any trailing spaces and/or periods
while [[ "${channelNameClean:$(( ${#channelNameClean} - 1 )):1}" =~ ^( |\.)$ ]]; do
    channelNameClean="${channelNameClean% }"
    channelNameClean="${channelNameClean%\.}"
done
# Replace any forward or back slashes \ /
channelNameClean="${channelNameClean//\//_}"
channelNameClean="${channelNameClean//\\/_}"
# Replace any colons :
channelNameClean="${channelNameClean//:/-}"
# Replace any stars *
channelNameClean="${channelNameClean//\*/}"
# Replace any question marks ?
channelNameClean="${channelNameClean//\?/}"
# Replace any quotation marks "
channelNameClean="${channelNameClean//\"/}"
# Replace any brackets < >
channelNameClean="${channelNameClean//</}"
channelNameClean="${channelNameClean//>/}"
# Replace any vertical bars |
channelNameClean="${channelNameClean//\|/}"
# Condense any instances of '_-_'
while [[ "${channelNameClean}" =~ .*"_-_".* ]]; do
    channelNameClean="${channelNameClean//_-_/ - }"
done
# Condense any multiple spaces
while [[ "${channelNameClean}" =~ .*"  ".* ]]; do
    channelNameClean="${channelNameClean//  / }"
done

# String the whole path together
chanPathClean="${channelNameClean} [${1}]"

# Clean the path up for sqlite
chanPathClean="${chanPathClean//\'/\'\'}"
# Clean the name up for sqlite
channelNameClean="${channelNameClean//\'/\'\'}"

# Extract the URL for the channel image, if one exists
chanImage="$(yq -p json ".items[0].snippet.thumbnails | to_entries | sort_by(.value.height) | reverse | .0 | .value.url" <<<"${curlOutput}")"

# Extract the URL for the channel background, if one exists
chanBanner="$(yq -p json ".items[0].brandingSettings.image.bannerExternalUrl" <<<"${curlOutput}")"
# If we have a banner, crop it correctly
if [[ -n "${chanBanner}" && ! "${chanBanner}" == "null" ]]; then
    chanBanner="${chanBanner}=w2560-fcrop64=1,00005a57ffffa5a8-k-c0xffffffff-no-nd-rj"
else
    unset chanBanner
fi

dbCount="$(sqDb "SELECT COUNT(1) FROM source_channels WHERE ID = '${1}';")"
if [[ "${dbCount}" -eq "0" ]]; then
    # Insert it into the database
    if sqDb "INSERT INTO source_channels (ID, NAME, NAME_CLEAN, TIMESTAMP, SUB_COUNT, COUNTRY, URL, VID_COUNT, VIEW_COUNT, DESC, PATH, IMAGE, UPDATED) VALUES ('${1}', '${chanName}', '${channelNameClean}', ${chanEpochDate}, ${chanSubs//,/}, '${chanCountry}', 'https://www.youtube.com/${chanUrl}', ${chanVids//,/}, ${chanViews//,/}, '${chanDesc}', '${chanPathClean}', '${chanImage}', $(date +%s));"; then
        printOutput "3" "Added channel [${chanNameOrig}] ID [${1}] to database"
    else
        badExit "100" "Adding channel [${chanNameOrig}] ID [${1}] to database failed"
    fi
elif [[ "${dbCount}" -eq "1" ]]; then
    # Update the database entry
    if sqDb "UPDATE source_channels SET NAME = '${chanName}', NAME_CLEAN = '${channelNameClean}', TIMESTAMP = ${chanEpochDate}, SUB_COUNT = ${chanSubs//,/}, COUNTRY = '${chanCountry}', URL = 'https://www.youtube.com/${chanUrl}', VID_COUNT = ${chanVids//,/}, VIEW_COUNT = ${chanVids//,/}, DESC = '${chanDesc}', PATH = '${chanPathClean}', IMAGE = '${chanImage}', UPDATED = $(date +%s) WHERE ID = '${1}';"; then
        printOutput "4" "Updated channel [${chanNameOrig}] ID [${1}] in database"
    else
        badExit "101" "Updating channel [${chanNameOrig}] ID [${1}] in database failed"
    fi
else
    # PANIC
    badExit "102" "Multiple matches found for channel ID [${1}] -- Possible database corruption"
fi

# If we have a channel banner, add that entry too
if [[ -n "${chanBanner}" && ! "${chanBanner}" == "null" ]]; then
    if sqDb "UPDATE source_channels SET BANNER = '${chanBanner}' WHERE ID = '${1}';"; then
        printOutput "5" "Appended channel banner to database entry for channel ID [${1}]"
    else
        badExit "103" "Unable to append channel banner to database entry for channel ID [${1}]"
    fi
fi

# If we're in maintenance mode, update the images
if [[ "${updateMetadata}" == "1" ]]; then
    # Get the chanDir path
    chanDir="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${1}';")"
    # Get the channel image
    dbReply="$(sqDb "SELECT IMAGE FROM source_channels WHERE ID = '${1}';")"
    if [[ -n "${dbReply}" ]]; then
        # We only need to store the image in a shows folder, since music folders require image uploads
        if [[ -d "${videoOutput}/${chanDir}" ]]; then
            # Download the show image
            if callCurlDownload "${dbReply}" "${videoOutputDir}/${chanDir}/show.jpg"; then
                printOutput "5" "Downloaded show image for [${chanDir}]"
            else
                printOutput "1" "Failed to download show image for [${chanDir}]"
            fi
            # Get the background image, if one exists
            dbReply="$(sqDb "SELECT BANNER FROM source_channels WHERE ID = '${1}';")"
            if [[ -n "${dbReply}" ]]; then
                # We only need to store the image in a shows folder, since music folders require image uploads
                if [[ -d "${videoOutput}/${chanDir}" ]]; then
                    # Download it
                    callCurlDownload "${dbReply}" "${videoOutputDir}/${chanDir}/background.jpg"
                fi
            fi
            # Replace season folder images
            while read -r vidYear; do
                # Back up old ones
                if [[ -e "${videoOutputDir}/${chanDir}/Season ${vidYear}/Season${vidYear}.jpg" ]]; then
                    if ! mv "${videoOutputDir}/${chanDir}/Season ${vidYear}/Season${vidYear}.jpg" "${videoOutputDir}/${chanDir}/Season ${vidYear}/Season${vidYear}.old.jpg"; then
                        printOutput "1" "Failed to back up old season image for year [${vidYear}]"
                    fi
                fi
                # Make new ones
                if makeSeasonImage "${chanDir}" "${seasonYear}" "${1}"; then
                    printOutput "5" "Created season image for [${chanDir}/Season ${seasonYear}]"
                else
                    printOutput "1" "Failed to create season image for [${chanDir}/Season ${seasonYear}]"
                fi
            done < <(sqDb "SELECT DISTINCT YEAR FROM source_videos WHERE CHANNEL_ID = '${1}';")
        fi
    fi
fi
}

function getPlaylistInfo {
# Playlist ID should be passed as ${1}
# Get the necessary information
ytApiCall "playlists?id=${1}&part=id,snippet"
apiResults="$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")"
if ! validateInterger "${apiResults}"; then
    printOutput "1" "Variable apiResults [${apiResults}] failed to validate -- Unable to continue"
    return 1
fi

if [[ "${apiResults}" -eq "0" ]]; then
    printOutput "2" "API lookup for playlist parsing returned zero results (Is the playlist private?)"

    if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
        printOutput "3" "Re-attempting playlist lookup via yt-dlp + cookie"
        dlpApiCall="$(yt-dlp --no-warnings -J --playlist-items 0 --cookies "${cookieFile}" "https://www.youtube.com/playlist?list=${1}" 2>/dev/null)"
        throttleDlp
        
        if [[ "$(yq -p json ".availability" <<<"${dlpApiCall}")" == "private" ]]; then
            # Yes, it's a private playlist we can auth via cookie
            plVis="private"
            printOutput "3" "Lookup via cookie auth successful"
            plTitle="$(yq -p json ".title" <<<"${dlpApiCall}")"
            plDesc="$(yq -p json ".description" <<<"${dlpApiCall}")"
            plImage="$(yq -p json ".thumbnails[0].url" <<<"${dlpApiCall}")"
            plImage="${plImage%\?*}"
        else
            printOutput "1" "Unable to preform lookup on playlist ID [${1}] via yt-dlp -- Skipping"
            return 1
        fi
    else
        printOutput "1" "API lookup failed, and no cookie file provided to attempt to lookup playlist ID [${1}] via yt-dlp -- Skipping"
        return 1
    fi
elif [[ "${apiResults}" -eq "1" ]]; then
    plVis="public"
    plTitle="$(yq -p json ".items[0].snippet.title" <<<"${curlOutput}")"
    plDesc="$(yq -p json ".items[0].snippet.description" <<<"${curlOutput}")"
    plImage="$(yq -p json ".items[0].snippet.thumbnails | to_entries | sort_by(.value.height) | reverse | .0 | .value.url" <<<"${curlOutput}")"
else
    badExit "104" "Impossible condition"
fi

if [[ -z "${plTitle}" ]]; then
    ### SKIP CONDITION
    printOutput "1" "Unable to find title for playlist [${1}]"
    return 1
else
    # Clean up the title for sqlite
    plTitle="${plTitle//\'/\'\'}"
fi
if [[ -z "${plImage}" ]]; then
    ### SKIP CONDITION
    printOutput "1" "Unable to find image for playlist [${1}]"
    return 1
else
    # Clean up the image for sqlite
    plImage="${plImage//\'/\'\'}"
fi

dbCount="$(sqDb "SELECT COUNT(1) FROM source_playlists WHERE ID = '${1}';")"
if [[ "${dbCount}" -eq "0" ]]; then
    # Doesn't exist, add it.
    if sqDb "INSERT INTO source_playlists (ID, VISIBILITY, TITLE, IMAGE, UPDATED) VALUES ('${1}', '${plVis}', '${plTitle}', '${plImage}', $(date +%s));"; then
        printOutput "3" "Added playlist [${plTitle}] to database"
    else
        badExit "105" "Adding playlist [${plTitle}] ID [${1}][Vis: ${plVis}] to database failed"
    fi
elif [[ "${dbCount}" -eq "1" ]]; then
    # Exists, update it
    if sqDb "UPDATE source_playlists SET VISIBILITY = '${plVis}', TITLE = '${plTitle}', IMAGE = '${plImage}', UPDATED = $(date +%s) WHERE ID = '${1}';"; then
        printOutput "3" "Updated playlist [${plTitle}] in database"
    else
        badExit "106" "Updating channel [${plTitle}] ID [${1}] in database failed"
    fi
else
    # Panic
    badExit "107" "Multiple items returned for playlist [${plTitle}] ID [${1}] -- Possible database corruption"
fi

if [[ -n "${plDesc}" ]]; then
    # Clean up the description for sqlite
    plDesc="${plDesc//\'/\'\'}"
    if sqDb "UPDATE source_playlists SET DESC = '${plDesc}', UPDATED = $(date +%s) WHERE ID = '${1}';"; then
        printOutput "3" "Updated description for playlist [${plTitle}] in database"
    else
        badExit "108" "Updating description for playlist [${plTitle}] in database failed"
    fi
fi
}

function setSeriesMetadata {
# Get the channel ID from the rating key
channelId="$(sqDb "SELECT CHANNEL_ID FROM video_rating_key_by_channel WHERE RATING_KEY = ${1};")"

# Get the channel name
showName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${channelId}';")"
if [[ -z "${showName}" ]]; then
    printOutput "1" "Unable to retrieve series name for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi
# Encode it
showNameEncoded="$(rawurlencode "${showName}")"
if [[ -z "${showNameEncoded}" ]]; then
    printOutput "1" "Unable to encode series name [${showName}] for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi

# Get and encode the channel description
showDesc="$(sqDb "SELECT DESC FROM source_channels WHERE ID = '${channelId}';")"
if [[ -z "${showDesc}" ]]; then
    printOutput "1" "Unable to retrieve series description for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi
# Encode it
showDescEncoded="$(rawurlencode "${showDesc}")"
if [[ -z "${showDescEncoded}" ]]; then
    printOutput "1" "Unable to encode series description for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi

# Get the channel creation date
showCreation="$(sqDb "SELECT TIMESTAMP FROM source_channels WHERE ID = '${channelId}';")"
if ! validateInterger "${showCreation}"; then
    printOutput "1" "Variable showCreation [${showCreation}] failed to validate -- Unable to continue"
    return 1
fi
# Convert it to YYYY-MM-DD
showCreation="$(date --date="@${showCreation}" "+%Y-%m-%d")"

if callCurlPut "${plexAdd}/library/sections/${videoLibraryId}/all?type=2&id=${1}&includeExternalMedia=1&title.value=${showNameEncoded}&titleSort.value=${showNameEncoded}&summary.value=${showDescEncoded}&studio.value=YouTube&originallyAvailableAt.value=${showCreation}&title.locked=1&titleSort.locked=1&originallyAvailableAt.locked=1&studio.locked=1&summary.locked=1&X-Plex-Token=${plexToken}"; then
    printOutput "4" "Metadata for series [${showName}] sucessfully updated"
else
    printOutput "1" "Metadata for series [${showName}] failed"
fi
}

function setArtistMetadata {
# Get the channel ID from the rating key
channelId="$(sqDb "SELECT CHANNEL_ID FROM audio_rating_key_by_channel WHERE RATING_KEY = ${1};")"

# Get the channel name
showName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${channelId}';")"
if [[ -z "${showName}" ]]; then
    printOutput "1" "Unable to retrieve artist name for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi
# Encode it
showNameEncoded="$(rawurlencode "${showName}")"
if [[ -z "${showNameEncoded}" ]]; then
    printOutput "1" "Unable to encode artist name [${showName}] for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi

# Get and encode the channel description
showDesc="$(sqDb "SELECT DESC FROM source_channels WHERE ID = '${channelId}';")"
if [[ -z "${showDesc}" ]]; then
    printOutput "1" "Unable to retrieve artist description for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi
# Encode it
showDescEncoded="$(rawurlencode "${showDesc}")"
if [[ -z "${showDescEncoded}" ]]; then
    printOutput "1" "Unable to encode artist description for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi

# Update the metadata
if callCurlPut "${plexAdd}/library/sections/${audioLibraryId}/all?type=8&id=${1}&includeExternalMedia=1&titleSort.value=${showNameEncoded}&summary.value=${showDescEncoded}&title.locked=1&titleSort.locked=1&summary.locked=1&X-Plex-Token=${plexToken}"; then
    printOutput "4" "Metadata for artist [${showName}] sucessfully updated"
else
    printOutput "1" "Metadata for artist [${showName}] failed"
fi

# Download the artist image to their directory
chanDir="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${channelId}';")"
dbReply="$(sqDb "SELECT IMAGE FROM source_channels WHERE ID = '${channelId}';")"
if [[ -n "${dbReply}" ]]; then
    # If the video directory exists, download it
    if [[ -d "${audioOutputDir}/${chanDir}" ]]; then
        callCurlDownload "${dbReply}" "${audioOutputDir}/${chanDir}/artist.jpg"
    fi
fi
# Get the background image, if one exists
dbReply="$(sqDb "SELECT BANNER FROM source_channels WHERE ID = '${channelId}';")"
if [[ -n "${dbReply}" ]]; then
    # If the video directory exists, download it
    if [[ -d "${audioOutputDir}/${chanDir}" ]]; then
        callCurlDownload "${dbReply}" "${audioOutputDir}/${chanDir}/background.jpg"
    fi
fi

# Set the artist image, since this can't be done simply by folder
if callCurlPost "${plexAdd}/library/metadata/${1}/posters?X-Plex-Token=${plexToken}" --data-binary "@${audioOutputDir}/${chanDir}/artist.jpg"; then
    printOutput "4" "Artist image for [${showName}] successfully updated"
else
    printOutput "1" "Artist image for [${showName}] update failed"
fi

# Set the background image, since this can't be done simply by folder
if [[ -e "${audioOutputDir}/${chanDir}/background.jpg" ]]; then
    if callCurlPost "${plexAdd}/library/metadata/${1}/arts?X-Plex-Token=${plexToken}" --data-binary "@${audioOutputDir}/${chanDir}/background.jpg"; then
        printOutput "4" "Background image for [${showName}] successfully updated"
    else
        printOutput "1" "Background image for [${showName}] update failed"
    fi
fi
}

function setAlbumMetadata {
# Get the file ID from the rating key
ytId="$(sqDb "SELECT ID FROM audio_rating_key_by_album WHERE RATING_KEY = '${1}';")"

# Get the channel ID
artistChanId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${ytId}';")"

# Get the album title -- ${albumName}
albumName="$(sqDb "SELECT TITLE FROM source_videos WHERE ID = '${ytId}';")"
if [[ -z "${albumName}" ]]; then
    printOutput "1" "Unable to retrieve album name for file ID [${ytId}] -- Possible database corruption"
    return 1
fi
# Encode it -- ${albumNameEncoded}
albumNameEncoded="$(rawurlencode "${albumName}")"

# Get the album artist -- ${artistName}
artistName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${artistChanId}';")"
if [[ -z "${artistName}" ]]; then
    printOutput "1" "Unable to retrieve artist name for file ID [${ytId}] -- Possible database corruption"
    return 1
fi
# Encode it -- ${artistNameEncoded}
artistNameEncoded="$(rawurlencode "${artistName}")"

# Get the originally available date YYYY-MM-DD -- ${albumCreation}
albumCreation="$(sqDb "SELECT TIMESTAMP FROM source_videos WHERE ID = '${ytId}';")"
if ! validateInterger "${albumCreation}"; then
    printOutput "1" "Variable albumCreation [${albumCreation}] failed to validate -- Unable to continue"
    return 1
fi
# Convert it to YYYY-MM-DD
albumCreation="$(date --date="@${albumCreation}" "+%Y-%m-%d")"

# Get the description [Review] -- ${albumDesc}
albumDesc="$(sqDb "SELECT DESC FROM source_videos WHERE ID = '${ytId}';")"
if [[ -z "${albumDesc}" ]]; then
    albumDesc="https://www.youtube.com/watch?v=${ytId}"
else
    albumDesc="https://www.youtube.com/watch?v=${ytId}${lineBreak}-----${lineBreak}${albumDesc}"
fi
# Encode it -- ${albumDescEncoded}
albumDescEncoded="$(rawurlencode "${albumDesc}")"

# Call curl PUT:
if callCurlPut "${plexAdd}/library/sections/${audioLibraryId}/all?type=9&id=${1}&includeExternalMedia=1&title.value=${albumNameEncoded}&titleSort.value=${albumNameEncoded}&artist.title.value=${artistNameEncoded}&summary.value=${albumDescEncoded}&studio.value=YouTube&originallyAvailableAt.value=${albumCreation}&summary.locked=1&title.locked=1&titleSort.locked=1&originallyAvailableAt.locked=1&studio.locked=1&X-Plex-Token=${plexToken}"; then
    printOutput "4" "Metadata for album [${albumName}] updated"
else
    printOutput "1" "Metadata update for album [${albumName}] with channel ID [${artistChanId}] and file ID [${ytId}] failed"
fi
}

function printAngryWarning {
printOutput "2" " __          __              _             _ "
printOutput "2" " \ \        / /             (_)           | |"
printOutput "2" "  \ \  /\  / /_ _ _ __ _ __  _ _ __   __ _| |"
printOutput "2" "   \ \/  \/ / _\` | '__| '_ \| | '_ \ / _\` | |"
printOutput "2" "    \  /\  / (_| | |  | | | | | | | | (_| |_|"
printOutput "2" "     \/  \/ \__,_|_|  |_| |_|_|_| |_|\__, (_)"
printOutput "2" "                                      __/ |  "
printOutput "2" "                                     |___/   "
}

function getChannelCountry {
case "${1}" in
    AF) chanCountry="Afghanistan";;
    AX) chanCountry="Aland Islands";;
    AL) chanCountry="Albania";;
    DZ) chanCountry="Algeria";;
    AS) chanCountry="American Samoa";;
    AD) chanCountry="Andorra";;
    AO) chanCountry="Angola";;
    AI) chanCountry="Anguilla";;
    AQ) chanCountry="Antarctica";;
    AG) chanCountry="Antigua And Barbuda";;
    AR) chanCountry="Argentina";;
    AM) chanCountry="Armenia";;
    AW) chanCountry="Aruba";;
    AU) chanCountry="Australia";;
    AT) chanCountry="Austria";;
    AZ) chanCountry="Azerbaijan";;
    BS) chanCountry="the Bahamas";;
    BH) chanCountry="Bahrain";;
    BD) chanCountry="Bangladesh";;
    BB) chanCountry="Barbados";;
    BY) chanCountry="Belarus";;
    BE) chanCountry="Belgium";;
    BZ) chanCountry="Belize";;
    BJ) chanCountry="Benin";;
    BM) chanCountry="Bermuda";;
    BT) chanCountry="Bhutan";;
    BO) chanCountry="Bolivia";;
    BQ) chanCountry="Bonaire";;
    BA) chanCountry="Bosnia And Herzegovina";;
    BW) chanCountry="Botswana";;
    BV) chanCountry="Bouvet Island";;
    BR) chanCountry="Brazil";;
    IO) chanCountry="British Indian Ocean Territory";;
    BN) chanCountry="Brunei Darussalam";;
    BG) chanCountry="Bulgaria";;
    BF) chanCountry="Burkina Faso";;
    BI) chanCountry="Burundi";;
    KH) chanCountry="Cambodia";;
    CM) chanCountry="Cameroon";;
    CA) chanCountry="Canada";;
    CV) chanCountry="Cape Verde";;
    KY) chanCountry="the Cayman Islands";;
    CF) chanCountry="the Central African Republic";;
    TD) chanCountry="Chad";;
    CL) chanCountry="Chile";;
    CN) chanCountry="China";;
    CX) chanCountry="Christmas Island";;
    CC) chanCountry="Cocos Keeling Islands";;
    CO) chanCountry="Colombia";;
    KM) chanCountry="the Comoros";;
    CG) chanCountry="Congo";;
    CK) chanCountry="Cook Islands";;
    CR) chanCountry="Costa Rica";;
    CI) chanCountry="Cote D'ivoire";;
    HR) chanCountry="Croatia";;
    CU) chanCountry="Cuba";;
    CW) chanCountry="Curacao";;
    CY) chanCountry="Cyprus";;
    CZ) chanCountry="the Czech Republic";;
    DK) chanCountry="Denmark";;
    DJ) chanCountry="Djibouti";;
    DM) chanCountry="Dominica";;
    DO) chanCountry="the Dominican Republic";;
    EC) chanCountry="Ecuador";;
    EG) chanCountry="Egypt";;
    SV) chanCountry="El Salvador";;
    GQ) chanCountry="Equatorial Guinea";;
    ER) chanCountry="Eritrea";;
    EE) chanCountry="Estonia";;
    ET) chanCountry="Ethiopia";;
    FK) chanCountry="the Falkland Islands Malvinas";;
    FO) chanCountry="Faroe Islands";;
    FJ) chanCountry="Fiji";;
    FI) chanCountry="Finland";;
    FR) chanCountry="France";;
    GF) chanCountry="French Guiana";;
    PF) chanCountry="French Polynesia";;
    TF) chanCountry="French Southern Territories";;
    GA) chanCountry="Gabon";;
    GM) chanCountry="Gambia";;
    GE) chanCountry="Georgia";;
    DE) chanCountry="Germany";;
    GH) chanCountry="Ghana";;
    GI) chanCountry="Gibraltar";;
    GR) chanCountry="Greece";;
    GL) chanCountry="Greenland";;
    GD) chanCountry="Grenada";;
    GP) chanCountry="Guadeloupe";;
    GU) chanCountry="Guam";;
    GT) chanCountry="Guatemala";;
    GG) chanCountry="Guernsey";;
    GN) chanCountry="Guinea";;
    GW) chanCountry="Guinea-Bissau";;
    GY) chanCountry="Guyana";;
    HT) chanCountry="Haiti";;
    HM) chanCountry="Heard Mcdonald Islands";;
    HN) chanCountry="Honduras";;
    HK) chanCountry="Hong Kong";;
    HU) chanCountry="Hungary";;
    IS) chanCountry="Iceland";;
    IN) chanCountry="India";;
    ID) chanCountry="Indonesia";;
    IR) chanCountry="Iran";;
    IQ) chanCountry="Iraq";;
    IE) chanCountry="Ireland";;
    IM) chanCountry="the Isle Of Man";;
    IL) chanCountry="Israel";;
    IT) chanCountry="Italy";;
    JM) chanCountry="Jamaica";;
    JP) chanCountry="Japan";;
    JE) chanCountry="Jersey";;
    JO) chanCountry="Jordan";;
    KZ) chanCountry="Kazakhstan";;
    KE) chanCountry="Kenya";;
    KI) chanCountry="Kiribati";;
    KP) chanCountry="North Korea";;
    KR) chanCountry="South Korea";;
    XK) chanCountry="Kosovo";;
    KW) chanCountry="Kuwait";;
    KG) chanCountry="Kyrgyzstan";;
    LA) chanCountry="Laos";;
    LV) chanCountry="Latvia";;
    LB) chanCountry="Lebanon";;
    LS) chanCountry="Lesotho";;
    LR) chanCountry="Liberia";;
    LY) chanCountry="Libya";;
    LI) chanCountry="Liechtenstein";;
    LT) chanCountry="Lithuania";;
    LU) chanCountry="Luxembourg";;
    MO) chanCountry="Macao";;
    MK) chanCountry="Macedonia";;
    MG) chanCountry="Madagascar";;
    MW) chanCountry="Malawi";;
    MY) chanCountry="Malaysia";;
    MV) chanCountry="the Maldives";;
    ML) chanCountry="Mali";;
    MT) chanCountry="Malta";;
    MH) chanCountry="the Marshall Islands";;
    MQ) chanCountry="Martinique";;
    MR) chanCountry="Mauritania";;
    MU) chanCountry="Mauritius";;
    YT) chanCountry="Mayotte";;
    MX) chanCountry="Mexico";;
    FM) chanCountry="Micronesia";;
    MD) chanCountry="Moldova";;
    MC) chanCountry="Monaco";;
    MN) chanCountry="Mongolia";;
    ME) chanCountry="Montenegro";;
    MS) chanCountry="Montserrat";;
    MA) chanCountry="Morocco";;
    MZ) chanCountry="Mozambique";;
    MM) chanCountry="Myanmar";;
    NA) chanCountry="Namibia";;
    NR) chanCountry="Nauru";;
    NP) chanCountry="Nepal";;
    NL) chanCountry="the Netherlands";;
    NC) chanCountry="New Caledonia";;
    NZ) chanCountry="New Zealand";;
    NI) chanCountry="Nicaragua";;
    NE) chanCountry="Niger";;
    NG) chanCountry="Nigeria";;
    NU) chanCountry="Niue";;
    NF) chanCountry="Norfolk Island";;
    MP) chanCountry="Northern Mariana Islands";;
    NO) chanCountry="Norway";;
    OM) chanCountry="Oman";;
    PK) chanCountry="Pakistan";;
    PW) chanCountry="Palau";;
    PS) chanCountry="Palestinian Territory";;
    PA) chanCountry="Panama";;
    PG) chanCountry="Papua New Guinea";;
    PY) chanCountry="Paraguay";;
    PE) chanCountry="Peru";;
    PH) chanCountry="the Philippines";;
    PN) chanCountry="Pitcairn";;
    PL) chanCountry="Poland";;
    PT) chanCountry="Portugal";;
    PR) chanCountry="Puerto Rico";;
    QA) chanCountry="Qatar";;
    RE) chanCountry="Reunion";;
    RO) chanCountry="Romania";;
    RU) chanCountry="Russia";;
    RW) chanCountry="Rwanda";;
    BL) chanCountry="Saint Barthelemy";;
    SH) chanCountry="Saint Helena";;
    KN) chanCountry="Saint Kitts And Nevis";;
    LC) chanCountry="Saint Lucia";;
    MF) chanCountry="Saint Martin French";;
    PM) chanCountry="Saint Pierre And Miquelon";;
    VC) chanCountry="Saint Vincent And Grenadines";;
    WS) chanCountry="Samoa";;
    SM) chanCountry="San Marino";;
    ST) chanCountry="Sao Tome And Principe";;
    SA) chanCountry="Saudi Arabia";;
    SN) chanCountry="Senegal";;
    RS) chanCountry="Serbia";;
    SC) chanCountry="Seychelles";;
    SL) chanCountry="Sierra Leone";;
    SG) chanCountry="Singapore";;
    SX) chanCountry="Sint Maarten Dutch";;
    SK) chanCountry="Slovakia";;
    SI) chanCountry="Slovenia";;
    SB) chanCountry="Solomon Islands";;
    SO) chanCountry="Somalia";;
    ZA) chanCountry="South Africa";;
    GS) chanCountry="South Georgia And South Sandwich Islands";;
    SS) chanCountry="South Sudan";;
    ES) chanCountry="Spain";;
    LK) chanCountry="Sri Lanka";;
    SD) chanCountry="Sudan";;
    SR) chanCountry="Suriname";;
    SJ) chanCountry="Svalbard And Jan Mayen";;
    SZ) chanCountry="Swaziland";;
    SE) chanCountry="Sweden";;
    CH) chanCountry="Switzerland";;
    SY) chanCountry="Syria";;
    TW) chanCountry="Taiwan";;
    TJ) chanCountry="Tajikistan";;
    TZ) chanCountry="Tanzania";;
    TH) chanCountry="Thailand";;
    TL) chanCountry="Timor-Leste";;
    TG) chanCountry="Togo";;
    TK) chanCountry="Tokelau";;
    TO) chanCountry="Tonga";;
    TT) chanCountry="Trinidad And Tobago";;
    TN) chanCountry="Tunisia";;
    TR) chanCountry="Turkey";;
    TM) chanCountry="Turkmenistan";;
    TC) chanCountry="the Turks And Caicos Islands";;
    TV) chanCountry="Tuvalu";;
    UG) chanCountry="Uganda";;
    UA) chanCountry="Ukraine";;
    AE) chanCountry="the United Arab Emirates";;
    GB) chanCountry="the United Kingdom";;
    US) chanCountry="the United States";;
    UM) chanCountry="the U.S. Minor Outlying Islands";;
    UY) chanCountry="Uruguay";;
    UZ) chanCountry="Uzbekistan";;
    VU) chanCountry="Vanuatu";;
    VA) chanCountry="Vatican Holy See";;
    VE) chanCountry="Venezuela";;
    VN) chanCountry="Vietnam";;
    VG) chanCountry="the Virgin Islands British";;
    VI) chanCountry="the Virgin Islands U.S.";;
    WF) chanCountry="Wallis And Futuna";;
    EH) chanCountry="Western Sahara";;
    YE) chanCountry="Yemen";;
    ZM) chanCountry="Zambia";;
    ZW) chanCountry="Zimbabwe";;
    *) return 1;; ### SKIP CONDITION
esac
}

function ytApiCall {
if [[ "${#ytApiKeys[@]}" -ne "0" ]]; then
    useLemnos="0"
    if [[ -z "${apiKeyNum}" ]]; then
        apiKeyNum="0"
    fi
    # Use a YouTube API key, with no throttling
    callCurl "https://www.googleapis.com/youtube/v3/${1}&key=${ytApiKeys[${apiKeyNum}]}"
    (( apiCallsYouTube++ ))
    # Check for a 400 or 403 error code
    errorCode="$(yq -p json ".error.code" <<<"${curlOutput}")"
    while [[ "${errorCode}" == "403" || "${errorCode}" == "400" ]]; do
        if [[ "${errorCode}" == "403" ]]; then
            printOutput "2" "API key [#${apiKeyNum}] exhaused, rotating to next available key"
        elif [[ "${errorCode}" == "400" ]]; then
            printOutput "1" "API key [${ytApiKeys[${apiKeyNum}]}] appears to be invalid"
            printOutput "2" "Rotating to next available API key"
        fi
        (( apiKeyNum++ ))
        if [[ -n "${ytApiKeys[${apiKeyNum}]}" ]]; then
            # Call curl again
            callCurl "https://www.googleapis.com/youtube/v3/${1}&key=${ytApiKeys[${apiKeyNum}]}"
            (( apiCallsYouTube++ ))
            errorCode="$(yq -p json ".error.code" <<<"${curlOutput}")"
        else
            # We've exhaused our keys, switch the Lemnos
            unset ytApiKeys
            useLemnos="1"
        fi
    done
else
    useLemnos="1"
fi

if [[ "${useLemnos}" -eq "1" ]]; then
    # Use the free/no-key lemnoslife API, and throttle ourselves out of courtesy
    callCurl "https://yt.lemnoslife.com/noKey/${1}"
    (( apiCallsLemnos++ ))
    randomSleep "3" "7"
fi
}

function compareFileIdToDb {
# Check to see if the video is already in the database or not
if [[ "${verifyMedia}" -eq "1" ]]; then
    configLevel="4"
    sponsorblockOpts="disable"
    vidIncludeShorts="true"
    audIncludeShorts="false"
    includeLiveBroadcasts="false"
    markWatched="false"
    if [[ "${newMediaType}" == "video" ]]; then
        videoOutput="original"
        audioOutput="none"
        vidStatus="downloaded"
        audStatus="skipped"
    elif [[ "${newMediaType}" == "audio" ]]; then
        if [[ -z "${2}" ]]; then
            badExit "109" "No audio type passed for new media update"
        fi
        videoOutput="none"
        audioOutput="${2}"
        vidStatus="skipped"
        audStatus="downloaded"
    else
        badExit "110" "Impossible condition"
    fi
fi

printOutput "5" "Entered 'compareFileIdToDb' with config level [${configLevel}]"

dbReply="$(sqDb "SELECT COUNT(1) FROM source_videos WHERE ID = '${1}';")"
if ! validateInterger "${dbReply}"; then
    printOutput "1" "Variable dbReply [${dbReply}] failed to validate -- Unable to continue"
    return 1
fi

if [[ "${dbReply}" -ge "2" ]]; then
    badExit "111" "Database returned count [${dbReply}] -- Possible database corruption"
elif [[ "${dbReply}" -eq "1" ]]; then
    # Grab the title
    assignTitle "${1}"
    printOutput "5" "Found one instance of file ID [${1}] in database"
    # The entry exists in the database, we should compare the existing config level to the current one.
    # If the current one is lower, then we should update the source accordingly.
    configReply="$(sqDb "SELECT CONFIG FROM source_videos WHERE ID = '${1}';")"
    # Either reply will want to know what type of video it is
    videoType="$(sqDb "SELECT TYPE FROM source_videos WHERE ID = '${1}';")"
    if [[ "${configReply}" -gt "${configLevel}" ]]; then
        printOutput "5" "Database config level outranked for file ID [${1}]"
        # This video has already been indexed, and we outrank the previous config, so we just need to update the relevant config options

        # Check to see what the existing VID_FORMAT and AUD_FORMAT are
        configVidFormat="$(sqDb "SELECT VID_FORMAT FROM source_videos WHERE ID = '${1}';")"
        # Validate it. This has already been safety checked, so we just need to verify a non-empty output.
        if [[ -z "${configVidFormat}" ]]; then
            badExit "112" "Existing video format lookup returned blank result for file ID [${1}] -- Possible database corruption"
        fi
        if ! [[ "${configVidFormat}" == "none" ]]; then
            # Get the file status
            vidStatus="$(sqDb "SELECT VID_STATUS FROM source_videos WHERE ID = '${1}';")"
            # Validate it. This has already been safety checked, so we just need to verify a non-empty output.
            if [[ -z "${vidStatus}" ]]; then
                badExit "113" "Existing video status lookup returned blank result for file ID [${1}] -- Possible database corruption"
            fi

            # It is not none, and we outrank whatever it is
            # If we are 'none', we should not replace whatever the config option is
            if [[ "${videoOutput}" == "none" ]]; then
                # For preserving video, we should preserve set SB_OPTIONS, VID_SHORTS_DL, LIVE, and WATCHED
                videoOutput="${configVidFormat}"
                sponsorblockOpts="$(sqDb "SELECT SB_OPTIONS FROM source_videos WHERE ID = '${1}';")"
                # Validate it. This has already been safety checked, so we just need to verify a non-empty output.
                if [[ -z "${sponsorblockOpts}" ]]; then
                    badExit "114" "Existing video sponsorblock option lookup returned blank result for file ID [${1}] -- Possible database corruption"
                fi
                vidIncludeShorts="$(sqDb "SELECT VID_SHORTS_DL FROM source_videos WHERE ID = '${1}';")"
                # Validate it. This has already been safety checked, so we just need to verify a non-empty output.
                if [[ -z "${vidIncludeShorts}" ]]; then
                    badExit "115" "Existing video include shorts option lookup returned blank result for file ID [${1}] -- Possible database corruption"
                fi
                includeLiveBroadcasts="$(sqDb "SELECT LIVE FROM source_videos WHERE ID = '${1}';")"
                # Validate it. This has already been safety checked, so we just need to verify a non-empty output.
                if [[ -z "${includeLiveBroadcasts}" ]]; then
                    badExit "116" "Existing video live broadcast option lookup returned blank result for file ID [${1}] -- Possible database corruption"
                fi
                markWatched="$(sqDb "SELECT WATCHED FROM source_videos WHERE ID = '${1}';")"
                # Validate it. This has already been safety checked, so we just need to verify a non-empty output.
                if [[ -z "${markWatched}" ]]; then
                    badExit "117" "Existing video mark as watched option lookup returned blank result for file ID [${1}] -- Possible database corruption"
                fi
            else
                if ! [[ "${vidStatus}" == "downloaded" ]]; then
                    if [[ "${vidIncludeShorts}" == "true" && "${videoType}" == "short" ]]; then
                        # Replace it with our data
                        vidStatus="queued"
                    elif [[ "${vidIncludeShorts}" == "false" ]] && ! [[ "${videoType}" == "short" ]]; then
                        vidStatus="queued"
                    else
                        vidStatus="skipped"
                    fi
                fi
            fi
        fi

        configAudFormat="$(sqDb "SELECT AUD_FORMAT FROM source_videos WHERE ID = '${1}';")"
        # Validate it. This has already been safety checked, so we just need to verify a non-empty output.
        if [[ -z "${configAudFormat}" ]]; then
            badExit "118" "Existing audio format lookup returned blank result for file ID [${1}] -- Possible database corruption"
        fi
        audStatus="$(sqDb "SELECT AUD_STATUS FROM source_videos WHERE ID = '${1}';")"
        if ! [[ "${configAudFormat}" == "none" ]]; then
            # It is not none, and we outrank whatever it is
            # If we are 'none', we should not replace whatever the config option is
            # Get the file status
            # Validate it. This has already been safety checked, so we just need to verify a non-empty output.
            if [[ -z "${audStatus}" ]]; then
                badExit "119" "Existing audio status lookup returned blank result for file ID [${1}] -- Possible database corruption"
            fi
            audIncludeShorts="$(sqDb "SELECT AUD_SHORTS_DL FROM source_videos WHERE ID = '${1}';")"
            # Validate it. This has already been safety checked, so we just need to verify a non-empty output.
            if [[ -z "${audIncludeShorts}" ]]; then
                badExit "120" "Existing audio include shorts option lookup returned blank result for file ID [${1}] -- Possible database corruption"
            fi
        fi
        if [[ "${audioOutput}" == "none" ]]; then
            audioOutput="${configAudFormat}"
        else
            printOutput "5" "Audio status: ${audStatus}"
            printOutput "5" "Include shorts: ${audIncludeShorts}"
            printOutput "5" "Include live: ${includeLiveBroadcasts}"
            printOutput "5" "Video type: ${videoType}"
            if ! [[ "${audStatus}" == "downloaded" ]]; then
                if [[ "${audIncludeShorts}" == "true" && "${videoType}" == "short" ]]; then
                    # Shorts are allowed, and the video type is a short
                    audStatus="queued"
                elif [[ "${audIncludeShorts}" == "false" && "${videoType}" == "short" ]]; then
                    # Shorts are not allowed, and the video type is a short
                    audStatus="skipped"
                elif [[ "${includeLiveBroadcasts}" == "true" && "${videoType}" == "waslive" ]]; then
                    # Previous live broadcasts are allowed, and the video type is a previous live broadcast
                    audStatus="queued"
                elif [[ "${includeLiveBroadcasts}" == "false" && "${videoType}" == "waslive" ]]; then
                    # Previous live broadcasts are not allowed, and the video type is a previous live broadcast
                    audStatus="skipped"
                else
                    # Everything else can be queued, since this format is wanted
                    audStatus="queued"
                fi
            fi
        fi

        if sqDb "UPDATE source_videos SET CONFIG = '${configLevel}', SB_OPTIONS = '${sponsorblockOpts}', VID_FORMAT = '${videoOutput}', AUD_FORMAT = '${audioOutput}', VID_SHORTS_DL = '${vidIncludeShorts}', AUD_SHORTS_DL = '${audIncludeShorts}', LIVE = '${includeLiveBroadcasts}', WATCHED = '${markWatched}', VID_STATUS = '${vidStatus}', AUD_STATUS = '${audStatus}', UPDATED = '$(date +%s)' WHERE ID = '${1}' ;"; then
            printOutput "3" "Updated file ID [${1}] in database"
        else
            badExit "121" "Update of file ID [${1}] in database failed"
        fi
    else
        # We do not outrank the current config; however, the current config may exclude audio/video we want.
        # Check and see if we have 'none' for audio or video format
        configVidFormat="$(sqDb "SELECT VID_FORMAT FROM source_videos WHERE ID = '${1}';")"
        if [[ "${configVidFormat}" == "none" ]]; then
            # Nothing is set. Do we have a value to set?
            if ! [[ "${videoOutput}" == "none" ]]; then
                # Yes, so let's set it.
                if [[ "${newMediaType}" == "video" ]]; then
                    vidStatus="downloaded"
                else
                    vidStatus="queued"
                fi
                # For setting video, we should also set SB_OPTIONS, VID_SHORTS_DL, LIVE, and WATCHED. These have already been verified.
                if sqDb "UPDATE source_videos SET SB_OPTIONS = '${sponsorblockOpts}', VID_FORMAT = '${videoOutput}', VID_SHORTS_DL = '${vidIncludeShorts}', LIVE = '${includeLiveBroadcasts}', WATCHED = '${markWatched}', VID_STATUS = '${vidStatus}', UPDATED = '$(date +%s)' WHERE ID = '${1}' ;"; then
                    printOutput "3" "Updated file ID [${1}] in database"
                else
                    badExit "122" "Update of file ID [${1}] in database failed"
                fi
            fi
        fi

        configAudFormat="$(sqDb "SELECT AUD_FORMAT FROM source_videos WHERE ID = '${1}';")"
        if [[ "${configAudFormat}" == "none" ]]; then
            # Nothing is set. Do we have a value to set?
            if ! [[ "${audioOutput}" == "none" ]]; then
                # Yes, so let's set it.
                if [[ "${newMediaType}" == "audio" ]]; then
                    audStatus="downloaded"
                else
                    if [[ "${audIncludeShorts}" == "true" && "${videoType}" == "short" ]]; then
                    # Shorts are allowed, and the video type is a short
                    audStatus="queued"
                    elif [[ "${audIncludeShorts}" == "false" && "${videoType}" == "short" ]]; then
                        # Shorts are not allowed, and the video type is a short
                        audStatus="skipped"
                    elif [[ "${includeLiveBroadcasts}" == "true" && "${videoType}" == "waslive" ]]; then
                        # Previous live broadcasts are allowed, and the video type is a previous live broadcast
                        audStatus="queued"
                    elif [[ "${includeLiveBroadcasts}" == "false" && "${videoType}" == "waslive" ]]; then
                        # Previous live broadcasts are not allowed, and the video type is a previous live broadcast
                        audStatus="skipped"
                    else
                        # Everything else can be queued, since this format is wanted
                        audStatus="queued"
                    fi
                fi
                if sqDb "UPDATE source_videos SET AUD_FORMAT = '${audioOutput}', AUD_SHORTS_DL = '${audIncludeShorts}', AUD_STATUS = '${audStatus}', UPDATED = '$(date +%s)' WHERE ID = '${1}' ;"; then
                    printOutput "3" "Updated file ID [${1}] in database"
                else
                    badExit "123" "Update of file ID [${1}] in database failed"
                fi
            fi
        fi
    fi
elif [[ "${dbReply}" -eq "0" ]]; then
    # It's not in the database
    unset vidTitle channelId epochDate uploadYear
    # Get the video info
    # Because we can't get the time string through yt-dlp, there's no point in trying to use it as our fake API here, we *have* to API query YouTube
    # Query the YouTube API for the video info
    printOutput "5" "Calling API for video info [${1}]"
    ytApiCall "videos?id=${1}&part=snippet,liveStreamingDetails"
    # Check to make sure we got a result
    apiResults="$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")"
    if ! validateInterger "${apiResults}"; then
        printOutput "1" "Variable apiResults [${apiResults}] failed to validate -- Unable to continue"
        return 1
    fi
    if [[ "${apiResults}" -eq "0" ]]; then
        printOutput "2" "API lookup for video zero results (Is the video private?)"
        if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
            printOutput "3" "Re-attempting video ID lookup via yt-dlp + cookie"
            dlpApiCall="$(yt-dlp --no-warnings -J --cookies "${cookieFile}" "https://www.youtube.com/watch?v=${1}" 2>/dev/null)"
            throttleDlp
            
            if [[ "$(yq -p json ".id" <<<"${dlpApiCall}")" == "${1}" ]]; then
                # Yes, it's a private video we can auth via cookie
                printOutput "3" "Lookup via cookie auth successful"
                # Get the video title
                vidTitle="$(yq -p json ".title" <<<"${dlpApiCall}")"
                # Get the video description
                # Blank if none set
                vidDesc="$(yq -p json ".description" <<<"${dlpApiCall}")"
                # Get the channel ID
                channelId="$(yq -p json ".channel_id" <<<"${dlpApiCall}")"
                # Get the channel name
                chanName="$(yq -p json ".channel" <<<"${dlpApiCall}")"
                # This is not provided by the yt-dlp payload. It cannot be looked up via the official API without oauth,
                # which I do not want to implement for a number of reasons. Instead, I am going to get this via some very
                # shameful code. Please do not read the below 3 lines, I am ashamed of them.
                uploadDate="$(curl -b "${cookieFile}" -skL "https://www.youtube.com/watch?v=${1}" | grep -E -o "<meta itemprop=\"datePublished\" content=\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}\">")"
                uploadDate="${uploadDate%\">}"
                uploadDate="${uploadDate##*\"}"
                # Ok I'm done, you can read it again.
                videoType="$(yq -p json ".live_status" <<<"${dlpApiCall}")"
                # We just need this to be a non-null value
                broadcastStart="ytdlp"
            else
                printOutput "1" "Unable to preform lookup on file ID [${1}] via yt-dlp -- Skipping"
                return 1
            fi
        else
            printOutput "1" "File ID [${1}] API lookup failed, and no cookie file provided to attempt to yt-dlp lookup -- Skipping"
            return 1
        fi
    elif [[ "${apiResults}" -eq "1" ]]; then
        # Get the video title
        vidTitle="$(yq -p json ".items[0].snippet.title" <<<"${curlOutput}")"
        # Get the video description
        # Blank if none set
        vidDesc="$(yq -p json ".items[0].snippet.description" <<<"${curlOutput}")"
        # Get the channel ID
        channelId="$(yq -p json ".items[0].snippet.channelId" <<<"${curlOutput}")"
        # Get the channel name
        chanName="$(yq -p json ".items[0].snippet.channelTitle" <<<"${curlOutput}")"
        # Get the upload date
        uploadDate="$(yq -p json ".items[0].snippet.publishedAt" <<<"${curlOutput}")"
        # Get the video type (Check to see if it's a live broadcast)
        videoType="$(yq -p json ".items[0].snippet.liveBroadcastContent" <<<"${curlOutput}")"
        # Get the broadcast start time (Will only return value if it's a live broadcast)
        broadcastStart="$(yq -p json ".items[0].liveStreamingDetails.actualStartTime" <<<"${curlOutput}")"
    else
        badExit "124" "Impossible condition"
    fi

    # Validate the video title
    if [[ -z "${vidTitle}" ]]; then
        ### SKIP CONDITION
        printOutput "1" "Video title returned blank result [${vidTitle}]"
        return 1
    fi
    # Save this for later
    vidTitleClean="${vidTitle}"
    vidTitleOrig="${vidTitle}"
    if [[ -z "${titleById[_${1}]}" ]]; then
        titleById["_${1}"]="$(sqDb "SELECT TITLE FROM source_videos WHERE ID = '${1}';")"
    fi
    # Clean the title up for sqlite
    vidTitle="${vidTitle//\'/\'\'}"

    # Get the video title with filesystem safe characters
    # Trim any leading spaces and/or periods
    while [[ "${vidTitleClean:0:1}" =~ ^( |\.)$ ]]; do
        vidTitleClean="${vidTitleClean# }"
        vidTitleClean="${vidTitleClean#\.}"
    done
    # Trim any trailing spaces and/or periods
    while [[ "${vidTitleClean:$(( ${#vidTitleClean} - 1 )):1}" =~ ^( |\.)$ ]]; do
        vidTitleClean="${vidTitleClean% }"
        vidTitleClean="${vidTitleClean%\.}"
    done
    # Replace any forward or back slashes \ /
    vidTitleClean="${vidTitleClean//\//_}"
    vidTitleClean="${vidTitleClean//\\/_}"
    # Replace any colons :
    vidTitleClean="${vidTitleClean//:/}"
    # Replace any stars *
    vidTitleClean="${vidTitleClean//\*/}"
    # Replace any question marks ?
    vidTitleClean="${vidTitleClean//\?/}"
    # Replace any quotation marks "
    vidTitleClean="${vidTitleClean//\"/}"
    # Replace any brackets < >
    vidTitleClean="${vidTitleClean//</}"
    vidTitleClean="${vidTitleClean//>/}"
    # Replace any vertical bars |
    vidTitleClean="${vidTitleClean//\|/}"
    # Condense any instances of '_-_'
    while [[ "${vidTitleClean}" =~ .*"_-_".* ]]; do
        vidTitleClean="${vidTitleClean//_-_/ - }"
    done
    # Condense any multiple spaces
    while [[ "${vidTitleClean}" =~ .*"  ".* ]]; do
        vidTitleClean="${vidTitleClean//  / }"
    done
    # Clean the title up for sqlite
    vidTitleClean="${vidTitleClean//\'/\'\'}"

    # If our video description is a single space, we don't want it
    if [[ "${vidDesc}" == " " ]]; then
        unset vidDesc
    fi
    # If we have a description, clean it up for sqlite
    if [[ -n "${vidDesc}" && ! "${vidDesc}" == "null" ]]; then
        vidDesc="${vidDesc//\'/\'\'}"
    fi

    # Validate the channel ID
    if ! [[ "${channelId}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
        ### SKIP CONDITION
        printOutput "1" "Unable to validate channel ID [${channelId}]"
        return 1
    fi
    # Probably unnecessary -- Clean the channel ID up for sqlite
    channelId="${channelId//\'/\'\'}"

    # Validate the upload date, by making sure it's not blank (Format can vary)
    if [[ -z "${uploadDate}" ]]; then
        printOutput "1" "Upload date lookup failed for video [${1}]"
        return 1
    fi
    # Convert the date to a Unix timestamp
    epochDate="$(date --date="${uploadDate}" "+%s")"
    if ! [[ "${epochDate}" =~ ^[0-9]+$ ]]; then
        ### SKIP CONDITION
        printOutput "1" "Unable to convert upload date to unix epoch timestamp [${uploadDate}][${epochDate}]"
        return 1
    fi
    # Extract the year, so we can match the video to a season
    uploadYear="${uploadDate:0:4}"
    if ! [[ "${uploadYear}" =~ ^[0-9]{4}$ ]]; then
        ### SKIP CONDITION
        printOutput "1" "Unable to extract year from video [${uploadDate}][${uploadYear}]"
        return 1
    fi

    # Validate the video type
    if [[ -z "${videoType}" ]]; then
        printOutput "1" "Video type lookup returned blank result [${videoType}]"
        return 1
    elif [[ "${videoType}" == "none" || "${videoType}" == "not_live" || "${videoType}" == "was_live" ]]; then
        # Not currently live
        # Check to see if it's a previous broadcast
        if [[ -z "${broadcastStart}" ]]; then
            # This should not be blank, it should be 'null' or a date/time
            printOutput "1" "Broadcast start time lookup returned blank result [${broadcastStart}] -- Skipping"
            return 1
        elif [[ "${broadcastStart}" == "null" || "${videoType}" == "not_live" ]]; then
            # It doesn't have one. Must be a short, or a regular video.
            # Use our bullshit to find out
            httpCode="$(curl -m 15 -s -I -o /dev/null -w "%{http_code}" "https://www.youtube.com/shorts/${1}")"
            if [[ "${httpCode}" == "000" ]]; then
                # We're being throttled
                printOutput "2" "Throttling detected"
                randomSleep "5" "15"
                httpCode="$(curl -m 15 -s -I -o /dev/null -w "%{http_code}" "https://www.youtube.com/shorts/${1}")"
            fi
            if [[ -z "${httpCode}" ]]; then
                printOutput "1" "Curl lookup to determine video type returned blank result [${httpCode}] -- Skipping"
                return 1
            elif [[ "${httpCode}" == "200" ]]; then
                # It's a short
                printOutput "4" "Determined video to be a short"
                videoType="short"
            elif [[ "${httpCode}" == "303" ]]; then
                # It's a regular video
                printOutput "4" "Determined video to be a standard video"
                videoType="normal"
            elif [[ "${httpCode}" == "404" ]]; then
                # No such video exists
                printOutput "1" "Curl lookup returned HTTP code 404 for file ID [${1}] -- Skipping"
                return 1
            else
                printOutput "1" "Curl lookup to determine file ID [${1}] type returned unexpected result [${httpCode}] -- Skipping"
                return 1
            fi
        elif [[ "${broadcastStart}" =~ ^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$ || "${videoType}" == "was_live" ]]; then
            printOutput "4" "Determined video to be a past live broadcast"
            videoType="waslive"
        else
            printOutput "Broadcast start time lookup returned unexpected result [${broadcastStart}] -- Skipping"
            return 1
        fi
    elif [[ "${videoType}" == "live" || "${videoType}" == "is_live" ]]; then
        # Currently live
        printOutput "1" "File ID [${1}] detected to be a live broadcast, unable to save -- Skipping"
        return 1
    else
        printOutput "1" "File ID [${1}] lookup video type returned invalid result [${videoType}] -- Skipping"
        return 1
    fi

    # Check to see if the channel ID exists in the database
    dbReply="$(sqDb "SELECT COUNT(1) FROM source_channels WHERE ID = '${channelId}';")"
    if ! validateInterger "${dbReply}"; then
        printOutput "1" "Variable dbReply [${dbReply}] failed to validate -- Unable to continue"
        return 1
    fi
    if [[ "${dbReply}" -ge "2" ]]; then
        badExit "125" "Database returned count [${dbReply}] -- Possible database corruption"
    elif [[ "${dbReply}" -eq "1" ]]; then
        # Check the channel ID and channel name for path correctness
        # (Did the channel name change?)
        chanNameDb="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${channelId}';")"
        if ! [[ "${chanNameDb}" == "${chanName}" ]]; then
            printOutput "2" "Channel name for channel ID [${channelId}] has changed from [${chanNameDb}] to [${chanName}]"
            printOutput "4" "Moving channel downloads to correct name directory"
            # Store the channel name for our directory name
            channelNameClean="${chanName}"
            # Store the channel name for stdout
            chanNameOrig="${chanName}"
            # Clean the name up for sqlite
            chanName="${chanName//\'/\'\'}"
            # Trim any leading spaces and/or periods
            while [[ "${channelNameClean:0:1}" =~ ^( |\.)$ ]]; do
                channelNameClean="${channelNameClean# }"
                channelNameClean="${channelNameClean#\.}"
            done
            # Trim any trailing spaces and/or periods
            while [[ "${channelNameClean:$(( ${#channelNameClean} - 1 )):1}" =~ ^( |\.)$ ]]; do
                channelNameClean="${channelNameClean% }"
                channelNameClean="${channelNameClean%\.}"
            done
            # Replace any forward or back slashes \ /
            channelNameClean="${channelNameClean//\//_}"
            channelNameClean="${channelNameClean//\\/_}"
            # Replace any colons :
            channelNameClean="${channelNameClean//:/-}"
            # Replace any stars *
            channelNameClean="${channelNameClean//\*/}"
            # Replace any question marks ?
            channelNameClean="${channelNameClean//\?/}"
            # Replace any quotation marks "
            channelNameClean="${channelNameClean//\"/}"
            # Replace any brackets < >
            channelNameClean="${channelNameClean//</}"
            channelNameClean="${channelNameClean//>/}"
            # Replace any vertical bars |
            channelNameClean="${channelNameClean//\|/}"
            # Condense any instances of '_-_'
            while [[ "${channelNameClean}" =~ .*"_-_".* ]]; do
                channelNameClean="${channelNameClean//_-_/ - }"
            done
            # Condense any multiple spaces
            while [[ "${channelNameClean}" =~ .*"  ".* ]]; do
                channelNameClean="${channelNameClean//  / }"
            done

            # String the whole path together
            chanDir="${channelNameClean} [${channelId}]"

            # Get the old path
            oldChanPath="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${channelId}';")"
            # Get the old clean name, for the file loop
            oldChanCleanName="$(sqDb "SELECT NAME_CLEAN FROM source_channels WHERE ID = '${channelId}';")"

            # We only need to move a video path if one exists
            if [[ -d "${videoOutputDir}/${oldChanPath}" ]]; then
                # It does. Check to make sure there's not already a directory where we want to move to.
                if [[ -d "${videoOutputDir}/${chanDir}" ]]; then
                    badExit "126" "Unable to correct channel ID [${channelId}] name from [${chanNameDb}] to [${chanNameOrig}] -- Directory already exists at [${videoOutputDir}/${chanDir}]"
                fi
                
                # Get the watch status for all items in that old folder
                # Get a list of all the episodes in this series
                while read -r z; do
                    # ${z} is the rating key for each season of a channel ID
                    
                    # Get the watch status for the season
                    callCurl "${plexAdd}/library/metadata/${z}/children?X-Plex-Token=${plexToken}"
                    # For each rating key in this season
                    while read -r zz; do
                        # Media item rating key is zz
                        fId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${zz}\" ) .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                        fId="${fId%\]\.*}"
                        fId="${fId##*\[}"
                        watchStatus="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${zz}\" ) .\"+@viewOffset\"" <<<"${curlOutput}")"
                        if [[ "${watchStatus}" =~ ^[0-9]+$ ]]; then
                            # It's in progress
                            reindexArr["_${fId}"]="${watchStatus}"
                        else
                            # Not in progress, we need to check the view count
                            watchStatus="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${zz}\" ) .\"+@viewCount\"" <<<"${curlOutput}")"
                            if [[ "${watchStatus}" == "null" ]]; then
                                # It's unwatched
                                reindexArr["_${fId}"]="unwatched"
                            else
                                # It's watched
                                reindexArr["_${fId}"]="watched"
                            fi
                        fi
                    done < <(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
                done < <(sqDb "SELECT RATING_KEY FROM video_rating_key_by_season WHERE CHANNEL_ID = '${channelId}';")
                
                # Let's just move the base folder
                if ! mv "${videoOutputDir}/${oldChanPath}" "${videoOutputDir}/${chanDir}"; then
                    badExit "127" "Failed to update channel ID [${channelId}] from [${chanNameDb}] to [${chanNameOrig}]"
                fi
                # Now let's rename each individual video in the series
                movedVids="0"
                while read -r z; do
                    # The yt ID is ${z}, we will need to get the TITLE_CLEAN for each item passed
                    titleClean="$(sqDb "SELECT TITLE_CLEAN FROM source_videos WHERE ID = '${z}';")"
                    # We also need the year (Season)
                    vidYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${z}';")"
                    # We also need the episode index number (Episode number)
                    vidIndex="$(sqDb "SELECT EP_INDEX FROM source_videos WHERE ID = '${z}';")"
                    # Now we have the path of where the video should be
                    if ! mv "${videoOutputDir}/${chanDir}/Season ${vidYear}/${oldChanCleanName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${titleClean} [${z}].mp4" "${videoOutputDir}/${chanDir}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${titleClean} [${z}].mp4"; then
                        badExit "128" "Failed to update video file [S${vidYear}E$(printf '%03d' "${vidIndex}")] for channel ID [${channelId}]"
                    fi
                    if ! mv "${videoOutputDir}/${chanDir}/Season ${vidYear}/${oldChanCleanName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${titleClean} [${z}].jpg" "${videoOutputDir}/${chanDir}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${titleClean} [${z}].jpg"; then
                        badExit "129" "Failed to update video thumbnail [S${vidYear}E$(printf '%03d' "${vidIndex}")] for channel ID [${channelId}]"
                    fi
                    # We've successfully moved the files, let's update our UPDATED timestamp
                    if ! sqDb "UPDATE source_videos SET UPDATED = '$(date +%s)' WHERE ID = '${z}';"; then
                        printOutput "1" "Update for file ID [${z}] failed"
                    fi
                    (( movedVids++ ))
                done < <(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${channelId}';")
            fi

            # Clean the path up for sqlite
            chanPathClean="${chanDir//\'/\'\'}"
            # Clean the name up for sqlite
            channelNameClean="${channelNameClean//\'/\'\'}"
            
            # Update the channel image
            if ! mv "${videoOutputDir}/${chanDir}/show.jpg" "${videoOutputDir}/${chanDir}/show.old.jpg"; then
                printOutput "1" "Failed to back up old channel image"
            fi
            # Setting the 'updateMetadata' flag will cause the 'getChannelInfo' function to update the show and season images
            updateMetadata="1"
            if ! getChannelInfo "${channelId}"; then
                printOutput "1" "Failed to retrieve channel info for [${channelId}]"
            fi
            updateMetadata="0"

            # Drop any old rating key references
            sqDb "DELETE FROM video_rating_key_by_channel WHERE CHANNEL_ID = '${channelId}';"
            sqDb "DELETE FROM video_rating_key_by_season WHERE CHANNEL_ID = '${channelId}';"
            while read -r dbVidId; do
                sqDb "DELETE FROM video_rating_key_by_item WHERE ID = '${dbVidId}';"
            done < <(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${channelId}';")
            
            # Add the new channel to be processed for metadata later
            newVideoDir+=("${channelId}")
            
            # Post the changes to the database
            if ! sqDb "UPDATE source_channels SET NAME = '${chanName}', NAME_CLEAN = '${channelNameClean}', PATH = '${chanPathClean}', UPDATED = '$(date +%s)' WHERE ID = '${channelId}';"; then
                printOutput "1" "Update for channel ID [${channelId}] failed"
            else
                printOutput "3" "Updated channel ID [${channelId}] from [${chanNameDb}] to [${chanNameOrig}] -- Moved [${movedVids}] videos"
            fi
        fi
    elif [[ "${dbReply}" -eq "0" ]]; then
        if ! getChannelInfo "${channelId}"; then
            printOutput "1" "Failed to retrieve channel info for [${channelId}]"
            return 1
        fi
    fi

    # These are already set if we're in verify media mode
    if [[ "${verifyMedia}" -eq "0" ]]; then
        if [[ "${vidIncludeShorts}" == "false" && "${videoType}" == "short" ]]; then
            vidStatus="skipped"
        elif [[ "${videoOutput}" == "none" ]]; then
            vidStatus="skipped"
        else
            vidStatus="queued"
        fi

        if ! [[ "${audioOutput}" == "none" ]]; then
            if [[ "${audIncludeShorts}" == "false" && "${videoType}" == "short" ]]; then
                audStatus="skipped"
            else
                audStatus="queued"
            fi
        else
            audStatus="skipped"
        fi
    fi

    # Insert it into the database
    if sqDb "INSERT INTO source_videos (ID, CONFIG, TITLE, TITLE_CLEAN, CHANNEL_ID, TIMESTAMP, YEAR, SB_OPTIONS, VID_FORMAT, AUD_FORMAT, VID_SHORTS_DL, AUD_SHORTS_DL, LIVE, WATCHED, TYPE, VID_STATUS, AUD_STATUS, UPDATED) VALUES ('${1}', ${configLevel}, '${vidTitle}', '${vidTitleClean}', '${channelId}', ${epochDate}, ${uploadYear}, '${sponsorblockOpts}', '${videoOutput}', '${audioOutput}', '${vidIncludeShorts}', '${audIncludeShorts}', '${includeLiveBroadcasts}', '${markWatched}', '${videoType}', '${vidStatus}', '${audStatus}', $(date +%s));"; then
        printOutput "3" "Added video [${vidTitleOrig}] ID [${1}] to database"
    else
        badExit "130" "Failed to add file ID [${1}] to database"
    fi

    # If we have a video description, add that entry too
    if [[ -n "${vidDesc}" && ! "${vidDesc}" == "null" ]]; then
        if sqDb "UPDATE source_videos SET DESC = '${vidDesc}', UPDATED = $(date +%s) WHERE ID = '${ytId}';"; then
            printOutput "5" "Appended video description to database entry for file ID [${ytId}]"
        else
            badExit "131" "Unable to append video description to database entry for file ID [${ytId}]"
        fi
    fi
fi
}

function makeShowImage {
# ${1} is ${chanDir}
# ${2} is ${channelId}

# Get the channel image
dbReply="$(sqDb "SELECT IMAGE FROM source_channels WHERE ID = '${2}';")"
if [[ -n "${dbReply}" ]]; then
    # If the video directory exists, download it
    if ! [[ -d "${videoOutputDir}/${1}" ]]; then
        if ! mkdir -p "${videoOutputDir}/${1}"; then
            printOutput "1" "Failed to create output directory [${videoOutputDir}/${1}]"
            return 1
        fi
    fi
    callCurlDownload "${dbReply}" "${videoOutputDir}/${1}/show.jpg"
fi
# Get the background image, if one exists
dbReply="$(sqDb "SELECT BANNER FROM source_channels WHERE ID = '${2}';")"
if [[ -n "${dbReply}" ]]; then
    callCurlDownload "${dbReply}" "${videoOutputDir}/${1}/background.jpg"
fi
}

function makeSeasonImage {
# ${1} is ${chanDir}
# ${2} is ${vidYear}
# ${3} is ${channelId} (Only needed if we need to call 'makeShowImage'
# Make sure we have a base show image to work with
if ! [[ -e "${videoOutputDir}/${1}/show.jpg" ]]; then
    if makeShowImage "${1}" "${3}"; then
        printOutput "5" "Show image created for channel directory [${1}]"
    else
        printOutput "1" "Failed to create show image for channel directory [${1}]"
    fi
fi
# Add the season folder, if required
if ! [[ -d "${videoOutputDir}/${1}/Season ${2}" ]]; then
    if ! mkdir -p "${videoOutputDir}/${1}/Season ${2}"; then
        badExit "132" "Unable to create season folder [${videoOutputDir}/${1}/Season ${2}]"
    fi
fi
# Create the image
if [[ -e "${videoOutputDir}/${1}/show.jpg" ]]; then
    # Get the height of the show image
    posterHeight="$(identify -format "%h" "${videoOutputDir}/${1}/show.jpg")"
    # We want 0.3 of the height, with no trailing decimal
    # We have to use 'awk' here, since bash doesn't like floating decimals
    textHeight="$(awk '{print $1 * $2}' <<<"${posterHeight} 0.3")"
    textHeight="${textHeight%\.*}"
    strokeHeight="$(awk '{print $1 * $2}' <<<"${textHeight} 0.03")"
    strokeHeight="${strokeHeight%\.*}"
    convert "${videoOutputDir}/${1}/show.jpg" -gravity Center -pointsize "${textHeight}" -fill white -stroke black -strokewidth "${strokeHeight}" -annotate 0 "${2}" "${videoOutputDir}/${1}/Season ${2}/Season${2}.jpg"
else
    printOutput "1" "Unable to generate season poster for [${1}]"
fi
}

function throttleDlp {
if ! [[ "${throttleMin}" -eq "0" && "${throttleMax}" -eq "0" ]]; then
    printOutput "4" "Throttling after calling yt-dlp"
    randomSleep "${throttleMin}" "${throttleMax}"
fi
}

function collectionGetOrder {
# Collection rating key should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a collection rating key please"
    return 1
elif [[ -z "${2}" ]]; then
    printOutput "1" "Pass 'audio' or 'video'"
    return 1
fi

if [[ "${2}" == "video" ]]; then
    fileStr="Video"
elif [[ "${2}" == "audio" ]]; then
    fileStr="Track"
else
    badExit "133" "Impossible condition"
fi

printOutput "5" "Obtaining order of items in ${2} collection from Plex"
unset plexCollectionOrder
# Start our indexing from one, it makes it easier for my smooth brain to debug playlist positioning
plexCollectionOrder[0]="null"
callCurl "${plexAdd}/library/collections/${1}/children?X-Plex-Token=${plexToken}"
while read -r ii; do
    if [[ -z "${ii}" || "${ii}" == "null" ]]; then
        printOutput "1" "No items in collection"
        return 1
    fi
    ii="${ii%\]\.*}"
    ii="${ii##*\[}"
    plexCollectionOrder+=("${ii}")
done < <(yq -p xml ".MediaContainer.${fileStr} | ([] + .) | .[] | .Media.Part.\"+@file\"" <<<"${curlOutput}")
unset plexCollectionOrder[0]
for ii in "${!plexCollectionOrder[@]}"; do
    assignTitle "${plexCollectionOrder[${ii}]}"
    printOutput "5" " plexCollectionOrder | ${ii} => ${plexCollectionOrder[${ii}]} [${titleById[_${plexCollectionOrder[${ii}]}]}]"
done
}

function collectionVerifySort {
# Collection rating key should be passed as ${1}
# 'audio' or 'video' should be passed as ${2}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a collection rating key please"
    return 1
elif [[ -z "${2}" ]]; then
    printOutput "1" "Pass 'audio' or 'video'"
    return 1
fi

collectionGetOrder "${1}" "${2}"

printOutput "3" "Checking for items to be re-ordered in ${2} collection"
for ii in "${!plexCollectionOrder[@]}"; do
    # ii = position interger [starts from 1]
    # plexCollectionOrder[${ii}] = file ID
    
    assignTitle "${plexCollectionOrder[${ii}]}"
    
    if [[ "${ii}" -eq "1" ]]; then
        if ! [[ "${plexCollectionOrder[1]}" == "${dbPlaylistVids[1]}" ]]; then
            printOutput "4" "Moving ${2} file ID [${dbPlaylistVids[1]}] to position 1 [${titleById[_${dbPlaylistVids[1]}]}]"
            if [[ "${2}" == "video" ]]; then
                getVideoFileRatingKey "${dbPlaylistVids[${ii}]}"
                urlRatingKey="${videoFileRatingKey[_${dbPlaylistVids[${ii}]}]}"
            elif [[ "${2}" == "audio" ]]; then
                getAudioFileRatingKey "${dbPlaylistVids[${ii}]}"
                urlRatingKey="${audioFileRatingKey[_${dbPlaylistVids[${ii}]}]}"
            else
                badExit "134" "Impossible condition"
            fi
            callCurlPut "${plexAdd}/library/collections/${1}/items/${urlRatingKey}/move?X-Plex-Token=${plexToken}"
        fi
    elif [[ "${ii}" -ge "1" ]]; then
        if ! [[ "${plexCollectionOrder[${ii}]}" == "${dbPlaylistVids[${ii}]}" ]]; then
            # The file in position ${plexCollectionOrder[${ii}]} does not match what it should be [${dbPlaylistVids[${ii}]}]
            # Get its incorrect position, for the sake of printing it
            for plexPos in "${!plexCollectionOrder[@]}"; do
                if [[ "${dbPlaylistVids[${ii}]}" == "${plexCollectionOrder[${plexPos}]}" ]]; then
                    break
                fi
            done
            for correctPos in "${!dbPlaylistVids[@]}"; do
                if [[ "${plexCollectionOrder[${ii}]}" == "${dbPlaylistVids[${correctPos}]}" ]]; then
                    # Correct 'after' is -1 from our current position
                    (( correctPos-- ))
                    break
                fi
            done
            
            if [[ "${2}" == "video" ]]; then
                # This is the file we want to move
                getVideoFileRatingKey "${plexCollectionOrder[${ii}]}"
                urlRatingKey="${videoFileRatingKey[_${plexCollectionOrder[${ii}]}]}"
                # This is the file it should come after
                getVideoFileRatingKey "${dbPlaylistVids[${correctPos}]}"
                urlRatingKeyAfter="${videoFileRatingKey[_${dbPlaylistVids[${correctPos}]}]}"
            elif [[ "${2}" == "audio" ]]; then
                # This is the file we want to move
                getAudioFileRatingKey "${plexCollectionOrder[${ii}]}"
                urlRatingKey="${audioFileRatingKey[_${plexCollectionOrder[${ii}]}]}"
                # This is the file it should come after
                getAudioFileRatingKey "${dbPlaylistVids[${correctPos}]}"
                urlRatingKeyAfter="${audioFileRatingKey[_${dbPlaylistVids[${correctPos}]}]}"
            else
                badExit "135" "Impossible condition"
            fi
            
            printOutput "4" "${2^} file ID [${plexCollectionOrder[${ii}]}] misplaced in position [${plexPos}], moving to position [$(( correctPos + 1 ))] [${urlRatingKey} - ${titleById[_${plexCollectionOrder[${ii}]}]} || ${urlRatingKeyAfter} - ${titleById[_${dbPlaylistVids[${correctPos}]}]}]"
            
            # Move it
            callCurlPut "${plexAdd}/library/collections/${1}/items/${urlRatingKey}/move?after=${urlRatingKeyAfter}&X-Plex-Token=${plexToken}"
        fi
    else
        badExit "136" "Impossible condition"
    fi
done
}

function collectionVerifyAdd {
# Collection rating key should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a collection rating key please"
    return 1
elif [[ -z "${2}" ]]; then
    printOutput "1" "Pass 'audio' or 'video'"
    return 1
fi

collectionGetOrder "${1}" "${2}"

printOutput "3" "Checking for items to be added to ${2} collection"
# For each index from the database
for ii in "${dbPlaylistVids[@]}"; do
    # ii = file ID
    needNewOrder="0"
    inPlaylist="0"
    # For each video in the collection
    for iii in "${plexCollectionOrder[@]}"; do
        # iii = file ID
        if [[ "${ii}" == "${iii}" ]]; then
            inPlaylist="1"
            break
        fi
    done
    if [[ "${inPlaylist}" -eq "0" ]]; then
        if [[ "${2}" == "video" ]]; then
            # This is the file we want to add
            getVideoFileRatingKey "${ii}"
            urlRatingKey="${videoFileRatingKey[_${ii}]}"
        elif [[ "${2}" == "audio" ]]; then
            # This is the file we want to add
            getAudioFileRatingKey "${ii}"
            urlRatingKey="${audioFileRatingKey[_${ii}]}"
        else
            badExit "137" "Impossible condition"
        fi
        assignTitle "${ii}"
        needNewOrder="1"
        callCurlPut "${plexAdd}/library/collections/${1}/items?uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${urlRatingKey}&X-Plex-Token=${plexToken}"
        printOutput "3" "Added file ID [${ii}][${titleById[_${ii}]}] to ${2} collection [${1}]"
    fi
    if [[ "${needNewOrder}" -eq "1" ]]; then
        collectionGetOrder "${1}" "${2}"
    fi
done
}

function collectionVerifyDelete {
# Collection rating key should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a collection rating key please"
    return 1
elif [[ -z "${2}" ]]; then
    printOutput "1" "Pass 'audio' or 'video'"
    return 1
fi

collectionGetOrder "${1}" "${2}"

printOutput "3" "Checking for items to be removed from ${2} collection"
for ii in "${plexCollectionOrder[@]}"; do
    # ii = file ID
    needNewOrder="0"
    inDbPlaylist="0"
    for iii in "${dbPlaylistVids[@]}"; do
        if [[ "${ii}" == "${iii}" ]]; then
            inDbPlaylist="1"
            break
        fi
    done
    if [[ "${inDbPlaylist}" -eq "0" ]]; then
        if [[ "${2}" == "video" ]]; then
            # This is the file we want to remove
            getVideoFileRatingKey "${ii}"
            urlRatingKey="${videoFileRatingKey[_${ii}]}"
        elif [[ "${2}" == "audio" ]]; then
            # This is the file we want to remove
            getAudioFileRatingKey "${ii}"
            urlRatingKey="${audioFileRatingKey[_${ii}]}"
        else
            badExit "138" "Impossible condition"
        fi
        assignTitle "${ii}"
        needNewOrder="1"
        callCurlDelete "${plexAdd}/library/collections/${1}/children/${urlRatingKey}?excludeAllLeaves=1&X-Plex-Token=${plexToken}"
        printOutput "3" "Removed file ID [${ii}] from ${2} collection [${1}] [${titleById[_${ii}]}]"
    fi
done
if [[ "${needNewOrder}" -eq "1" ]]; then
    collectionGetOrder "${1}" "${2}"
fi
}

function updateCollectionInfo {
# ${plId} is ${1}
# ${collectionRatingKey} is ${2}
collectionDesc="$(sqDb "SELECT DESC FROM source_playlists WHERE ID = '${1}';")"
if [[ -z "${collectionDesc}" || "${collectionDesc}" == "null" ]]; then
    # No playlist description set
    collectionDesc="https://www.youtube.com/playlist?list=${1}${lineBreak}Playlist last updated $(date)"
else
    collectionDesc="${collectionDesc}${lineBreak}-----${lineBreak}https://www.youtube.com/playlist?list=${1}${lineBreak}Playlist last updated $(date)"
fi
collectionDescEncoded="$(rawurlencode "${collectionDesc}")"
if callCurlPut "${plexAdd}/library/sections/${videoLibraryId}/all?type=18&id=${2}&includeExternalMedia=1&summary.value=${collectionDescEncoded}&summary.locked=1&X-Plex-Token=${plexToken}"; then
    printOutput "5" "Updated description for collection ID [${1}]"
else
    printOutput "1" "Failed to update description for collection ID [${1}]"
fi

# Update the image
collectionImg="$(sqDb "SELECT IMAGE FROM source_playlists WHERE ID = '${1}';")"
if [[ -n "${collectionImg}" ]] && ! [[ "${collectionImg}" == "null" ]]; then
    callCurlDownload "${collectionImg}" "${tmpDir}/${1}.jpg"
    callCurlPost "${plexAdd}/library/metadata/${2}/posters?X-Plex-Token=${plexToken}" --data-binary "@${tmpDir}/${1}.jpg"
    rm -f "${tmpDir}/${1}.jpg"
    printOutput "4" "Collection [${2}] image set"
fi
}

function playlistGetOrder {
# Playlist rating key should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a playlist rating key please"
    return 1
elif [[ -z "${2}" ]]; then
    printOutput "1" "Pass 'audio' or 'video'"
    return 1
fi

if [[ "${2}" == "video" ]]; then
    fileStr="Video"
elif [[ "${2}" == "audio" ]]; then
    fileStr="Track"
else
    badExit "139" "Impossible condition"
fi

printOutput "5" "Obtaining order of items in ${2} playlist from Plex"
unset plexPlaylistOrder
# Start our indexing from one, it makes it easier for my smooth brain to debug playlist positioning
plexPlaylistOrder[0]="null"
callCurl "${plexAdd}/playlists/${1}/items?X-Plex-Token=${plexToken}"
while read -r ii; do
    if [[ -z "${ii}" || "${ii}" == "null" ]]; then
        printOutput "1" "No items in playlist"
        return 1
    fi
    ii="${ii%\]\.*}"
    ii="${ii##*\[}"
    printOutput "5" "Found ${2} [${ii}] in position [${#plexPlaylistOrder[@]}]"
    plexPlaylistOrder+=("${ii}")
done < <(yq -p xml ".MediaContainer.${fileStr} | ([] + .) | .[] | .Media.Part.\"+@file\"" <<<"${curlOutput}")
unset plexPlaylistOrder[0]
for ii in "${!plexPlaylistOrder[@]}"; do
    assignTitle "${plexPlaylistOrder[${ii}]}"
    printOutput "5" " plexPlaylistOrder | ${ii} => ${plexPlaylistOrder[${ii}]} [${titleById[_${plexPlaylistOrder[${ii}]}]}]"
done
}

function playlistVerifySort {
# Playlist rating key should be passed as ${1}
# 'audio' or 'video' should be passed as ${2}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a playlist rating key please"
    return 1
elif [[ -z "${2}" ]]; then
    printOutput "1" "Pass 'audio' or 'video'"
    return 1
fi

for ii in "${!dbPlaylistVids[@]}"; do
    printOutput "5" "Found ${2} master record [${dbPlaylistVids[${ii}]}] in position [${ii}]"
done

playlistGetOrder "${1}" "${2}"

printOutput "3" "Checking for items to be re-ordered in ${2} playlist [${1}]"

for ii in "${!plexPlaylistOrder[@]}"; do
    # ii = position interger [starts from 1]
    # plexPlaylistOrder[${ii}] = file ID
    
    assignTitle "${plexPlaylistOrder[${ii}]}"
    
    needNewOrder="0"
    
    if [[ "${ii}" -eq "1" ]]; then
        if ! [[ "${plexPlaylistOrder[1]}" == "${dbPlaylistVids[1]}" ]]; then
            printOutput "4" "Moving ${2} file ID [${dbPlaylistVids[1]}] to position 1 [${titleById[_${dbPlaylistVids[1]}]}]"
            
            if [[ "${2}" == "video" ]]; then
                getVideoFileRatingKey "${dbPlaylistVids[1]}"
                callCurl "${plexAdd}/playlists/${1}/items?X-Plex-Token=${plexToken}"
                playlistItemId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${videoFileRatingKey[_${dbPlaylistVids[1]}]}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
                printOutput "5" "Item RK [${videoFileRatingKey[_${dbPlaylistVids[1]}]}] | Item PLID [${playlistItemId}]"
            elif [[ "${2}" == "audio" ]]; then
                getAudioFileRatingKey "${dbPlaylistVids[1]}"
                callCurl "${plexAdd}/playlists/${1}/items?X-Plex-Token=${plexToken}"
                playlistItemId="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${audioFileRatingKey[_${dbPlaylistVids[1]}]}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
                printOutput "5" "Item RK [${audioFileRatingKey[_${dbPlaylistVids[1]}]}] | Item PLID [${playlistItemId}]"
            else
                badExit "140" "Impossible condition"
            fi
            callCurlPut "${plexAdd}/library/playlists/${1}/items/${playlistItemId}/move?X-Plex-Token=${plexToken}"
            needNewOrder="1"
        fi
    elif [[ "${ii}" -ge "1" ]]; then
        if ! [[ "${plexPlaylistOrder[${ii}]}" == "${dbPlaylistVids[${ii}]}" ]]; then
            # The file in position ${plexPlaylistOrder[${ii}]} does not match what it should be [${dbPlaylistVids[${ii}]}]
            for correctPos in "${!dbPlaylistVids[@]}"; do
                if [[ "${plexPlaylistOrder[${ii}]}" == "${dbPlaylistVids[${correctPos}]}" ]]; then
                    # Correct 'after' is -1 from our current position ${correctPos}
                    (( correctPos-- ))
                    break
                fi
            done
            
            if [[ "${2}" == "video" ]]; then
                # This is the file we want to move
                getVideoFileRatingKey "${plexPlaylistOrder[${ii}]}"
                callCurl "${plexAdd}/playlists/${1}/items?X-Plex-Token=${plexToken}"
                playlistItemId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${videoFileRatingKey[_${plexPlaylistOrder[${ii}]}]}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
                # This is the file it should come after
                getVideoFileRatingKey "${dbPlaylistVids[${correctPos}]}"
                callCurl "${plexAdd}/playlists/${1}/items?X-Plex-Token=${plexToken}"
                playlistItemIdAfter="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${videoFileRatingKey[_${dbPlaylistVids[${correctPos}]}]}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
                printOutput "5" "Item RK [${videoFileRatingKey[_${plexPlaylistOrder[${ii}]}]}] | Item PLID [${playlistItemId}] | Item pos [${ii}] | After RK [${videoFileRatingKey[_${dbPlaylistVids[${correctPos}]}]}] | After PLID [${playlistItemIdAfter}] | After pos [${correctPos}]"
            elif [[ "${2}" == "audio" ]]; then
                # This is the file we want to move
                getAudioFileRatingKey "${plexPlaylistOrder[${ii}]}"
                callCurl "${plexAdd}/playlists/${1}/items?X-Plex-Token=${plexToken}"
                playlistItemId="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${audioFileRatingKey[_${plexPlaylistOrder[${ii}]}]}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
                # This is the file it should come after
                getAudioFileRatingKey "${dbPlaylistVids[${correctPos}]}"
                callCurl "${plexAdd}/playlists/${1}/items?X-Plex-Token=${plexToken}"
                playlistItemIdAfter="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${audioFileRatingKey[_${dbPlaylistVids[${correctPos}]}]}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
                printOutput "5" "Item RK [${audioFileRatingKey[_${plexPlaylistOrder[${ii}]}]}] | Item PLID [${playlistItemId}] | Item pos [${ii}] | After RK [${audioFileRatingKey[_${dbPlaylistVids[${correctPos}]}]}] | After PLID [${playlistItemIdAfter}] | After pos [${correctPos}]"
            else
                badExit "141" "Impossible condition"
            fi
            
            printOutput "4" "${2^} file ID [${plexPlaylistOrder[${ii}]}] misplaced in position [${ii}], moving to position [$(( correctPos + 1 ))]"
            
            # Move it
            callCurlPut "${plexAdd}/playlists/${1}/items/${playlistItemId}/move?after=${playlistItemIdAfter}&X-Plex-Token=${plexToken}"
            needNewOrder="1"
        fi
    else
        badExit "142" "Impossible condition"
    fi
    
    if [[ "${needNewOrder}" -eq "1" ]]; then
        playlistGetOrder "${1}" "${2}"
    fi
done
}

function playlistVerifyAdd {
# Playlist rating key should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a playlist rating key please"
    return 1
elif [[ -z "${2}" ]]; then
    printOutput "1" "Pass 'audio' or 'video'"
    return 1
fi

playlistGetOrder "${1}" "${2}"

printOutput "3" "Checking for items to be added to ${2} playlist"
# For each index from the database
for ii in "${dbPlaylistVids[@]}"; do
    # ii = file ID
    needNewOrder="0"
    inPlaylist="0"
    # For each video in the playlist
    for iii in "${plexPlaylistOrder[@]}"; do
        # iii = file ID
        if [[ "${ii}" == "${iii}" ]]; then
            inPlaylist="1"
            break
        fi
    done
    if [[ "${inPlaylist}" -eq "0" ]]; then
        if [[ "${2}" == "video" ]]; then
            # This is the file we want to add
            getVideoFileRatingKey "${ii}"
            urlRatingKey="${videoFileRatingKey[_${ii}]}"
        elif [[ "${2}" == "audio" ]]; then
            # This is the file we want to add
            getAudioFileRatingKey "${ii}"
            urlRatingKey="${audioFileRatingKey[_${ii}]}"
        else
            badExit "143" "Impossible condition"
        fi
        assignTitle "${ii}"
        needNewOrder="1"
        callCurlPut "${plexAdd}/playlists/${1}/items?uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${urlRatingKey}&X-Plex-Token=${plexToken}"
        printOutput "3" "Added file ID [${ii}][${titleById[_${ii}]}] to ${2} playlist [${1}]"
    fi
    if [[ "${needNewOrder}" -eq "1" ]]; then
        playlistGetOrder "${1}" "${2}"
    fi
done
}

function playlistVerifyDelete {
# Playlist rating key should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a playlist rating key please"
    return 1
elif [[ -z "${2}" ]]; then
    printOutput "1" "Pass 'audio' or 'video'"
    return 1
fi

playlistGetOrder "${1}" "${2}"

printOutput "3" "Checking for items to be removed from ${2} playlist"
for ii in "${plexPlaylistOrder[@]}"; do
    printOutput "5" "Checking Plex item [${ii}]"
    # ii = file ID
    needNewOrder="0"
    inDbPlaylist="0"
    for iii in "${dbPlaylistVids[@]}"; do
        printOutput "5" "Comparing against DB item [${iii}]"
        if [[ "${ii}" == "${iii}" ]]; then
            # It's supposed to be in the playlist
            inDbPlaylist="1"
            break
        fi
    done
    if [[ "${inDbPlaylist}" -eq "0" ]]; then
        if [[ "${2}" == "video" ]]; then
            # This is the file we want to remove
            getVideoFileRatingKey "${ii}"
            callCurl "${plexAdd}/playlists/${1}/items?X-Plex-Token=${plexToken}"
            playlistItemId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${videoFileRatingKey[_${ii}]}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
        elif [[ "${2}" == "audio" ]]; then
            # This is the file we want to remove
            getAudioFileRatingKey "${ii}"
            callCurl "${plexAdd}/playlists/${1}/items?X-Plex-Token=${plexToken}"
            playlistItemId="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${audioFileRatingKey[_${ii}]}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
        else
            badExit "144" "Impossible condition"
        fi
        assignTitle "${ii}"
        needNewOrder="1"
        callCurlDelete "${plexAdd}/playlists/${1}/items/${playlistItemId}?X-Plex-Token=${plexToken}"
        printOutput "3" "Removed file ID [${ii}] from ${2} playlist [${1}] [${titleById[_${ii}]}]"
    fi
done
if [[ "${needNewOrder}" -eq "1" ]]; then
    playlistGetOrder "${1}" "${2}"
fi
}

function updatePlaylistInfo {
# ${plId} is ${1}
# ${playlistRatingKey} is ${2}
# Update the description
playlistDesc="$(sqDb "SELECT DESC FROM source_playlists WHERE ID = '${1}';")"
if [[ -z "${playlistDesc}" || "${playlistDesc}" == "null" ]]; then
    # No playlist description set
    playlistDesc="https://www.youtube.com/playlist?list=${1}${lineBreak}Playlist last updated $(date)"
else
    playlistDesc="${playlistDesc}${lineBreak}-----${lineBreak}https://www.youtube.com/playlist?list=${1}${lineBreak}Playlist last updated $(date)"
fi
playlistDescEncoded="$(rawurlencode "${playlistDesc}")"
if callCurlPut "${plexAdd}/playlists/${2}?summary=${playlistDescEncoded}&X-Plex-Token=${plexToken}"; then
    printOutput "5" "Updated description for playlist ID [${1}]"
else
    printOutput "1" "Failed to update description for playlist ID [${1}]"
fi

# Update the image
playlistImg="$(sqDb "SELECT IMAGE FROM source_playlists WHERE ID = '${1}';")"
if [[ -n "${playlistImg}" ]] && ! [[ "${playlistImg}" == "null" ]]; then
    callCurlDownload "${playlistImg}" "${tmpDir}/${1}.jpg"
    callCurlPost "${plexAdd}/library/metadata/${2}/posters?X-Plex-Token=${plexToken}" --data-binary "@${tmpDir}/${1}.jpg"
    rm -f "${tmpDir}/${1}.jpg"
    printOutput "4" "Playlist [${2}] image set"
fi
}

function sqDb {
# Log the command we're executing to the database, for development purposes
idCount="$(sqlite3 "${sqliteDb}" "SELECT ID FROM db_log ORDER BY ID DESC LIMIT 1;")"
if ! validateInterger "${idCount}"; then
    printOutput "1" "Variable idCount [${idCount}] failed to validate -- Unable to continue"
    return 1
else
    (( idCount++ ))
fi

# Execute the command
if sqOutput="$(sqlite3 "${sqliteDb}" "${1}" 2>&1)"; then
    if [[ -n "${sqOutput}" ]]; then
        echo "${sqOutput}"
    fi
else
    sqlite3 "${sqliteDb}" "INSERT INTO db_log (ID, TIME, COMMAND, RESULT, OUTPUT) VALUES (${idCount}, '$(date)', '${1//\'/\'\'}', 'Failure', '${sqOutput//\'/\'\'}');"
    if [[ -n "${sqOutput}" ]]; then
        echo "${sqOutput}"
    fi
    return 1
fi
}

#############################
##       Signal Traps      ##
#############################
trap "badExit SIGINT" INT
trap "badExit SIGQUIT" QUIT

#############################
##  Positional parameters  ##
#############################
# We can run the positional parameter options without worrying about lockFile
printHelp="0"
doUpdate="0"
skipDownload="0"
verifyMedia="0"
updateRatingKeys="0"
updateMetadata="0"
forceSourceUpdate="0"
dbMaint="0"

while [[ -n "${*}" ]]; do
    case "${1,,}" in
    "-h"|"--help")
        printHelp="1"
    ;;
    "-u"|"--update")
        doUpdate="1"
    ;;
    "-s"|"--skip-download")
        skipDownload="1"
    ;;
    "-v"|"--verify-media")
        verifyMedia="1"
    ;;
    "-r"|"--rating-key-update")
        updateRatingKeys="1"
    ;;
    "-m"|"--metadata-update")
        updateMetadata="1"
    ;;
    "-f"|"--force-source-update")
        forceSourceUpdate="1"
    ;;
    "-d"|"--db-maintenance")
        dbMaint="1"
    ;;
    esac
    shift
done

if [[ "${printHelp}" -eq "1" ]]; then

while read -r i; do
    if [[ "${i}" == "##        Changelog        ##" ]]; then
        scriptVer="1"
    elif [[ "${scriptVer}" -eq "1" ]]; then
        scriptVer="2"
    elif [[ "${scriptVer}" -eq "2" ]]; then
        scriptVer="${i}"
        break
    fi
done < "${0}"

scriptVer="${scriptVer#\# }"

    echo "          ${0##*/}
          Version date [${scriptVer}]

-h  --help                  Displays this help message

-u  --update                Self update to the most recent version

-s  --skip-download         Skips any media processing/download
                             Can be useful for if you only want to
                             do maintenance tasks

-v  --verify-media          Compares media on the file system to
                             media in the database, and adds any
                             missing items to the database
                             * Note, this requires that the naming
                             scheme for untracked media to end in
                             '[VIDEO_ID].[ext]' where 'VIDEO_ID' is
                             the 11 character video id, and [ext]
                             is an 'mp4', 'mp3' or 'opus' extension
                             * Also note, file extensions MUST be
                             lowercase to be detected properly

-r  --rating-key-update     Verifies the correct ID referencing
                             known files in Plex. Useful it you're
                             having issues with incorrect items
                             being added/removed/re-ordered in
                             playlists and collections

-m  --metadata-update       Updates descriptions and images for
                             all series, seasons, artists, albums,
                             playlists, and collections
                             
-f  --force-source-update   Forces a source to be updated in the
                             database, if it otherwise would have
                             been skipped, e.g. if there was no
                             new content

-d  --db-maintenance        Preforms some database cleaning and
                             maintenance via sqlite's 'VACUUM'"


    cleanExit "--silent"
fi

if [[ "${doUpdate}" -eq "1" ]]; then
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
        else
            badExit "145" "Update downloaded, but unable to \`chmod +x\`"
        fi
    else
        badExit "146" "Unable to download Update"
    fi
    cleanExit
fi

#############################
##   Initiate .env file    ##
#############################
################ UNCOMMENT
if [[ -e "${realPath%/*}/${scriptName%.bash}.env" ]]; then
    source "${realPath%/*}/${scriptName%.bash}.env"
else
    badExit "147" "Error: \"${realPath%/*}/${scriptName%.bash}.env\" does not appear to exist"
fi

printOutput "4" "Validating config file"
varFail="0"
# Standard checks
if ! [[ "${updateCheck,,}" =~ ^(yes|no|true|false)$ ]]; then
    echo "Option to check for updates not valid. Assuming no."
    updateCheck="No"
fi
if ! [[ "${outputVerbosity}" =~ ^[1-5]$ ]]; then
    echo "Invalid output verbosity defined. Assuming level 1 (Errors only)"
    outputVerbosity="1"
fi

# Config specific checks
if ! [[ "${throttleMin}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid option for 'throttleMin' -- Using default of 30"
    throttleMin="30"
fi
if ! [[ "${throttleMax}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid option for 'throttleMax' -- Using default of 120"
    throttleMin="120"
fi
if [[ "${throttleMin}" -gt "${throttleMax}" ]]; then
    printOutput "1" "Minimum throttle time [${throttleMin}] is greater than maximum throttle time [${throttleMax}] -- Resetting to defaults [30/120]"
    throttleMin="30"
    throttleMax="120"
fi
printOutput "5" "TODO: Validate config options"
if ! [[ -d "${videoOutputDir}" ]]; then
    printOutput "1" "Video output dir [${videoOutputDir}] does not appear to exist -- Please create it, and add it to Plex"
    varFail="1"
fi
if ! [[ -d "${audioOutputDir}" ]]; then
    printOutput "1" "Audio output dir [${audioOutputDir}] does not appear to exist -- Please create it, and add it to Plex"
    varFail="1"
fi
if [[ "${#ytApiKeys[@]}" -eq "0" ]]; then
    printOutput "2" "No YouTube Data API keys provided -- Will use LemnosLife, at a greatly reduced call rate"
fi
if ! [[ -e "${cookieFile}" ]]; then
    printOutput "2" "No cookie file provided -- Will be unable to interact with 'Private' media"
fi
if [[ -z "${plexIp}" ]]; then
    printOutput "1" "Please provide an IP address or container name for Plex"
    varFail="1"
fi
if [[ -z "${plexToken}" ]]; then
    printOutput "1" "Please provide an authentication token for Plex"
    varFail="1"
fi
if [[ -z "${plexPort}" ]]; then
    printOutput "2" "No port provided to contact Plex, assuming 32400"
    plexPort="32400"
elif ! [[ "${plexPort}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid port provided to contact Plex [${plexPort}]"
    varFail="1"
fi
if ! [[ "${plexScheme}" =~ ^https?$ ]]; then
    printOutput "2" "Invalid HTTP scheme provided to contact plex [${plexScheme}], assuming https"
    plexScheme="https"
fi
if ! [[ -d "${tmpDir}" ]]; then
    printOutput "1" "Path to create temp directory does not appear to exist, please create it"
    varFail="1"
fi

# Quit if failures
if [[ "${varFail}" -eq "1" ]]; then
    badExit "148" "Please fix above errors"
fi

#############################
##       Update check      ##
#############################
if [[ "${updateCheck,,}" =~ ^(yes|true)$ ]]; then
    printOutput "4" "Checking for updates"
    while read -r i; do
        if [[ "${i}" == "##        Changelog        ##" ]]; then
            scriptVer="1"
        elif [[ "${scriptVer}" -eq "1" ]]; then
            scriptVer="2"
        elif [[ "${scriptVer}" -eq "2" ]]; then
            scriptVer="${i}"
            break
        fi
    done < "${0}"
    while read -r i; do
        if [[ "${i}" == "##        Changelog        ##" ]]; then
            newVer="1"
        elif [[ "${newVer}" -eq "1" ]]; then
            newVer="2"
        elif [[ "${newVer}" -eq "2" ]]; then
            newVer="${i}"
            break
        fi
    done < <(curl -skL "${updateURL}")
    if ! [[ "${newest}" == "${current}" ]]; then
        printOutput "0" "A newer version [${newVer}] is available"
    else
        printOutput "4" "No new updates available"
    fi
fi

#############################
##         Payload         ##
#############################
# Define some variables
apiCallsYouTube="0"
apiCallsLemnos="0"
sqliteDb="${realPath%/*}/.${scriptName}.db"
declare -A reindexArr newVideoMediaPath newAudioMediaPath dbVidSeriesArr dbAudSeriesArr videoFileRatingKey audioFileRatingKey plItemId titleById

# Create our tmpDir
tmpDir="$(mktemp -d -p "${tmpDir}")"

# If no database exists, create one
if ! [[ -e "${sqliteDb}" ]]; then
    printOutput "3" "############### Initializing database #################"
    sqlite3 "${sqliteDb}" "CREATE TABLE source_videos(ID TEXT PRIMARY KEY, CONFIG INTERGER, TITLE TEXT, TITLE_CLEAN TEXT, CHANNEL_ID TEXT, TIMESTAMP INTERGER, YEAR INTERGER, DESC TEXT, EP_INDEX INTERGER, SB_OPTIONS TEXT, VID_FORMAT TEXT, AUD_FORMAT TEXT, VID_SHORTS_DL TEXT, AUD_SHORTS_DL TEXT, LIVE TEXT, WATCHED TEXT, TYPE TEXT, VID_STATUS TEXT, AUD_STATUS TEXT, UPDATED INTERGER);"
    sqlite3 "${sqliteDb}" "CREATE TABLE source_channels(ID TEXT PRIMARY KEY, NAME TEXT, NAME_CLEAN TEXT, TIMESTAMP INTERGER, SUB_COUNT INTERGER, COUNTRY TEXT, URL TEXT, VID_COUNT INTERGER, VIEW_COUNT INTERGER, DESC TEXT, PATH TEXT, IMAGE TEXT, BANNER TEXT, UPDATED INTERGER);"
    sqlite3 "${sqliteDb}" "CREATE TABLE source_playlists(ID TEXT PRIMARY KEY, VISIBILITY TEXT, TITLE TEXT, DESC TEXT, IMAGE TEXT, VID_RATING_KEY INTERGER, AUD_RATING_KEY INTERGER, UPDATED INTERGER);"

    sqlite3 "${sqliteDb}" "CREATE TABLE playlist_order(SQID INTERGER PRIMARY KEY, ID TEXT, PLAYLIST_INDEX INTERGER, PLAYLIST_KEY TEXT, UPDATED INTERGER);"

    sqlite3 "${sqliteDb}" "CREATE TABLE video_rating_key_by_channel(RATING_KEY INTERGER PRIMARY KEY, CHANNEL_ID TEXT, UPDATED INTERGER);"
    sqlite3 "${sqliteDb}" "CREATE TABLE video_rating_key_by_season(RATING_KEY INTERGER PRIMARY KEY, YEAR INTERGER, CHANNEL_ID TEXT, UPDATED INTERGER);"
    sqlite3 "${sqliteDb}" "CREATE TABLE video_rating_key_by_item(RATING_KEY INTERGER PRIMARY KEY, ID TEXT, UPDATED INTERGER);"

    sqlite3 "${sqliteDb}" "CREATE TABLE audio_rating_key_by_channel(RATING_KEY INTERGER PRIMARY KEY, CHANNEL_ID TEXT, UPDATED INTERGER);"
    sqlite3 "${sqliteDb}" "CREATE TABLE audio_rating_key_by_album(RATING_KEY INTERGER PRIMARY KEY, ID TEXT, UPDATED INTERGER);"
    sqlite3 "${sqliteDb}" "CREATE TABLE audio_rating_key_by_item(RATING_KEY INTERGER PRIMARY KEY, ID TEXT, UPDATED INTERGER);"

    sqlite3 "${sqliteDb}" "CREATE TABLE db_log(ID INTERGER PRIMARY KEY, TIME TEXT, RESULT TEXT, COMMAND TEXT, OUTPUT TEXT);"
fi

# Preform database maintenance, if needed
if [[ "${dbMaint}" -eq "1" ]]; then
    startTime="$(($(date +%s%N)/1000000))"
    printOutput "3" "########### Preforming database maintenance ###########"
    
    # Verify the 'ID' column of audio_rating_key_by_album
    readarray -t verifyArr < <(sqDb "SELECT ID FROM audio_rating_key_by_album;")
    for i in "${verifyArr[@]}"; do
        count="0"
        for ii in "${verifyArr[@]}"; do
            if [[ "${i}" == "${ii}" ]]; then
                (( count++ ))
            fi
        done
        if [[ "${count}" -eq "0" ]]; then
            badExit "149" "Impossible condition"
        elif [[ "${count}" -eq "1" ]]; then
            # Expected outcome
            true
        elif [[ "${count}" -gt "1" ]]; then
            printOutput "1" "Multiple instances of file ID [${i}] found in [audio_rating_key_by_album] table -- Database corrupted!"
        fi
    done

    # Verify the 'CHANNEL_ID' column of audio_rating_key_by_channel
    readarray -t verifyArr < <(sqDb "SELECT CHANNEL_ID FROM audio_rating_key_by_channel;")
    for i in "${verifyArr[@]}"; do
        count="0"
        for ii in "${verifyArr[@]}"; do
            if [[ "${i}" == "${ii}" ]]; then
                (( count++ ))
            fi
        done
        if [[ "${count}" -eq "0" ]]; then
            badExit "150" "Impossible condition"
        elif [[ "${count}" -eq "1" ]]; then
            # Expected outcome
            true
        elif [[ "${count}" -gt "1" ]]; then
            printOutput "1" "Multiple instances of channel ID [${i}] found in [audio_rating_key_by_channel] table -- Database corrupted!"
        fi
    done
    
    # Verify the 'ID' column of audio_rating_key_by_item
    readarray -t verifyArr < <(sqDb "SELECT ID FROM audio_rating_key_by_item;")
    for i in "${verifyArr[@]}"; do
        count="0"
        for ii in "${verifyArr[@]}"; do
            if [[ "${i}" == "${ii}" ]]; then
                (( count++ ))
            fi
        done
        if [[ "${count}" -eq "0" ]]; then
            badExit "151" "Impossible condition"
        elif [[ "${count}" -eq "1" ]]; then
            # Expected outcome
            true
        elif [[ "${count}" -gt "1" ]]; then
            printOutput "1" "Multiple instances of file ID [${i}] found in [audio_rating_key_by_item] table -- Database corrupted!"
        fi
    done
    
    # Verify the 'ID' column of video_rating_key_by_channel
    readarray -t verifyArr < <(sqDb "SELECT CHANNEL_ID FROM video_rating_key_by_channel;")
    for i in "${verifyArr[@]}"; do
        count="0"
        for ii in "${verifyArr[@]}"; do
            if [[ "${i}" == "${ii}" ]]; then
                (( count++ ))
            fi
        done
        if [[ "${count}" -eq "0" ]]; then
            badExit "152" "Impossible condition"
        elif [[ "${count}" -eq "1" ]]; then
            # Expected outcome
            true
        elif [[ "${count}" -gt "1" ]]; then
            printOutput "1" "Multiple instances of channel ID [${i}] found in [video_rating_key_by_channel] table -- Database corrupted!"
        fi
    done

    # Verify the 'CHANNEL_ID' column of video_rating_key_by_season
    readarray -t verifyArr < <(sqDb "SELECT CHANNEL_ID, YEAR FROM video_rating_key_by_season;")
    for i in "${verifyArr[@]}"; do
        count="0"
        for ii in "${verifyArr[@]}"; do
            if [[ "${i}" == "${ii}" ]]; then
                (( count++ ))
            fi
        done
        if [[ "${count}" -eq "0" ]]; then
            badExit "153" "Impossible condition"
        elif [[ "${count}" -eq "1" ]]; then
            # Expected outcome
            true
        elif [[ "${count}" -gt "1" ]]; then
            printOutput "1" "Multiple instances of channel ID [${i%|*}] and year [${i#*|}] found in [video_rating_key_by_season] table -- Database corrupted!"
        fi
    done
    
    # Verify the 'ID' column of video_rating_key_by_item
    readarray -t verifyArr < <(sqDb "SELECT ID FROM video_rating_key_by_item;")
    for i in "${verifyArr[@]}"; do
        count="0"
        for ii in "${verifyArr[@]}"; do
            if [[ "${i}" == "${ii}" ]]; then
                (( count++ ))
            fi
        done
        if [[ "${count}" -eq "0" ]]; then
            badExit "154" "Impossible condition"
        elif [[ "${count}" -eq "1" ]]; then
            # Expected outcome
            true
        elif [[ "${count}" -gt "1" ]]; then
            printOutput "1" "Multiple instances of file ID [${i}] found in [video_rating_key_by_item] table -- Database corrupted!"
        fi
    done
    
    # For each playlist in the playlist_order table, verify that each video ID only appears once, and each index position only appears once
    dbColumns=("ID" "PLAYLIST_INDEX")
    while read -r plId; do
        for dbColumn in "${dbColumns[@]}"; do
            readarray -t verifyArr < <(sqDb "SELECT ${dbColumn} FROM playlist_order WHERE PLAYLIST_KEY = '${plId}';")
            for i in "${verifyArr[@]}"; do
                count="0"
                for ii in "${verifyArr[@]}"; do
                    if [[ "${i}" == "${ii}" ]]; then
                        (( count++ ))
                    fi
                done
                if [[ "${count}" -eq "0" ]]; then
                    badExit "155" "Impossible condition"
                elif [[ "${count}" -eq "1" ]]; then
                    # Expected outcome
                    true
                elif [[ "${count}" -gt "1" ]]; then
                    printOutput "1" "Multiple instances of column [${dbColumn}] value [${i}] found in [playlist_order] table -- Database corrupted!"
                fi
            done
        done
    done < <(sqDb "SELECT DISTINCT PLAYLIST_KEY FROM playlist_order;")
    
    sqDb "VACUUM;"
    printOutput "3" "Database health check and optimization completed [Took $(timeDiff "${startTime}")]"
    cleanExit
fi

# Verify that we can connect to Plex
printOutput "3" "############# Verifying Plex connectivity #############"
getContainerIp "${plexIp}"
plexAdd="${plexScheme}://${containerIp}:${plexPort}"

# Make sure we can reach the server
numServers="$(yq -p xml ".MediaContainer.+@size" <<<"${curlOutput}")"
if [[ "${numServers}" -gt "1" ]]; then
    serverVersion="$(yq -p xml ".MediaContainer.Server[] | select(.+@host == \"${containerIp}\") | .+@version" <<<"${curlOutput}")"
    serverMachineId="$(yq -p xml ".MediaContainer.Server[] | select(.+@host == \"${containerIp}\") | .+@serverMachineId" <<<"${curlOutput}")"
    serverName="$(yq -p xml ".MediaContainer.Server[] | select(.+@host == \"${containerIp}\") | .+@name" <<<"${curlOutput}")"
elif [[ "${numServers}" -eq "1" ]]; then
    serverVersion="$(yq -p xml ".MediaContainer.Server.+@version" <<<"${curlOutput}")"
    serverMachineId="$(yq -p xml ".MediaContainer.Server.+@serverMachineId" <<<"${curlOutput}")"
    serverName="$(yq -p xml ".MediaContainer.Server.+@name" <<<"${curlOutput}")"
else
    badExit "156" "No Plex Media Servers found."
fi
if [[ -z "${serverName}" || -z "${serverVersion}" || -z "${serverMachineId}" ]]; then
    badExit "157" "Unable to validate Plex Media Server"
fi
# Get the library ID for our video output directory
# Count how many libraries we have
callCurl "${plexAdd}/library/sections/?X-Plex-Token=${plexToken}"
numLibraries="$(yq -p xml ".MediaContainer.Directory | length" <<<"${curlOutput}")"
if [[ "${numLibraries}" -eq "0" ]]; then
    badExit "158" "No libraries detected in the Plex Media Server"
fi
z="0"
while [[ "${z}" -lt "${numLibraries}" ]]; do
    # Get the path for our library ID
    plexPath="$(yq -p xml ".MediaContainer.Directory[${z}].Location.\"+@path\"" <<<"${curlOutput}")"
    if [[ "${videoOutputDir}" =~ ^.*"${plexPath}"$ ]]; then
        # Get the library name
        libraryName="$(yq -p xml ".MediaContainer.Directory[${z}].\"+@title\"" <<<"${curlOutput}")"
        # Get the library ID
        videoLibraryId="$(yq -p xml ".MediaContainer.Directory[${z}].\"+@key\"" <<<"${curlOutput}")"

        printOutput "4" "Matched Plex video library [${libraryName}] to library ID [${videoLibraryId}]"
    elif [[ "${audioOutputDir}" =~ ^.*"${plexPath}"$ ]]; then
        # Get the library name
        libraryName="$(yq -p xml ".MediaContainer.Directory[${z}].\"+@title\"" <<<"${curlOutput}")"
        # Get the library ID
        audioLibraryId="$(yq -p xml ".MediaContainer.Directory[${z}].\"+@key\"" <<<"${curlOutput}")"

        printOutput "4" "Matched Plex audio library [${libraryName}] to library ID [${audioLibraryId}]"
    fi
    (( z++ ))
done
printOutput "3" "Validated Plex Media Server: ${serverName} [Version: ${serverVersion}] [Machine ID: ${serverMachineId}]"

if [[ "${verifyMedia}" -eq "1" ]]; then
    printOutput "3" "############### Verifying media library ###############"
    printOutput "3" "Verifying media items within Plex"
    if [[ -d "${videoOutputDir}" ]]; then
        # Find all the videos in the video library
        newMediaType="video"
        readarray -t knownMedia < <(find "${videoOutputDir}" -type f -name "*.mp4")
        for i in "${knownMedia[@]}"; do
            # Make sure we can extract the file ID
            ytId="${i%\]\.*}"
            ytId="${ytId##*\[}"
            # See if what we have matches what a file ID should be
            if [[ "${ytId}" =~ ^[A-Za-z0-9_\-]{11}$ ]]; then
                # It's a valid ID
                # Note the file path with an associative array
                # The key is '_${ytId}'
                # The value is the path
                newVideoMediaPath["_${ytId}"]="${i}"
                # Do we have the ID in the database already?
                dbCount="$(sqDb "SELECT COUNT(1) from source_videos WHERE ID = '${ytId}';")"
                if [[ "${dbCount}" -eq "0" ]]; then
                    # It's not in the database, let's add it
                    if compareFileIdToDb "${ytId}"; then
                        newMedia+=("${ytId}")
                        vidTitle="$(sqDb "SELECT TITLE from source_videos WHERE ID = '${ytId}';")"
                        if [[ -z "${vidTitle}" ]]; then
                            badExit "159" "Unable to extract video title from file ID [${ytId}]"
                        fi
                        printOutput "2" "Found untracked video file ID [${ytId}] [${vidTitle}]"
                    else
                        printOutput "1" "Failed to add file [${i}] to database"
                    fi
                elif [[ "${dbCount}" -eq "1" ]]; then
                    # The audio might be in there and the video not. If so, it'll return 'skipped'
                    if dbReply="$(sqDb "SELECT VID_STATUS from source_videos WHERE ID = '${ytId}';")"; then
                        printOutput "5" "Successfully looked up video statis [${dbReply}] for file ID [${ytId}]"
                    else
                        badExit "160" "Failed to look up video statis [${dbReply}] for file ID [${ytId}]"
                    fi
                    if [[ "${dbReply}" == "skipped" ]]; then
                        if compareFileIdToDb "${ytId}" "${i##*.}"; then
                            newMedia+=("${ytId}")
                            vidTitle="$(sqDb "SELECT TITLE from source_videos WHERE ID = '${ytId}';")"
                            if [[ -z "${vidTitle}" ]]; then
                                badExit "161" "Unable to extract video title from file ID [${ytId}]"
                            fi
                            printOutput "3" "Found untracked video file ID [${ytId}] [${vidTitle}]"
                        else
                            printOutput "1" "Failed to add file [${i}] to database"
                        fi
                    fi
                fi
            fi
        done

        if [[ "${#newMedia[@]}" -eq "0" ]]; then
            printOutput "3" "All media from [${videoOutputDir}] logged in database [${#knownMedia[@]} items]"
        fi

        # Set the episode index position for all the videos we just added
        for ytId in "${newMedia[@]}"; do
            # Set index position for videos
            # Get our channel ID
            channelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${ytId}';")"
            # Validate it
            if ! [[ "${channelId}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
                printOutput "1" "Channel ID lookup for file ID [${ytId}] returned invalid result [${channelId}]"
                (( n++ ))
                continue
            fi
            # Get our year
            vidYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${ytId}';")"
            # Validate it
            if ! [[ "${vidYear}" =~ ^[0-9][0-9][0-9][0-9]$ ]]; then
                printOutput "1" "Year lookup for file ID [${ytId}] returned invalid result [${vidYear}]"
                (( n++ ))
                continue
            fi
            # Get the order of all items in that season
            readarray -t seasonOrder < <(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${channelId}' AND YEAR = ${vidYear} ORDER BY TIMESTAMP ASC;")

            # Iterate through the season until our ID matches, so we know our position
            vidIndex="1"
            for z in "${seasonOrder[@]}"; do
                if [[ "${z}" == "${ytId}" ]]; then
                    break
                fi
                (( vidIndex++ ))
            done

            # Log that position in the database
            if ! sqDb "UPDATE source_videos SET EP_INDEX = '${vidIndex}', UPDATED = '$(date +%s)' WHERE ID = '${ytId}';"; then
                badExit "162" "Unable to update episode index to [S${vidYear}E${vidIndex}] for file ID [${ytId}]"
            fi

            # Verify our path is correct
            # Start by getting our save path from the DB
            chanDir="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${channelId}';")"
            # Then get our clean channel name
            channelNameClean="$(sqDb "SELECT NAME_CLEAN FROM source_channels WHERE ID = '${channelId}';")"
            # Then get our clean file name title
            vidTitleClean="$(sqDb "SELECT TITLE_CLEAN FROM source_videos WHERE ID = '${ytId}';")"
            if ! [[ "${videoOutputDir}/${chanDir}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4" == "${newVideoMediaPath[_${ytId}]}" ]]; then
                # It's not in the right place. Let's move it.
                # Make sure the destination exists
                if ! [[ -d "${videoOutputDir}/${chanDir}" ]]; then
                    if ! mkdir -p "${videoOutputDir}/${chanDir}"; then
                        badExit "163" "Unable to create directory [${videoOutputDir}/${chanDir}]"
                    fi
                    makeShowImage "${chanDir}" "${channelId}"
                fi
                if ! [[ -d "${videoOutputDir}/${chanDir}/Season ${vidYear}" ]]; then
                    if ! mkdir -p "${videoOutputDir}/${chanDir}/Season ${vidYear}"; then
                        badExit "164" "Unable to create directory [${videoOutputDir}/${chanDir}/Season ${vidYear}]"
                    fi
                    makeSeasonImage "${chanDir}" "${vidYear}" "${channelId}"
                fi
                # Move the file
                if ! mv "${newVideoMediaPath[_${ytId}]}" "${videoOutputDir}/${chanDir}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4"; then
                    badExit "165" "Unable to correct found file [${newVideoMediaPath[_${ytId}]}] to [${videoOutputDir}/${chanDir}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4]"
                fi
                # If it had a thumbnail, move that too
                if [[ -e "${newVideoMediaPath[_${ytId}]%.mp4}.jpg" ]]; then
                    if ! mv "${newVideoMediaPath[_${ytId}]%.mp4}.jpg" "${videoOutputDir}/${chanDir}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"; then
                        badExit "166" "Unable to correct found thumbnail [${newVideoMediaPath[_${ytId}]%.mp4}.jpg] to [${videoOutputDir}/${chanDir}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg]"
                    fi
                fi
                printOutput "3" "Corrected found file location for video file ID [${ytId}]"
            fi
        done
    fi

    if [[ -d "${audioOutputDir}" ]]; then
        # Find all the songs in the audio library
        unset newMedia
        newMediaType="audio"
        readarray -t knownMedia < <(find "${audioOutputDir}" -type f -name "*.mp3" -o -name "*.opus")
        for i in "${knownMedia[@]}"; do
            # Make sure we can extract the file ID
            ytId="${i%\].mp3}"
            ytId="${ytId%\].opus}"
            ytId="${ytId##*\[}"
            # See if what we have matches what a file ID should be
            if [[ "${ytId}" =~ ^[A-Za-z0-9_\-]{11}$ ]]; then
                # It's a valid ID
                # Note the file path with an associative array
                # The key is '_${ytId}'
                # The value is the path
                newAudioMediaPath["_${ytId}"]="${i}"
                # Do we have the ID in the database already?
                dbCount="$(sqDb "SELECT COUNT(1) from source_videos WHERE ID = '${ytId}';")"
                if [[ "${dbCount}" -eq "0" ]]; then
                    # It's not in the database, let's add it
                    if compareFileIdToDb "${ytId}" "${i##*.}"; then
                        newMedia+=("${ytId}")
                        vidTitle="$(sqDb "SELECT TITLE from source_videos WHERE ID = '${ytId}';")"
                        if [[ -z "${vidTitle}" ]]; then
                            badExit "167" "Unable to extract audio title from file ID [${ytId}]"
                        fi
                        printOutput "3" "Found untracked audio file ID [${ytId}] [${vidTitle}]"
                    else
                        printOutput "1" "Failed to add file [${i}] to database"
                    fi
                elif [[ "${dbCount}" -eq "1" ]]; then
                    # The video might be in there and the audio not. If so, it'll return 'skipped'
                    if dbReply="$(sqDb "SELECT AUD_STATUS from source_videos WHERE ID = '${ytId}';")"; then
                        printOutput "5" "Successfully looked up audio statis [${dbReply}] for file ID [${ytId}]"
                    else
                        badExit "168" "Failed to look up audio statis [${dbReply}] for file ID [${ytId}]"
                    fi
                    if [[ "${dbReply}" == "skipped" ]]; then
                        if compareFileIdToDb "${ytId}" "${i##*.}"; then
                            newMedia+=("${ytId}")
                            vidTitle="$(sqDb "SELECT TITLE from source_videos WHERE ID = '${ytId}';")"
                            if [[ -z "${vidTitle}" ]]; then
                                badExit "169" "Unable to extract audio title from file ID [${ytId}]"
                            fi
                            printOutput "3" "Found untracked audio file ID [${ytId}] [${vidTitle}]"
                        else
                            printOutput "1" "Failed to add file [${i}] to database"
                        fi
                    fi
                fi
            fi
        done

        if [[ "${#newMedia[@]}" -eq "0" ]]; then
            printOutput "3" "All media from [${audioOutputDir}] logged in database [${#knownMedia[@]} items]"
        fi

        for ytId in "${newMedia[@]}"; do
            # Verify the found file is in the correct path
            # Get our channel ID
            channelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${ytId}';")"
            # Validate it
            if ! [[ "${channelId}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
                printOutput "1" "Channel ID lookup for file ID [${ytId}] returned invalid result [${channelId}]"
                (( n++ ))
                continue
            fi
            # Start by getting our save path from the DB
            chanDir="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${channelId}';")"
            # Then get our clean channel name
            channelNameClean="$(sqDb "SELECT NAME_CLEAN FROM source_channels WHERE ID = '${channelId}';")"
            # Then get our clean file name title
            vidTitleClean="$(sqDb "SELECT TITLE_CLEAN FROM source_videos WHERE ID = '${ytId}';")"
            # Finally, get our audio output format
            audioOutput="$(sqDb "SELECT AUD_FORMAT FROM source_videos WHERE ID = '${ytId}';")"
            if ! [[ "${audioOutputDir}/${chanDir}/${vidTitleClean}/01 - ${vidTitleClean} [${ytId}].${audioOutput}" == "${newAudioMediaPath[_${ytId}]}" ]]; then
                # It's not in the right place. Let's move it.
                # Make sure the destination exists
                if ! [[ -d "${audioOutputDir}/${chanDir}/${vidTitleClean}" ]]; then
                    # Make the destination directory
                    if ! mkdir -p "${audioOutputDir}/${chanDir}/${vidTitleClean}"; then
                        badExit "170" "Unable to create directory [${audioOutputDir}/${chanDir}/${vidTitleClean}]"
                    fi            
                    # If we had an artist.jpg, move it
                    if [[ -e "${newAudioMediaPath[_${ytId}]%/*/*}/artist.jpg" ]]; then
                        if ! mv "${newAudioMediaPath[_${ytId}]%/*/*}/artist.jpg" "${audioOutputDir}/${chanDir}/artist.jpg"; then
                            badExit "171" "Unable to correct artist cover [${newAudioMediaPath[_${ytId}]%/*/*}/artist.jpg] to [${audioOutputDir}/${chanDir}/artist.jpg]"
                        fi
                    fi
                    # If we had a background.jpg, move it
                    if [[ -e "${newAudioMediaPath[_${ytId}]%/*/*}/background.jpg" ]]; then
                        if ! mv "${newAudioMediaPath[_${ytId}]%/*/*}/background.jpg" "${audioOutputDir}/${chanDir}/background.jpg"; then
                            badExit "172" "Unable to correct background [${newAudioMediaPath[_${ytId}]%/*/*}background.jpg] to [${audioOutputDir}/${chanDir}/background.jpg]"
                        fi
                    fi
                fi
                # Move the file
                if ! mv "${newAudioMediaPath[_${ytId}]}" "${audioOutputDir}/${chanDir}/${vidTitleClean}/01 - ${vidTitleClean} [${ytId}].${audioOutput}"; then
                    badExit "173" "Unable to correct found file [${newAudioMediaPath[_${ytId}]}] to [${audioOutputDir}/${chanDir}/${vidTitleClean}/01 - ${vidTitleClean} [${ytId}].${audioOutput}]"
                fi
                # If it had a thumbnail, move that too
                if [[ -e "${newAudioMediaPath[_${ytId}]%/*}/cover.jpg" ]]; then
                    if ! mv "${newAudioMediaPath[_${ytId}]%/*}/cover.jpg" "${audioOutputDir}/${chanDir}/${vidTitleClean}/cover.jpg"; then
                        badExit "174" "Unable to correct album cover [${newAudioMediaPath[_${ytId}]%/*}/cover.jpg] to [${audioOutputDir}/${chanDir}/${vidTitleClean}/cover.jpg]"
                    fi
                fi
                printOutput "3" "Corrected found file location for audio file ID [${ytId}]"
            fi
        done
    fi
    
    unset newMediaType
    verifyMedia="0"
fi

if [[ "${updateRatingKeys}" -eq "1" ]]; then
    printOutput "3" "################ Verifying rating keys ################"
    # Update all rating keys for the video library in database
    printOutput "3" "Updating rating keys for video library"
    # Get a list of shows in the database
    while read -r i; do
        chanPath="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${i}';")"
        if [[ -z "${chanPath}" ]]; then
            badExit "175" "Unable to obtain file path for channel ID [${i}]"
        fi
        # We only need to check it, if the output directory actually exists
        if [[ -d "${videoOutputDir}/${chanPath}" ]]; then
            chanName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${i}';")"
            if [[ -z "${chanName}" ]]; then
                badExit "176" "Unable to obtain channel name for channel ID [${i}]"
            fi
            dbVidSeriesArr["${i}"]="${chanName}"
        fi
    done < <(sqDb "SELECT DISTINCT CHANNEL_ID FROM source_videos WHERE VID_FORMAT != 'none';")
    # Now we have an associative array of dbVidSeriesArr[chanId]="chan name" we can use to systematically eliminate channels we update
    # This will help us make sure we don't miss any

    # Get a list of series rating keys in Plex
    callCurl "${plexAdd}/library/sections/${videoLibraryId}/all?X-Plex-Token=${plexToken}"
    readarray -t plexSeriesArr < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")

    if [[ "${#plexSeriesArr[@]}" -eq "0" ]]; then
        printOutput "2" "No items found in video library"
    else
        # Remove all the old rating keys
        sqDb "DELETE FROM video_rating_key_by_channel;"
        sqDb "DELETE FROM video_rating_key_by_season;"
        sqDb "DELETE FROM video_rating_key_by_item;"
        # Make sure Plex is aware of all media in the library
        refreshLibrary "${videoLibraryId}"
        # Rule of thumb: Wait 30 seconds per series, minimum of 30 seconds, maximum of 10 minutes
        scanWait="$(( ${#plexSeriesArr[@]} * 30 ))"
        if [[ "${scanWait}" -lt "30" ]]; then
            scanWait="30"
        elif [[ "${scanWait}" -gt "600" ]]; then
            scanWait="600"
        fi
        printOutput "4" "Waiting [${scanWait}] seconds for Plex Media Scanner to update video file library"
        sleep "${scanWait}"
    fi

    printOutput "3" "Updating rating keys for [${#plexSeriesArr[@]}] series"
    for i in "${plexSeriesArr[@]}"; do
        # Recycling variables is bad, m'kay?
        unset foundSeriesKey seasonYearArr plexSeasonArr

        printOutput "4" "Processing video series rating key [${i}]"
        # For each series, get a list of seasons
        callCurl "${plexAdd}/library/metadata/${i}/children?X-Plex-Token=${plexToken}"
        while read -r ii; do
            if ! [[ "${ii}" == "null" ]]; then
                plexSeasonArr+=("${ii}")
            fi
        done < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
        # Also get a corresponding list of years for each of those seasons
        for ii in "${plexSeasonArr[@]}"; do
            seasonYearArr["${ii}"]="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${ii}\" ) .\"+@index\"" <<<"${curlOutput}")"
        done
        # For each season, get a list of episodes
        for ii in "${plexSeasonArr[@]}"; do
            unset plexEpisodeArr
            printOutput "5" "Processing video season rating key [${ii}]"
            # Get the file list for the season
            callCurl "${plexAdd}/library/metadata/${ii}/children?X-Plex-Token=${plexToken}"
            while read -r iii; do
                if ! [[ "${iii}" == "null" ]]; then
                    plexEpisodeArr+=("${iii}")
                fi
            done < <(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
            # For each episode rating key
            for iii in "${plexEpisodeArr[@]}"; do
                printOutput "5" "Processing video file rating key [${iii}]"
                # Isolate the file ID
                foundFileId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${iii}\" ) .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                foundFileId="${foundFileId%\]\.*}"
                foundFileId="${foundFileId##*\[}"
                # Now we've isolated the file ID, let's set it in the database
                videoFileRatingKey["_${foundFileId}"]="${iii}"

                # Safety check
                if [[ -z "${foundFileId}" ]]; then
                    printOutput "1" "Null file ID key returned [seriesRK:${i}][seasonRK:${ii}][itemRK:${iii}]"
                    continue 3
                fi

                dbCount="$(sqDb "SELECT COUNT(1) FROM video_rating_key_by_item WHERE RATING_KEY = '${iii}';")"
                if [[ "${dbCount}" -eq "0" ]]; then
                    # It does not exist in the database, use an 'insert'
                    if sqDb "INSERT INTO video_rating_key_by_item (RATING_KEY, ID, UPDATED) VALUES ('${iii}', '${foundFileId}', $(date +%s));"; then
                        printOutput "5" "Added file rating key [${iii}] to database"
                    else
                        badExit "177" "Adding file rating key [${iii}] to database failed"
                    fi
                elif [[ "${dbCount}" -eq "1" ]]; then
                    # It exists in the database, use an 'update'
                    if sqDb "UPDATE video_rating_key_by_item SET ID = '${foundFileId}', UPDATED = $(date +%s) WHERE RATING_KEY = '${iii}';"; then
                        printOutput "5" "Added file rating key [${iii}] to database"
                    else
                        badExit "178" "Adding file rating key [${iii}] to database failed"
                    fi
                else
                    badExit "179" "Database count for file ID [${iii}] in video_rating_key_by_item table returned greater than 1 -- Possible database corruption"
                fi

                # If we haven't set our 'foundSeriesKey', let's set it now
                if [[ -z "${foundSeriesKey}" ]]; then
                    foundSeriesKey="${i}"
                    # Add it to the database
                    # We need the channel ID
                    channelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${foundFileId}';")"

                    # Safety check
                    if [[ -z "${channelId}" ]]; then
                        printOutput "1" "Null channel ID returned [seriesRK:${i}][seasonRK:${ii}][itemRK:${iii}][fID:${foundFileId}]}"
                        continue 3
                    fi

                    dbCount="$(sqDb "SELECT COUNT(1) FROM video_rating_key_by_channel WHERE RATING_KEY = '${foundSeriesKey}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # It does not exist in the database, use an 'insert'
                        if sqDb "INSERT INTO video_rating_key_by_channel (RATING_KEY, CHANNEL_ID, UPDATED) VALUES ('${foundSeriesKey}', '${channelId}', $(date +%s));"; then
                            printOutput "5" "Added show rating key [${foundSeriesKey}] to database"
                        else
                            badExit "180" "Adding show rating key [${foundSeriesKey}] to database failed"
                        fi
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # It exists in the database, use an 'update'
                        if sqDb "UPDATE video_rating_key_by_channel SET CHANNEL_ID = '${channelId}', UPDATED = $(date +%s) WHERE RATING_KEY = '${foundSeriesKey}';"; then
                            printOutput "5" "Added show rating key [${foundSeriesKey}] to database"
                        else
                            badExit "181" "Adding show rating key [${foundSeriesKey}] to database failed"
                        fi
                    else
                        badExit "182" "Database count for show ID [${foundSeriesKey}] in video_rating_key_by_channel table returned greater than 1 -- Possible database corruption"
                    fi

                    # Remove this series from our list of series we haven't updated
                    unset dbVidSeriesArr["${channelId}"]
                fi
            done

            # We should now have an assigned channel ID, so let's update the season's rating key as well

            # Safety check
            if [[ -z "${channelId}" ]]; then
                printOutput "1" "Null channel ID returned [seriesRK:${i}][seasonRK:${ii}][itemRK:${iii}][fID:${foundFileId}]}"
                continue 3
            fi
            if [[ -z "${seasonYearArr[${ii}]}" ]]; then
                printOutput "1" "Null year returned [seriesRK:${i}][seasonRK:${ii}][itemRK:${iii}][fID:${foundFileId}]}"
                continue 3
            fi

            dbCount="$(sqDb "SELECT COUNT(1) FROM video_rating_key_by_season WHERE RATING_KEY = '${ii}';")"
            if [[ "${dbCount}" -eq "0" ]]; then
                # It does not exist in the database, use an 'insert'
                if sqDb "INSERT INTO video_rating_key_by_season (RATING_KEY, YEAR, CHANNEL_ID, UPDATED) VALUES ('${ii}', ${seasonYearArr[${ii}]}, '${channelId}', $(date +%s));"; then
                    printOutput "5" "Added season rating key [${ii}] to database"
                else
                    badExit "183" "Adding season rating key [${ii}] to database failed"
                fi
            elif [[ "${dbCount}" -eq "1" ]]; then
                # It exists in the database, use an 'update'
                if sqDb "UPDATE video_rating_key_by_season SET CHANNEL_ID = '${channelId}', YEAR = ${seasonYearArr[${ii}]}, UPDATED = $(date +%s) WHERE RATING_KEY = '${ii}';"; then
                    printOutput "5" "Added season rating key [${ii}] to database"
                else
                    badExit "184" "Adding season rating key [${ii}] to database failed"
                fi
            else
                badExit "185" "Database count for season ID [${ii}] in video_rating_key_by_season table returned greater than 1 -- Possible database corruption"
            fi
        done
    done

    for key in "${!dbVidSeriesArr[@]}"; do
        printOutput "1" "Unable to locate videos for channel ID [${key}] [${dbVidSeriesArr[${key}]}] in Plex"
    done

    # Update all rating keys for the audio library in database
    printOutput "3" "Updating rating keys for audio library"
    # Get a list of shows in the database
    while read -r i; do
        chanPath="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${i}';")"
        if [[ -z "${chanPath}" ]]; then
            badExit "186" "Unable to obtain file path for channel ID [${i}]"
        fi
        # We only need to check it if the output directory actually exists
        if [[ -d "${audioOutputDir}/${chanPath}" ]]; then
            chanName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${i}';")"
            if [[ -z "${chanName}" ]]; then
                badExit "187" "Unable to obtain channel name for channel ID [${i}]"
            fi
            dbAudSeriesArr["${i}"]="${chanName}"
        fi
    done < <(sqDb "SELECT DISTINCT CHANNEL_ID FROM source_videos WHERE AUD_FORMAT != 'none';")
    # Now we have an associative array of dbAudSeriesArr[chanId]="chan name" we can use to systematically eliminate channels we update
    # This will help us make sure we don't miss any

    # Get a list of series rating keys in Plex
    callCurl "${plexAdd}/library/sections/${audioLibraryId}/all?X-Plex-Token=${plexToken}"
    readarray -t plexMusicArr < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")

    if [[ "${#plexMusicArr[@]}" -eq "0" ]]; then
        printOutput "2" "No items found in audio library"
    else
        # Remove all the old rating keys
        sqDb "DELETE FROM audio_rating_key_by_channel;"
        sqDb "DELETE FROM audio_rating_key_by_album;"
        sqDb "DELETE FROM audio_rating_key_by_item;"
        # Make sure Plex is aware of all media in the library
        refreshLibrary "${audioLibraryId}"
        # Rule of thumb: Wait 10 seconds per series, minimum of 30 seconds, maximum of 10 minutes
        scanWait="$(( ${#plexMusicArr[@]} * 10 ))"
        if [[ "${scanWait}" -lt "30" ]]; then
            scanWait="30"
        elif [[ "${scanWait}" -gt "600" ]]; then
            scanWait="600"
        fi
        printOutput "4" "Waiting [${scanWait}] seconds for Plex Media Scanner to update audio file library"
        sleep "${scanWait}"
    fi

    printOutput "3" "Updating rating keys for [${#plexMusicArr[@]}] artists"
    for i in "${plexMusicArr[@]}"; do
        # Recycling variables is bad, m'kay?
        unset albumYearArr plexAlbumArr

        printOutput "4" "Processing audio series rating key [${i}]"
        # For each series, get a list of seasons
        callCurl "${plexAdd}/library/metadata/${i}/children?X-Plex-Token=${plexToken}"
        while read -r ii; do
            if ! [[ "${ii}" == "null" ]]; then
                plexAlbumArr+=("${ii}")
            fi
        done < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
        # For each season, get a list of episodes
        for ii in "${plexAlbumArr[@]}"; do
            unset plexTrackArr
            printOutput "5" "Processing audio album rating key [${ii}]"
            # Get the file list for the season
            callCurl "${plexAdd}/library/metadata/${ii}/children?X-Plex-Token=${plexToken}"
            while read -r iii; do
                if ! [[ "${iii}" == "null" ]]; then
                    plexTrackArr+=("${iii}")
                fi
            done < <(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
            # For each episode rating key
            for iii in "${plexTrackArr[@]}"; do
                printOutput "5" "Processing track file rating key [${iii}]"
                # Isolate the file ID
                foundFileId="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${iii}\" ) .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                foundFileId="${foundFileId%\].*}"
                foundFileId="${foundFileId##*\[}"

                # Safety check
                if [[ -z "${foundFileId}" ]]; then
                    printOutput "1" "Null file ID key returned [seriesRK:${i}][seasonRK:${ii}][itemRK:${iii}]"
                    continue 3
                fi

                # Now we've isolated the file ID, let's set it in the database
                dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_item WHERE RATING_KEY = '${iii}';")"
                if [[ "${dbCount}" -eq "0" ]]; then
                    # It does not exist in the database, use an 'insert'
                    if sqDb "INSERT INTO audio_rating_key_by_item (RATING_KEY, ID, UPDATED) VALUES ('${iii}', '${foundFileId}', $(date +%s));"; then
                        printOutput "5" "Added file rating key [${iii}] to database"
                    else
                        badExit "188" "Adding file rating key [${iii}] to database failed"
                    fi
                elif [[ "${dbCount}" -eq "1" ]]; then
                    # It exists in the database, use an 'update'
                    if sqDb "UPDATE audio_rating_key_by_item SET ID = '${foundFileId}', UPDATED = $(date +%s) WHERE RATING_KEY = '${iii}';"; then
                        printOutput "5" "Added file rating key [${iii}] to database"
                    else
                        badExit "189" "Adding file rating key [${iii}] to database failed"
                    fi
                else
                    badExit "190" "Database count for file ID [${iii}] in audio_rating_key_by_item table returned greater than 1 -- Possible database corruption"
                fi

                foundArtistKey="${i}"
                # Add it to the database
                # We need the channel ID
                channelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${foundFileId}';")"

                # Safety check
                if [[ -z "${channelId}" ]]; then
                    printOutput "1" "Null channel ID returned [seriesRK:${i}][seasonRK:${ii}][itemRK:${iii}][fID:${foundFileId}]}"
                fi

                dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_channel WHERE RATING_KEY = '${foundArtistKey}';")"
                if [[ "${dbCount}" -eq "0" ]]; then
                    # It does not exist in the database, use an 'insert'
                    if sqDb "INSERT INTO audio_rating_key_by_channel (RATING_KEY, CHANNEL_ID, UPDATED) VALUES ('${foundArtistKey}', '${channelId}', $(date +%s));"; then
                        printOutput "5" "Added album rating key [${foundArtistKey}] to database"
                    else
                        badExit "191" "Adding album rating key [${foundArtistKey}] to database failed"
                    fi
                elif [[ "${dbCount}" -eq "1" ]]; then
                    # It exists in the database, use an 'update'
                    if sqDb "UPDATE audio_rating_key_by_channel SET CHANNEL_ID = '${channelId}', UPDATED = $(date +%s) WHERE RATING_KEY = '${foundArtistKey}';"; then
                        printOutput "5" "Added album rating key [${foundArtistKey}] to database"
                    else
                        badExit "192" "Adding album rating key [${foundArtistKey}] to database failed"
                    fi
                else
                    badExit "193" "Database count for album ID [${foundArtistKey}] in audio_rating_key_by_channel table returned greater than 1 -- Possible database corruption"
                fi

                # We should now have an assigned file ID, so let's update the season's rating key as well

                dbCount="$(sqDb "SELECT COUNT(1) FROM audio_rating_key_by_album WHERE RATING_KEY = '${ii}';")"
                if [[ "${dbCount}" -eq "0" ]]; then
                    # It does not exist in the database, use an 'insert'
                    if sqDb "INSERT INTO audio_rating_key_by_album (RATING_KEY, ID, UPDATED) VALUES ('${ii}', '${foundFileId}', $(date +%s));"; then
                        printOutput "5" "Added season rating key [${ii}] to database"
                    else
                        badExit "194" "Adding season rating key [${ii}] to database failed"
                    fi
                elif [[ "${dbCount}" -eq "1" ]]; then
                    # It exists in the database, use an 'update'
                    if sqDb "UPDATE audio_rating_key_by_album SET ID = '${foundFileId}', UPDATED = $(date +%s) WHERE RATING_KEY = '${ii}';"; then
                        printOutput "5" "Added season rating key [${ii}] to database"
                    else
                        badExit "195" "Adding season rating key [${ii}] to database failed"
                    fi
                else
                    badExit "196" "Database count for season ID [${ii}] in audio_rating_key_by_album table returned greater than 1 -- Possible database corruption"
                fi

                # Remove this series from our list of series we haven't updated
                unset dbAudSeriesArr["${channelId}"]
            done
        done
    done

    for key in "${!dbAudSeriesArr[@]}"; do
        printOutput "1" "Unable to locate tracks for channel ID [${key}] [${dbAudSeriesArr[${key}]}] in Plex"
    done
fi

if [[ "${updateMetadata}" -eq "1" ]]; then
    printOutput "3" "################## Updating metadata ##################"
    # Update all channel information in database
    readarray -t chanIds < <(sqDb "SELECT ID FROM source_channels;")
    for channelId in "${chanIds[@]}"; do
        if ! getChannelInfo "${channelId}"; then
            printOutput "1" "Failed to retrieve channel info for [${channelId}]"
        fi
    done

    # Update all playlist information in database
    readarray -t plIds < <(sqDb "SELECT ID FROM source_playlists;")
    for plId in "${plIds[@]}"; do
        if ! getPlaylistInfo "${plId}"; then
            printOutput "1" "Failed to retrieve playlist info for [${plId}]"
        fi
    done

    # Update all series metadata in Plex
    readarray -t plexSeries < <(sqDb "SELECT RATING_KEY FROM video_rating_key_by_channel;")
    for ratingKey in "${plexSeries[@]}"; do
        if ! setSeriesMetadata "${ratingKey}"; then
            printOutput "1" "Failed to update metadata for series rating key [${ratingKey}]"
        fi
    done

    # Update all artist metadata in Plex
    readarray -t plexArtists < <(sqDb "SELECT RATING_KEY FROM audio_rating_key_by_channel;")
    for ratingKey in "${plexArtists[@]}"; do
        if ! setArtistMetadata "${ratingKey}"; then
            printOutput "1" "Failed to update metadata for artist rating key [${ratingKey}]"
        fi
    done

    # Update all album metadata in Plex
    readarray -t plexAlbums < <(sqDb "SELECT RATING_KEY FROM audio_rating_key_by_album;")
    for ratingKey in "${plexAlbums[@]}"; do
        if ! setAlbumMetadata "${ratingKey}"; then
            printOutput "1" "Failed to update metadata for album rating key [${ratingKey}]"
        fi
    done

    # Update all playlist descriptions and images in Plex
    readarray -t plexPlaylists < <(sqDb "SELECT ID FROM source_playlists;")
    for plId in "${plexPlaylists[@]}"; do
        # Update its info
        getPlaylistInfo "${plId}"
        # See if it has a video rating key
        plVidRk="$(sqDb "SELECT VID_RATING_KEY FROM source_playlists WHERE ID = '${plId}';")"
        # See if it has an audio rating key
        plAudRk="$(sqDb "SELECT AUD_RATING_KEY FROM source_playlists WHERE ID = '${plId}';")"
        if [[ -n "${plVidRk}" ]]; then
            updatePlaylistInfo "${plId}" "${plVidRk}"
        fi
        if [[ -n "${plAudRk}" ]]; then
            updatePlaylistInfo "${plId}" "${plAudRk}"
        fi
    done
fi

if [[ "${skipDownload}" -eq "0" ]]; then
    for source in "${realPath%/*}/${scriptName%.bash}.sources/"*".env"; do
        printOutput "3" "############### Processing media sources ##############"
        # Unset some variables we need to be able to be blank
        unset itemType videoArr channelId backupVideoArr
        # Unset some variables from the previous source
        unset sourceUrl sponsorblockOpts videoOutput audioOutput vidIncludeShorts audIncludeShorts markWatched includeLiveBroadcasts
        printOutput "3" "Processing source: ${source##*/}"
        source "${source}"
        
        if [[ -z "${sourceUrl}" ]]; then
            printOutput "1" "No source URL provided in input file [${source##*/}]"
            continue
        fi

        printOutput "4" "Validating source config"
        # Verify source config options
        if ! [[ "${sponsorblockOpts,,}" =~ ^(mark|remove)$ ]]; then
            sponsorblockOpts="disable"
        else
            sponsorblockOpts="${sponsorblockOpts,,}"
        fi
        if ! [[ "${markWatched,,}" == "true" ]]; then
            markWatched="false"
        else
            markWatched="${markWatched,,}"
        fi
        if ! [[ "${vidIncludeShorts,,}" == "true" ]]; then
            vidIncludeShorts="false"
        else
            vidIncludeShorts="${vidIncludeShorts,,}"
        fi
        if ! [[ "${audIncludeShorts,,}" == "true" ]]; then
            audIncludeShorts="false"
        else
            audIncludeShorts="${audIncludeShorts,,}"
        fi
        if ! [[ "${includeLiveBroadcasts,,}" == "true" ]]; then
            includeLiveBroadcasts="false"
        else
            includeLiveBroadcasts="${includeLiveBroadcasts,,}"
        fi

        if [[ "${videoOutput,,}" == "none" ]]; then
            videoOutput="none"
        elif [[ "${videoOutput,,}" == "144p" ]]; then
            videoOutput="144"
        elif [[ "${videoOutput,,}" == "240p" ]]; then
            videoOutput="240"
        elif [[ "${videoOutput,,}" == "360p" ]]; then
            videoOutput="360"
        elif [[ "${videoOutput,,}" == "480p" ]]; then
            videoOutput="480"
        elif [[ "${videoOutput,,}" == "720p" ]]; then
            videoOutput="720"
        elif [[ "${videoOutput,,}" == "1080p" ]]; then
            videoOutput="1080"
        elif [[ "${videoOutput,,}" == "1440p" || "${videoOutput,,}" == "2k" ]]; then
            videoOutput="1440"
        elif [[ "${videoOutput,,}" == "2160p" || "${videoOutput,,}" == "4k" ]]; then
            videoOutput="2160"
        elif [[ "${videoOutput,,}" == "4320p" || "${videoOutput,,}" == "8k" ]]; then
            videoOutput="4320"
        elif [[ "${videoOutput,,}" == "original" ]]; then
            videoOutput="original"
        else
            videoOutput="original"
        fi

        if [[ "${audioOutput,,}" == "opus" ]]; then
            audioOutput="opus"
        elif [[ "${audioOutput,,}" == "mp3" ]]; then
            audioOutput="mp3"
        else
            audioOutput="none"
        fi
        printOutput "5" "Validated config options:"
        printOutput "5" "sponsorblockOpts: ${sponsorblockOpts}"
        printOutput "5" "markWatched: ${markWatched}"
        printOutput "5" "vidIncludeShorts: ${vidIncludeShorts}"
        printOutput "5" "audIncludeShorts: ${audIncludeShorts}"
        printOutput "5" "includeLiveBroadcasts: ${includeLiveBroadcasts}"
        printOutput "5" "videoOutput: ${videoOutput}"
        printOutput "5" "audioOutput: ${audioOutput}"

        # Parse the source URL
        printOutput "4" "Parsing source URL [${sourceUrl}]"
        id="${sourceUrl#http:\/\/}"
        id="${id#https:\/\/}"
        id="${id#m\.}"
        id="${id#www\.}"
        if [[ "${id:0:8}" == "youtu.be" ]]; then
            # I think these short URL's can only be a video ID?
            itemType="video"
            ytId="${id:9:11}"
            printOutput "4" "Found file ID [${ytId}]"
        elif [[ "${id:12:6}" == "shorts" ]]; then
            # This is a video ID for a short
            itemType="video"
            ytId="${id:19:11}"
            printOutput "4" "Found short file ID [${ytId}]"
        elif [[ "${id:0:8}" == "youtube." ]]; then
            # This can be a video ID, a channel ID, a channel name, or a playlist
            if [[ "${id:12:1}" == "@" ]]; then
                printOutput "4" "Found username"
                # It's a username
                ytId="${id:13}"
                ytId="${ytId%\&*}"
                ytId="${ytId%\?*}"
                ytId="${ytId%\/*}"
                # We have the "@username", we need the channel ID
                # Try using yt-dlp as an API First
                printOutput "3" "Calling yt-dlp to obtain channel ID from channel handle [@${ytId}]"
                if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
                    channelId="$(yt-dlp -J --playlist-items 0 --cookies "${cookieFile}" "https://www.youtube.com/@${ytId}")"
                else
                    channelId="$(yt-dlp -J --playlist-items 0 "https://www.youtube.com/@${ytId}")"
                fi
                throttleDlp
                
                channelId="$(yq -p json ".channel_id" <<<"${channelId}")"
                if ! [[ "${channelId}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
                    # We don't, let's try the official API
                    printOutput "3" "Calling API to obtain channel ID from channel handle [@${ytId}]"
                    ytApiCall "channels?forHandle=@${ytId}&part=snippet"
                    apiResults="$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")"
                    
                    if ! validateInterger "${apiResults}"; then
                        printOutput "1" "Variable apiResults [${apiResults}] failed to validate -- Unable to continue"
                        return 1
                    fi
                    
                    if [[ "${apiResults}" -eq "0" ]]; then
                        printOutput "1" "API lookup for source parsing returned zero results"
                        return 1
                    fi
                    if [[ "$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")" -eq "1" ]]; then
                        channelId="$(yq -p json ".items[0].id" <<<"${curlOutput}")"
                        # Validate it
                        if ! [[ "${channelId}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
                            ### SKIP CONDITION
                            printOutput "1" "Unable to validate channel ID for [@${ytId}]"
                            continue
                        fi
                    else
                        printOutput "1" "Unable to isolate channel ID for [${sourceUrl}]"
                        continue
                    fi
                fi
                printAngryWarning
                printOutput "1" "Channel usernames are less reliable than channel ID's, as usernames can be changed, but ID's can not."
                printOutput "1" "Please consider replacing your source URL:"
                printOutput "1" "  ${sourceUrl}"
                printOutput "1" "with:"
                printOutput "1" "  https://www.youtube.com/channel/${channelId}"
                printOutput "2" " "
                printOutput "3" "Found channel ID [${channelId}] for handle [@${ytId}]"
                itemType="channel"
            elif [[ "${id:12:8}" == "watch?v=" ]]; then
                # It's a video ID
                printOutput "4" "Found video ID"
                itemType="video"
                ytId="${id:20:11}"
            elif [[ "${id:12:7}" == "channel" ]]; then
                # It's a channel ID
                printOutput "4" "Found channel ID"
                itemType="channel"
                channelId="${id:20:24}"
            elif [[ "${id:12:8}" == "playlist" ]]; then
                # It's a playlist
                printOutput "4" "Found playlist"
                itemType="playlist"
                if [[ "${id:26:2}" == "WL" ]]; then
                    # Watch later
                    plId="${id:26:2}"
                elif [[ "${id:26:2}" == "LL" ]]; then
                    # Liked videos
                    plId="${id:26:2}"
                elif [[ "${id:26:2}" == "PL" ]]; then
                    # Public playlist?
                    plId="${id:26:34}"
                fi
            fi
        else
            printOutput "1" "Unable to parse input [${id}] -- skipping"
            continue
        fi

        if [[ "${itemType}" == "video" ]]; then
            # Add it to our array of videos to process
            videoArr+=("${ytId}")
            configLevel="1"
        elif [[ "${itemType}" == "channel" ]]; then
            # We should use ${channelId} for the channel ID rather than ${ytId} which could be the handle
            # Get a list of the videos for the channel
            printOutput "3" "Getting video list for channel ID [${channelId}]"
            if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
                while read -r i; do
                    videoArr+=("${i}")
                    backupVideoArr+=("${i}")
                done < <(yt-dlp --flat-playlist --no-warnings --cookies "${cookieFile}" --print "%(id)s" "https://www.youtube.com/channel/${channelId}")
            else
                while read -r i; do
                    videoArr+=("${i}")
                    backupVideoArr+=("${i}")
                done < <(yt-dlp --flat-playlist --no-warnings --print "%(id)s" "https://www.youtube.com/channel/${channelId}")
            fi
            throttleDlp
            
            printOutput "4" "Pulled list of [${#videoArr[@]}] videos from channel"

            # Assign config levels
            configLevel="3"

            # Check to make sure we should continue to ignore any shorts for this channel
            if ! [[ "${videoOutput,,}" == "none" ]]; then
                if [[ "${vidIncludeShorts,,}" == "true" ]]; then
                    dbReply="$(sqDb "SELECT COUNT(1) FROM source_videos WHERE CHANNEL_ID = '${channelId}' AND TYPE = 'short' AND VID_STATUS = 'skipped';")"
                    if [[ "${dbReply}" -ne "0" ]]; then
                        # We need to re-process the videos that matched
                        printOutput "2" "Found [${dbReply}] previously indexed and skipped shorts to be processed"
                        while read -r ytId; do
                            printOutput "4" "Setting file ID [${ytId}] to status 'queued'"
                            # Update its status to queued
                            if ! sqDb "UPDATE source_videos SET VID_STATUS = 'queued', TYPE = 'short', UPDATED = '$(date +%s)' WHERE ID = '${ytId}';"; then
                                printOutput "1" "Update for file ID [${ytId}] failed -- Skipping"
                                continue
                            fi
                        done < <(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${channelId}' AND TYPE = 'short' AND VID_STATUS = 'skipped';")
                    fi
                fi
            fi
            if ! [[ "${audioOutput,,}" == "none" ]]; then
                if [[ "${audIncludeShorts,,}" == "true" ]]; then
                    dbReply="$(sqDb "SELECT COUNT(1) FROM source_videos WHERE CHANNEL_ID = '${channelId}' AND TYPE = 'short' AND AUD_STATUS = 'skipped';")"
                    if [[ "${dbReply}" -ne "0" ]]; then
                        # We need to re-process the videos that matched
                        printOutput "2" "Found [${dbReply}] previously indexed and skipped shorts to be processed"
                        while read -r ytId; do
                            printOutput "4" "Setting file ID [${ytId}] to status 'queued'"
                            # Update its status to queued
                            if ! sqDb "UPDATE source_videos SET AUD_STATUS = 'queued', TYPE = 'short', UPDATED = '$(date +%s)' WHERE ID = '${ytId}';"; then
                                printOutput "1" "Update for file ID [${ytId}] failed -- Skipping"
                                continue
                            fi
                        done < <(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${channelId}' AND TYPE = 'short' AND AUD_STATUS = 'skipped';")
                    fi
                fi
            fi

            # Find out what videos we have in our database for this channel ID
            readarray -t dbVidArray < <(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${channelId}';")
            printOutput "4" "Pulled list of [${#dbVidArray[@]}] videos from channel in database"

            # Check to see if the results are identical
            printOutput "4" "Comparing lists to check for any un-indexed content"
            for z in "${!videoArr[@]}"; do
                isMissing="1"
                for zz in "${dbVidArray[@]}"; do
                    if [[ "${videoArr[${z}]}" == "${zz}" ]]; then
                        isMissing="0"
                        continue
                    fi
                done
                if [[ "${isMissing}" -eq "0" ]]; then
                    unset videoArr["${z}"]
                fi
            done

            # Check to see if there's no new videos. If so, we can skip further processing here.
            if [[ "${#videoArr[@]}" -eq "0" ]]; then
                printOutput "3" "No new content from source detected"
                if [[ "${forceSourceUpdate}" -eq "1" ]]; then
                    printOutput "3" "Forcing content update from source"
                    for i in "${backupVideoArr[@]}"; do
                        videoArr+=("${i}")
                    done
                else
                    continue
                fi
            fi
        elif [[ "${itemType}" == "playlist" ]]; then
            printOutput "3" "Processing playlist ID [${plId}]"
            # Is the playlist already in our database?
            dbReply="$(sqDb "SELECT COUNT(1) FROM source_playlists WHERE ID = '${plId}';")"
            if [[ "${dbReply}" -eq "0" ]]; then
                # It is not, add it
                newPlaylists+=("${plId}")
                if ! getPlaylistInfo "${plId}"; then
                    printOutput "1" "Failed to retrieve playlist info for [${plId}] -- Skipping source"
                    continue
                fi
            elif [[ "${dbReply}" -ge "2" ]]; then
                badExit "197" "Database query returned [${dbReply}] results -- Possible database corruption"
            elif [[ "${dbReply}" -eq "1" ]]; then
                # Get its visibility
                plVis="$(sqDb "SELECT VISIBILITY FROM source_playlists WHERE ID = '${plId}';")"
                # Get its title
                plTitle="$(sqDb "SELECT TITLE FROM source_playlists WHERE ID = '${plId}';")"
                
                if [[ "${forceSourceUpdate}" -eq "1" ]]; then
                    printOutput "3" "Forcing content update for playlist"
                    newPlaylists+=("${plId}")
                    if ! getPlaylistInfo "${plId}"; then
                        printOutput "1" "Failed to retrieve playlist info for [${plId}] -- Skipping source"
                        continue
                    fi
                fi
            else
                badExit "198" "Impossible condition"
            fi

            # Get a list of videos in the playlist -- Easier/faster to do this via yt-dlp than API
            if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
                while read -r i; do
                    videoArr+=("${i}")
                    backupVideoArr+=("${i}")
                done < <(yt-dlp --cookies "${cookieFile}" --flat-playlist --no-warnings --print "%(id)s" "https://www.youtube.com/playlist?list=${plId}")
            else
                while read -r i; do
                    videoArr+=("${i}")
                    backupVideoArr+=("${i}")
                done < <(yt-dlp --flat-playlist --no-warnings --print "%(id)s" "https://www.youtube.com/playlist?list=${plId}")
            fi
            throttleDlp

            # Assign config levels
            configLevel="2"

            # Find out what videos we have in our database for this channel ID
            readarray -t dbVidArray < <(sqDb "SELECT ID FROM playlist_order WHERE PLAYLIST_KEY = '${plId}';")
            
            # Check to make sure all the videos in the database playlist order are (still) in the official order
            resortPlaylist="0"
            for z in "${dbVidArray[@]}"; do
                inPlaylist="0"
                for zz in "${videoArr[@]}"; do
                    if [[ "${z}" == "${zz}" ]]; then
                        inPlaylist="1"
                        break
                    fi
                done
                if [[ "${inPlaylist}" -eq "0" ]]; then
                    printOutput "4" "File ID [${z}] appears to have been removed from playlist ID [${plId}]"
                    # Mark this playlist ID as needing re-sorting
                    resortPlaylist="1"
                fi
            done
            
            # If we removed anything from the playlist order database, we should re-sort its order
            if [[ "${resortPlaylist}" -eq "1" ]]; then
                unset dbVidArray
                # Delete any rows where our playlist ID is the one we're currently working with
                if ! sqDb "DELETE FROM playlist_order WHERE PLAYLIST_KEY = '${plId}';"; then
                    printOutput "1" "Failed to remove stale playlist order keys for playlist ID [${plId}]"
                fi
            fi

            # Clear out any previous playlist position arrays
            unset plPosArr
            # Check to see if the master playlist matches the local playlist
            for z in "${!videoArr[@]}"; do
                plPosArr["${z}"]="${videoArr[${z}]}"
                
                if [[ "${videoArr[${z}]}" == "${dbVidArray[${z}]}" ]]; then
                    # It's in the correct position
                    # Verify that the video is indexed
                    # (Did a private one become visible?)
                    dbReply="$(sqDb "SELECT COUNT(1) FROM source_videos WHERE ID = '${videoArr[${z}]}';")"
                    if [[ "${dbReply}" -eq "0" ]]; then
                        # We need to index this video
                        if ! compareFileIdToDb "${videoArr[${z}]}"; then
                            printOutput "1" "Skipping ID [${videoArr[${z}]}]"
                        fi
                    elif [[ "${dbReply}" -eq "1" ]]; then
                        unset videoArr["${z}"]
                    elif [[ "${dbReply}" -ge "2" ]]; then
                        badExit "199" "Database query returned [${dbReply}] results -- Possible database corruption"
                    else
                        badExit "200" "Impossible condition"
                    fi
                fi
            done

            # Add/compare it to the 'playlist_order' table
            pos="1"
            posChanged="0"
            for ytId in "${plPosArr[@]}"; do
                dbReply="$(sqDb "SELECT COUNT(1) FROM playlist_order WHERE ID = '${ytId}' AND PLAYLIST_KEY = '${plId}';")"
                if [[ "${dbReply}" -eq "0" ]]; then
                    # Doesn't exist, insert it
                    # Get the ID number for sqlite, since we can't have multiple rows with a ytId as its unique ID in the DB
                    idCount="$(sqDb "SELECT SQID FROM playlist_order ORDER BY SQID DESC LIMIT 1;")"
                    if [[ -z "${idCount}" ]]; then
                        idCount="0"
                    fi
                    if [[ "${idCount}" =~ ^[0-9]+$ ]]; then
                        (( idCount++ ))
                    else
                        badExit "201" "SQLite returned non-interger for ID count [${idCount}]"
                    fi
                    if sqDb "INSERT INTO playlist_order (SQID, ID, PLAYLIST_INDEX, PLAYLIST_KEY, UPDATED) VALUES (${idCount}, '${ytId}', ${pos}, '${plId}', $(date +%s));"; then
                        printOutput "4" "Added file ID [${ytId}] to database to playlist [${plTitle}]"
                    else
                        badExit "202" "Adding file ID [${ytId}][Pos: ${pos}] to database under playlist ID [${plId}] failed"
                    fi
                    posChanged="1"
                elif [[ "${dbReply}" -eq "1" ]]; then
                    # Exists, what position is it.
                    dbReply="$(sqDb "SELECT PLAYLIST_INDEX FROM playlist_order WHERE ID = '${ytId}' AND PLAYLIST_KEY = '${plId}';")"
                    if ! [[ "${dbReply}" -eq "${pos}" ]]; then
                        # Doesn't match our position, update it
                        if sqDb "UPDATE playlist_order SET PLAYLIST_INDEX = ${pos}, PLAYLIST_KEY = '${plId}', UPDATED = '$(date +%s)' WHERE ID = '${ytId}';"; then
                            printOutput "3" "Updated file ID [${ytId}] to position [${pos}] in playlist [${plId}]"
                        else
                            badExit "203" "Updating file ID [${ytId}] to position [${pos}] in playlist [${plId}] failed"
                        fi
                        posChanged="1"
                    fi
                elif [[ "${dbReply}" -ge "2" ]]; then
                    badExit "204" "Database query returned [${dbReply}] results -- Possible database corruption"
                else
                    badExit "205" "Impossible condition"
                fi
                (( pos++ ))
            done
            
            # If we're being forced to update the source, process all the items in the playlist
            if [[ "${forceSourceUpdate}" -eq "1" ]]; then
                printOutput "3" "Forcing content update from source"
                unset videoArr
                for i in "${backupVideoArr[@]}"; do 
                    videoArr+=("${i}")
                done
            elif [[ "${#videoArr[@]}" -eq "0" && "${posChanged}" -eq "0" ]]; then
                printOutput "3" "No content changes detected in playlist, skipping further processing"
                continue
            fi

            # If we've reached this far, we need to make a note that this playlist needs updating
            updatedPlaylists+=("${plId}")
        fi

        # Iterate through our video list
        printOutput "3" "Found [${#videoArr[@]}] video ID's to be processed into database"
        n="1"
        for ytId in "${videoArr[@]}"; do
            printOutput "4" "Verifying file ID [${ytId}] against database [Item ${n} of ${#videoArr[@]}]"
            if ! compareFileIdToDb "${ytId}"; then
                printOutput "5" "Skipping ID [${ytId}]"
            fi
            (( n++ ))
        done
    done

    # We're done with indexing our sources, now we need to process any queued videos
    # Check for any previously failed downloands, and re-queue them
    readarray -t failQueue < <(sqDb "SELECT DISTINCT ID FROM source_videos WHERE VID_STATUS = 'failed' OR AUD_STATUS = 'failed';")
    if [[ "${#failQueue[@]}" -ge "1" ]]; then
        printOutput "3" "Found [${#failQueue[@]}] previously failed items, marking for download to be re-attempted"
        for ytId in "${failQueue[@]}"; do
            vidFail="$(sqDb "SELECT VID_STATUS FROM source_videos WHERE ID = '${ytId}';")"
            audFail="$(sqDb "SELECT AUD_STATUS FROM source_videos WHERE ID = '${ytId}';")"
            if [[ "${vidFail}" == "failed" ]]; then
                if sqDb "UPDATE source_videos SET VID_STATUS = 'queued' WHERE ID = '${ytId}';"; then
                    printOutput "5" "Requeueing failed video download for file ID [${ytId}] succeeded"
                else
                    printOutput "1" "Requeueing failed video download for file ID [${ytId}] failed"
                fi
            fi
            if [[ "${audFail}" == "failed" ]]; then
                if sqDb "UPDATE source_videos SET AUD_STATUS = 'queued' WHERE ID = '${ytId}';"; then
                    printOutput "5" "Requeueing failed audio download for file ID [${ytId}] succeeded"
                else
                    printOutput "1" "Requeueing failed audio download for file ID [${ytId}] failed"
                fi
            fi
        done
    fi

    # Start by checking to see if there are any videos in the queue
    # I have no evidence randomizing the queue helps with blocking/throttling, but it couldn't hurt?
    readarray -t vidQueue < <(sqDb "SELECT ID from source_videos WHERE VID_STATUS = 'queued' OR AUD_STATUS = 'queued' ORDER BY RANDOM();")
    
    if [[ "${#vidQueue[@]}" -ge "1" ]]; then
        printOutput "3" "############# Processing queued downloads #############"
        # Let's get to work
        itemCountVid="$(sqDb "SELECT COUNT(1) from source_videos WHERE (VID_STATUS = 'queued' AND AUD_STATUS != 'queued');")"
        itemCountAud="$(sqDb "SELECT COUNT(1) from source_videos WHERE (VID_STATUS != 'queued' AND AUD_STATUS = 'queued');")"
        itemCountBoth="$(sqDb "SELECT COUNT(1) from source_videos WHERE (VID_STATUS = 'queued' AND AUD_STATUS = 'queued');")"
        # Get a list of items that are video only
        itemCount="$(( itemCountVid + itemCountAud + itemCountBoth + itemCountBoth ))"
        printOutput "3" "Processing ${itemCount} items in download queue"
        n="1"
        for ytId in "${vidQueue[@]}"; do
            printOutput "4" "Processing file ID [${ytId}]"
            
            # Assign titles
            assignTitle "${ytId}"
            # Clean out our tmp dir, as if we previously failed due to out of space, we don't want everything else after to fail
            rm -rf "${tmpDir:?}/"*

            # Get the video title
            vidTitle="$(sqDb "SELECT TITLE FROM source_videos WHERE ID = '${ytId}';")"
            # Validate it
            if [[ -z "${vidTitle}" ]]; then
                printOutput "1" "Video title lookup for file ID [${ytId}] returned blank result -- Skipping [Item ${n} of ${itemCount}]"
                (( n++ ))
                continue
            fi

            # Get the cleaned video title
            vidTitleClean="$(sqDb "SELECT TITLE_CLEAN FROM source_videos WHERE ID = '${ytId}';")"
            # Validate it
            if [[ -z "${vidTitleClean}" ]]; then
                printOutput "1" "Clean video title lookup for file ID [${ytId}] returned blank result -- Skipping [Item ${n} of ${itemCount}]"
                (( n++ ))
                continue
            fi

            # Get our channel ID
            channelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${ytId}';")"
            # Validate it
            if ! [[ "${channelId}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
                printOutput "1" "Channel ID lookup for file ID [${ytId}] returned invalid result [${channelId}] -- Skipping [Item ${n} of ${itemCount}]"
                (( n++ ))
                continue
            fi

            # Get our channel name
            channelName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${channelId}';")"
            # Validate it
            if [[ -z "${channelName}" ]]; then
                printOutput "1" "Channel name lookup for channel ID [${channelId}] returned blank result -- Skipping [Item ${n} of ${itemCount}]"
                (( n++ ))
                continue
            fi

            # Get our sanitized channel name
            channelNameClean="$(sqDb "SELECT NAME_CLEAN FROM source_channels WHERE ID = '${channelId}';")"
            # Validate it
            if [[ -z "${channelNameClean}" ]]; then
                printOutput "1" "Sanitized channel name lookup for channel ID [${channelId}] returned blank result -- Skipping [Item ${n} of ${itemCount}]"
                (( n++ ))
                continue
            fi

            # Get our channel output directory
            chanDir="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${channelId}';")"
            # Validate it
            if [[ -z "${chanDir}" ]]; then
                badExit "206" "Unable to look up channel video directory for channel ID [${channelId}]"
            fi

            # Get our year
            vidYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${ytId}';")"
            # Validate it
            if ! [[ "${vidYear}" =~ ^[0-9][0-9][0-9][0-9]$ ]]; then
                printOutput "1" "Year lookup for file ID [${ytId}] returned invalid result [${vidYear}] -- Skipping [Item ${n} of ${itemCount}]"
                (( n++ ))
                continue
            fi

            # Get our video output format
            videoOutput="$(sqDb "SELECT VID_FORMAT FROM source_videos WHERE ID = '${ytId}';")"
            # Validate it
            if [[ -z "${videoOutput}" ]]; then
                badExit "207" "Unable to look up video output format for file ID [${ytId}]"
            fi

            # Get our audio output format
            audioOutput="$(sqDb "SELECT AUD_FORMAT FROM source_videos WHERE ID = '${ytId}';")"
            # Validate it
            if [[ -z "${audioOutput}" ]]; then
                badExit "208" "Unable to look up audio output format for file ID [${ytId}]"
            fi

            # Get our watched setting
            markWatched="$(sqDb "SELECT WATCHED FROM source_videos WHERE ID = '${ytId}';")"
            # Validate it
            if [[ -z "${markWatched}" ]]; then
                badExit "209" "Unable to look up watch option for file ID [${ytId}]"
            fi

            # Get our video status
            vidStatus="$(sqDb "SELECT VID_STATUS FROM source_videos WHERE ID = '${ytId}';")"
            # Validate it
            if [[ -z "${vidStatus}" ]]; then
                badExit "210" "Unable to look up video status for file ID [${ytId}]"
            fi

            # Get our audio status
            audStatus="$(sqDb "SELECT AUD_STATUS FROM source_videos WHERE ID = '${ytId}';")"
            # Validate it
            if [[ -z "${audStatus}" ]]; then
                badExit "211" "Unable to look up audio status for file ID [${ytId}]"
            fi

            # Get the order of all items in that season
            readarray -t seasonOrder < <(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${channelId}' AND YEAR = ${vidYear} ORDER BY TIMESTAMP ASC;")

            # Iterate through the season until our ID matches, so we know our position
            vidIndex="1"
            for z in "${seasonOrder[@]}"; do
                if [[ "${z}" == "${ytId}" ]]; then
                    break
                fi
                (( vidIndex++ ))
            done

            # Log that position in the database
            if ! sqDb "UPDATE source_videos SET EP_INDEX = '${vidIndex}', UPDATED = '$(date +%s)' WHERE ID = '${ytId}';"; then
                badExit "212" "Unable to update episode index to [S${vidYear}E${vidIndex}] for file ID [${ytId}]"
            fi

            # Verify that everything in that season is in the correct order, if there is more than one entry for the EP_INDEX we just set
            dbReply="$(sqDb "SELECT COUNT(1) FROM source_videos WHERE CHANNEL_ID = '${channelId}' AND YEAR = ${vidYear} AND EP_INDEX = '${vidIndex}';")"
            if [[ "${dbReply}" -ge "2" ]]; then
                # Go ahead and anticipate that our new episode is unwatched (watchedArr will fix this if it's set in config)
                reindexArr["_${ytId}"]="unwatched"
                orderNum="1"
                while read -r z; do
                    # z is the ytId
                    dbNum="$(sqDb "SELECT EP_INDEX FROM source_videos WHERE ID = '${z}';")"
                    if [[ -z "${dbNum}" ]]; then
                        dbNum="1"
                    fi
                    if [[ "${dbNum}" -ne "${orderNum}" ]]; then
                        # UPDATE IT
                        printOutput "2" "Correcting ID [${z}] to position [S${vidYear}E$(printf '%03d' "${orderNum}")]"
                        # Get the clean title of the file we need to move
                        vidTitleCleanMove="$(sqDb "SELECT TITLE_CLEAN FROM source_videos WHERE ID = '${z}';")"
                        # Validate it
                        if [[ -z "${vidTitleCleanMove}" ]]; then
                            printOutput "1" "Clean video title lookup for file ID [${z}] returned blank result -- Skipping [Item ${n} of ${itemCount}]"
                            (( n++ ))
                            continue
                        fi

                        # We need the season's rating key
                        seasonRatingKey="$(sqDb "SELECT RATING_KEY FROM video_rating_key_by_season WHERE CHANNEL_ID = '${channelId}' AND YEAR = ${vidYear};")"
                        if ! validateInterger "${seasonRatingKey}"; then
                            printOutput "1" "Artist rating key [${seasonRatingKey}] failed to validate -- Unable to continue"
                            return 1
                        fi
                        inArray="0"
                        for zz in "${reindexSeason[@]}"; do
                            if [[ "${zz}" == "${seasonRatingKey}" ]]; then
                                inArray="1"
                                break
                            fi
                        done
                        if [[ "${inArray}" -eq "0" ]]; then
                            reindexSeason+=("${seasonRatingKey}")
                        fi
                        # Get the watch status for the season
                        callCurl "${plexAdd}/library/metadata/${seasonRatingKey}/children?X-Plex-Token=${plexToken}"
                        # For each rating key in this season
                        while read -r zz; do
                            # Media item rating key is zz
                            fId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${zz}\" ) .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                            fId="${fId%\]\.*}"
                            fId="${fId##*\[}"
                            watchStatus="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${zz}\" ) .\"+@viewOffset\"" <<<"${curlOutput}")"
                            if [[ "${watchStatus}" =~ ^[0-9]+$ ]]; then
                                # It's in progress
                                reindexArr["_${fId}"]="${watchStatus}"
                            else
                                # Not in progress, we need to check the view count
                                watchStatus="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${zz}\" ) .\"+@viewCount\"" <<<"${curlOutput}")"
                                if [[ "${watchStatus}" == "null" ]]; then
                                    # It's unwatched
                                    reindexArr["_${fId}"]="unwatched"
                                else
                                    # It's watched
                                    reindexArr["_${fId}"]="watched"
                                fi
                            fi
                        done < <(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")

                        # Move it
                        if ! mv "${videoOutputDir}/${chanDir}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${dbNum}") - ${vidTitleCleanMove} [${z}].mp4" "${videoOutputDir}/${chanDir}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${orderNum}") - ${vidTitleCleanMove} [${z}].mp4"; then
                            badExit "213" "Unable to re-index [${channelNameClean} - S${vidYear}E$(printf '%03d' "${dbNum}")] to [${channelNameClean} - S${vidYear}E$(printf '%03d' "${orderNum}")]"
                        fi
                        
                        # Move the thumbnail
                        if ! mv "${videoOutputDir}/${chanDir}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${dbNum}") - ${vidTitleCleanMove} [${z}].jpg" "${videoOutputDir}/${chanDir}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${orderNum}") - ${vidTitleCleanMove} [${z}].jpg"; then
                            printOutput "1" "Unable to re-index thumbail for [${channelNameClean} - S${vidYear}E$(printf '%03d' "${dbNum}")] to [${channelNameClean} - S${vidYear}E$(printf '%03d' "${orderNum}")]"
                        fi

                        # Correct the database entry
                        if ! sqDb "UPDATE source_videos SET EP_INDEX = '${orderNum}', UPDATED = '$(date +%s)' WHERE ID = '${z}';"; then
                            badExit "214" "Unable to update episode index to [S${vidYear}E${orderNum}] for file ID [${z}]"
                        fi
                    fi
                    (( orderNum++ ))
                done < <(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${channelId}' AND YEAR = ${vidYear} ORDER BY TIMESTAMP ASC;")
            fi

            if ! [[ "${videoOutput}" == "none" ]] && ! [[ "${vidStatus}" == "downloaded" ]] ; then
                # Add the series folder, if required
                if ! [[ -d "${videoOutputDir}/${chanDir}" ]]; then
                    if ! mkdir -p "${videoOutputDir}/${chanDir}"; then
                        badExit "215" "Unable to create channel folder [${videoOutputDir}/${chanDir}]"
                    else
                        flagNewVideoDir="1"
                    fi
                else
                    flagNewVideoDir="0"
                fi

                # Check for channel image(s)
                if ! [[ -e "${videoOutputDir}/${chanDir}/show.jpg" ]]; then
                    makeShowImage "${chanDir}" "${channelId}"
                fi

                # Create a season thumbnail
                makeSeasonImage "${chanDir}" "${vidYear}" "${channelId}"

                # Get the video format
                videoOutput="$(sqDb "SELECT VID_FORMAT FROM source_videos WHERE ID = '${ytId}';")"
                # This is already validated, so we just need to check and make sure it's not blank
                if [[ -z "${videoOutput}" ]]; then
                    printOutput "1" "Invalid video format returned for file ID [${ytId}] -- Skipping [Item ${n} of ${itemCount}]"
                    (( n++ ))
                    continue
                fi

                # Get the sponsorblock options
                sponsorblockOpts="$(sqDb "SELECT SB_OPTIONS FROM source_videos WHERE ID = '${ytId}';")"
                # This is already validated, so we just need to check and make sure it's not blank
                if [[ -z "${sponsorblockOpts}" ]]; then
                    printOutput "1" "Invalid sponsorblock option returned for file ID [${ytId}] -- Skipping [Item ${n} of ${itemCount}]"
                    (( n++ ))
                    continue
                fi

                # We've validated where we should download it to. So... download it
                # Unset any old leftover options
                unset dlpOpts dlpOutput dlpError
                # Set our options
                if ! [[ "${videoOutput}" == "original" ]]; then
                    dlpOpts+=("-S res:${videoOutput}")
                fi
                if ! [[ "${sponsorblockOpts}" == "mark" ]]; then
                    dlpOpts+=("--sponsorblock-mark all")
                elif ! [[ "${sponsorblockOpts}" == "remove" ]]; then
                    dlpOpts+=("--sponsorblock-remove all")
                fi
                dlpOpts+=("--no-progress" "--retry-sleep 10" "--merge-output-format mp4" "--write-thumbnail" "--convert-thumbnails jpg" "--embed-subs" "--embed-metadata" "--embed-chapters" "--sleep-requests 1.25")
                if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
                    startTime="$(($(date +%s%N)/1000000))"
                    while read -r z; do
                        dlpOutput+=("${z}")
                        if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                            dlpError="${z}"
                        fi
                    done < <(yt-dlp -vU ${dlpOpts[*]} --cookies "${cookieFile}" -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                         # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                    endTime="$(($(date +%s%N)/1000000))"
                else
                    startTime="$(($(date +%s%N)/1000000))"
                    while read -r z; do
                        dlpOutput+=("${z}")
                        if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                            dlpError="${z}"
                        fi
                    done < <(yt-dlp -vU ${dlpOpts[*]} -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                         # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                    endTime="$(($(date +%s%N)/1000000))"
                fi

                # Retry #1 if throttled
                if [[ "${dlpError}" == "ERROR: unable to download video data: HTTP Error 403: Forbidden" ]]; then
                    printOutput "2" "IP throttling detected, taking a 2 minute break and then trying again [Retry 1]"
                    sleep 120
                    unset dlpOutput dlpError
                    if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
                        startTime="$(($(date +%s%N)/1000000))"
                        while read -r z; do
                            dlpOutput+=("${z}")
                            if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                                dlpError="${z}"
                            fi
                        done < <(yt-dlp -vU ${dlpOpts[*]} --cookies "${cookieFile}" -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                             # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                        endTime="$(($(date +%s%N)/1000000))"
                    else
                        while read -r z; do
                        startTime="$(($(date +%s%N)/1000000))"
                            dlpOutput+=("${z}")
                            if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                                dlpError="${z}"
                            fi
                        done < <(yt-dlp -vU ${dlpOpts[*]} -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                             # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                        endTime="$(($(date +%s%N)/1000000))"
                    fi
                fi
                # Retry #2 if throttled
                if [[ "${dlpError}" == "ERROR: unable to download video data: HTTP Error 403: Forbidden" ]]; then
                    printOutput "2" "IP throttling detected, taking a 2 minute break and then trying again [Retry 2]"
                    sleep 120
                    unset dlpOutput dlpError
                    if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
                        startTime="$(($(date +%s%N)/1000000))"
                        while read -r z; do
                            dlpOutput+=("${z}")
                            if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                                dlpError="${z}"
                            fi
                        done < <(yt-dlp -vU ${dlpOpts[*]} --cookies "${cookieFile}" -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                             # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                        endTime="$(($(date +%s%N)/1000000))"
                    else
                        startTime="$(($(date +%s%N)/1000000))"
                        while read -r z; do
                            dlpOutput+=("${z}")
                            if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                                dlpError="${z}"
                            fi
                        done < <(yt-dlp -vU ${dlpOpts[*]} -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                             # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                        endTime="$(($(date +%s%N)/1000000))"
                    fi
                else
                    throttleDlp
                fi
                # Make sure the video downloaded
                if ! [[ -e "${tmpDir}/${ytId}.mp4" ]]; then
                    printOutput "1" "Download of video file ID [${ytId}] failed"
                    if [[ -n "${dlpError}" ]]; then
                        printOutput "1" "Found yt-dlp error message [${dlpError}]"
                    fi
                    printOutput "1" "=========== Begin yt-dlp log ==========="
                    for z in "${dlpOutput[@]}"; do
                        printOutput "1" "${z}"
                    done
                    printOutput "1" "============ End yt-dlp log ============"
                    printOutput "1" "Skipping file ID [${ytId}] [Item ${n} of ${itemCount}]"
                    if ! sqDb "UPDATE source_videos SET VID_STATUS = 'failed', UPDATED = '$(date +%s)' WHERE ID = '${ytId}';"; then
                        badExit "216" "Unable to update status to [failed] for file ID [${ytId}]"
                    fi
                    (( n++ ))
                    continue
                else
                    printOutput "4" "Download complete [$(timeDiff "${startTime}" "${endTime}")]"
                fi
                # Make sure the thumbnail was written
                if ! [[ -e "${tmpDir}/${ytId}.jpg" ]]; then
                    printOutput "1" "Download of thumbnail for video file ID [${ytId}] failed"
                    printOutput "1" "=========== Begin yt-dlp log ==========="
                    for z in "${dlpOutput[@]}"; do
                        printOutput "1" "${z}"
                    done
                    printOutput "1" "============ End yt-dlp log ============"
                    printOutput "1" "Skipping file ID [${ytId}] [Item ${n} of ${itemCount}]"
                    if ! sqDb "UPDATE source_videos SET VID_STATUS = 'failed', UPDATED = '$(date +%s)' WHERE ID = '${ytId}';"; then
                        badExit "217" "Unable to update status to [failed] for file ID [${ytId}]"
                    fi
                    (( n++ ))
                    continue
                fi

                # Make sure we can move the video from tmp to destination
                if ! mv "${tmpDir}/${ytId}.mp4" "${videoOutputDir}/${chanDir}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4"; then
                    printOutput "1" "Failed to move file ID [${ytId}] from tmp dir [${tmpDir}] to destination [${chanDir}/Season ${vidYear}] -- Skipping"
                    (( n++ ))
                    continue
                else
                    # Make sure we can move the thumbnail from tmp to destination
                    if ! mv "${tmpDir}/${ytId}.jpg" "${videoOutputDir}/${chanDir}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"; then
                        printOutput "1" "Failed to move thumbnail for file ID [${ytId}] from tmp dir [${tmpDir}] to destination [${chanDir}/Season ${vidYear}] -- Skipping"
                        (( n++ ))
                        continue
                    fi
                fi

                if [[ -e "${videoOutputDir}/${chanDir}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4" ]]; then
                    printOutput "3" "Downloaded video [${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}] [Item ${n} of ${itemCount}]"
                    msgArr+=("Downloaded video [${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}]")
                    if [[ "${flagNewVideoDir}" -eq "1" ]]; then
                        newVideoDir+=("${channelId}")
                    fi
                    (( videoCount++ ))
                    if ! sqDb "UPDATE source_videos SET VID_STATUS = 'downloaded', UPDATED = '$(date +%s)' WHERE ID = '${ytId}';"; then
                        badExit "218" "Unable to update status to [downloaded] for file ID [${ytId}]"
                    fi
                else
                    printOutput "1" "Failed to download [${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}]"
                    if ! sqDb "UPDATE source_videos SET VID_STATUS = 'failed', UPDATED = '$(date +%s)' WHERE ID = '${ytId}';"; then
                        badExit "219" "Unable to update status to [failed] for file ID [${ytId}]"
                    fi
                fi
                (( n++ ))

                # If we should mark a video as watched, add it to an array to deal with later
                if [[ "${markWatched}" == "true" ]]; then
                    watchedArr+=("${ytId}")
                fi
            fi

            if ! [[ "${audioOutput}" == "none" ]] && ! [[ "${audStatus}" == "downloaded" ]] ; then
                # Add the artist folder
                if ! [[ -d "${audioOutputDir}/${chanDir}" ]]; then
                    if ! mkdir -p "${audioOutputDir}/${chanDir}"; then
                        badExit "220" "Unable to create artist folder [${audioOutputDir}/${chanDir}]"
                    else
                        flagNewAudioDir="1"
                    fi
                else
                    flagNewAudioDir="0"
                fi

                # Add the album folder
                if ! [[ -d "${audioOutputDir}/${chanDir}/${vidTitleClean}" ]]; then
                    if ! mkdir -p "${audioOutputDir}/${chanDir}/${vidTitleClean}" ; then
                        badExit "221" "Unable to create season folder [${audioOutputDir}/${chanDir}/${vidTitleClean}]"
                    fi
                fi

                # Get the audio format
                audioOutput="$(sqDb "SELECT AUD_FORMAT FROM source_videos WHERE ID = '${ytId}';")"
                # This is already validated, so we just need to check and make sure it's not blank
                if [[ -z "${audioOutput}" ]]; then
                    printOutput "1" "Invalid audio format returned for file ID [${ytId}] -- Skipping [Item ${n} of ${itemCount}]"
                    (( n++ ))
                    continue
                fi

                # Get the sponsorblock options
                sponsorblockOpts="$(sqDb "SELECT SB_OPTIONS FROM source_videos WHERE ID = '${ytId}';")"
                # This is already validated, so we just need to check and make sure it's not blank
                if [[ -z "${sponsorblockOpts}" ]]; then
                    printOutput "1" "Invalid sponsorblock option returned for file ID [${ytId}] -- Skipping [Item ${n} of ${itemCount}]"
                    (( n++ ))
                    continue
                fi

                # We've validated where we should download it to. So... download it
                # Unset any old leftover options
                unset dlpOpts dlpOutput dlpError
                # Set our options
                dlpOpts+=("-x" "--audio-format ${audioOutput}")
                dlpOpts+=("--no-progress" "--retry-sleep 10" "--write-thumbnail" "--convert-thumbnails jpg" "--embed-metadata" "--embed-chapters")
                if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
                    startTime="$(($(date +%s%N)/1000000))"
                    while read -r z; do
                        dlpOutput+=("${z}")
                        if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                            dlpError="${z}"
                        fi
                    done < <(yt-dlp ${dlpOpts[*]} --cookies "${cookieFile}" -o "${tmpDir}/${ytId}.${audioOutput}" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                    # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                        endTime="$(($(date +%s%N)/1000000))"
                else
                    startTime="$(($(date +%s%N)/1000000))"
                    while read -r z; do
                        dlpOutput+=("${z}")
                        if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                            dlpError="${z}"
                        fi
                    done < <(yt-dlp ${dlpOpts[*]} -o "${tmpDir}/${ytId}.${audioOutput}" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                    # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                        endTime="$(($(date +%s%N)/1000000))"
                fi

                if [[ "${dlpError}" == "ERROR: unable to download video data: HTTP Error 403: Forbidden" ]]; then
                    printOutput "2" "IP throttling detected, taking a 2 minute break and then trying again [Retry 1]"
                    sleep 120
                    unset dlpOpts dlpOutput dlpError
                    # Set our options
                    if ! [[ "${videoOutput}" == "original" ]]; then
                        dlpOpts+=("-S res:${videoOutput}")
                    fi
                    if ! [[ "${sponsorblockOpts}" == "mark" ]]; then
                        dlpOpts+=("--sponsorblock-mark all")
                    elif ! [[ "${sponsorblockOpts}" == "remove" ]]; then
                        dlpOpts+=("--sponsorblock-remove all")
                    fi
                    dlpOpts+=("--no-progress" "--retry-sleep 10" "--merge-output-format mp4" "--write-thumbnail" "--convert-thumbnails jpg" "--embed-subs" "--embed-metadata" "--embed-chapters")
                    if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
                        startTime="$(($(date +%s%N)/1000000))"
                        while read -r z; do
                            dlpOutput+=("${z}")
                            if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                                dlpError="${z}"
                            fi
                        done < <(yt-dlp ${dlpOpts[*]} --cookies "${cookieFile}" -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                        # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                        endTime="$(($(date +%s%N)/1000000))"
                    else
                        startTime="$(($(date +%s%N)/1000000))"
                        while read -r z; do
                            dlpOutput+=("${z}")
                            if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                                dlpError="${z}"
                            fi
                        done < <(yt-dlp ${dlpOpts[*]} -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                        # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                        endTime="$(($(date +%s%N)/1000000))"
                    fi
                fi
                if [[ "${dlpError}" == "ERROR: unable to download video data: HTTP Error 403: Forbidden" ]]; then
                    printOutput "2" "IP throttling detected, taking a 2 minute break and then trying again [Retry 2]"
                    sleep 120
                    unset dlpOpts dlpOutput dlpError
                    # Set our options
                    if ! [[ "${videoOutput}" == "original" ]]; then
                        dlpOpts+=("-S res:${videoOutput}")
                    fi
                    if ! [[ "${sponsorblockOpts}" == "mark" ]]; then
                        dlpOpts+=("--sponsorblock-mark all")
                    elif ! [[ "${sponsorblockOpts}" == "remove" ]]; then
                        dlpOpts+=("--sponsorblock-remove all")
                    fi
                    dlpOpts+=("--no-progress" "--retry-sleep 10" "--merge-output-format mp4" "--write-thumbnail" "--convert-thumbnails jpg" "--embed-subs" "--embed-metadata" "--embed-chapters")
                    if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
                        startTime="$(($(date +%s%N)/1000000))"
                        while read -r z; do
                            dlpOutput+=("${z}")
                            if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                                dlpError="${z}"
                            fi
                        done < <(yt-dlp ${dlpOpts[*]} --cookies "${cookieFile}" -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                        # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                        endTime="$(($(date +%s%N)/1000000))"
                    else
                        startTime="$(($(date +%s%N)/1000000))"
                        while read -r z; do
                            dlpOutput+=("${z}")
                            if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                                dlpError="${z}"
                            fi
                        done < <(yt-dlp ${dlpOpts[*]} -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                        # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                        endTime="$(($(date +%s%N)/1000000))"
                    fi
                else
                    throttleDlp
                fi

                # Make sure the audio downloaded
                if ! [[ -e "${tmpDir}/${ytId}.${audioOutput}" ]]; then
                    printOutput "1" "Download of audio file ID [${ytId}] failed"
                    if [[ -n "${dlpError}" ]]; then
                        printOutput "1" "Found yt-dlp error message [${dlpError}]"
                    fi
                    printOutput "1" "=========== Begin yt-dlp log ==========="
                    for z in "${dlpOutput[@]}"; do
                        printOutput "1" "${z}"
                        if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                            dlpError="${z}"
                        fi
                    done
                    printOutput "1" "============ End yt-dlp log ============"
                    printOutput "1" "Skipping file ID [${ytId}] [Item ${n} of ${itemCount}]"
                    if ! sqDb "UPDATE source_videos SET AUD_STATUS = 'failed', UPDATED = '$(date +%s)' WHERE ID = '${ytId}';"; then
                        badExit "222" "Unable to update status to [failed] for file ID [${ytId}]"
                    fi
                    (( n++ ))
                    continue
                else
                    printOutput "4" "Download complete [$(timeDiff "${startTime}" "${endTime}")]"
                fi
                # Make sure the thumbnail was written
                if ! [[ -e "${tmpDir}/${ytId}.${audioOutput}.jpg" ]]; then
                    printOutput "1" "Download of thumbnail for audio file ID [${ytId}] failed"
                    printOutput "1" "=========== Begin yt-dlp log ==========="
                    for z in "${dlpOutput[@]}"; do
                        printOutput "1" "${z}"
                    done
                    printOutput "1" "============ End yt-dlp log ============"
                    printOutput "1" "Skipping file ID [${ytId}] [Item ${n} of ${itemCount}]"
                    if ! sqDb "UPDATE source_videos SET AUD_STATUS = 'failed', UPDATED = '$(date +%s)' WHERE ID = '${ytId}';"; then
                        badExit "223" "Unable to update status to [failed] for file ID [${ytId}]"
                    fi
                    (( n++ ))
                    continue
                fi

                # Make sure we can move the audio from tmp to destination
                if ! mv "${tmpDir}/${ytId}.${audioOutput}" "${audioOutputDir}/${chanDir}/${vidTitleClean}/01 - ${vidTitleClean} [${ytId}].${audioOutput}"; then
                    printOutput "1" "Failed to move file ID [${ytId}] from tmp dir [${tmpDir}] to destination [${chanDir}/${vidTitleClean}] -- Skipping [Item ${n} of ${itemCount}]"
                    continue
                else
                    # Make sure we can move the thumbnail from tmp to destination
                    if ! mv "${tmpDir}/${ytId}.${audioOutput}.jpg" "${audioOutputDir}/${chanDir}/${vidTitleClean}/cover.jpg"; then
                        printOutput "1" "Failed to move thumbail for file ID [${ytId}] from tmp dir [${tmpDir}] to destination [${chanDir}/${vidTitleClean}] -- Skipping [Item ${n} of ${itemCount}]"
                        (( n++ ))
                        continue
                    fi
                fi

                if [[ -e "${audioOutputDir}/${chanDir}/${vidTitleClean}/01 - ${vidTitleClean} [${ytId}].${audioOutput}" ]]; then
                    printOutput "3" "Downloaded audio [${channelName} - ${vidTitle}] [Item ${n} of ${itemCount}]"
                    msgArr+=("Downloaded audio [${channelName} - ${vidTitle}]")
                    if [[ "${flagNewAudioDir}" -eq "1" ]]; then
                        newAudioDir+=("${channelId}")
                    fi
                    albumsToProcess+=("${ytId}")
                    (( audioCount++ ))

                    if ! sqDb "UPDATE source_videos SET AUD_STATUS = 'downloaded', UPDATED = '$(date +%s)' WHERE ID = '${ytId}';"; then
                        badExit "224" "Unable to update status to [downloaded] for file ID [${ytId}]"
                    fi
                else
                    printOutput "1" "Failed to download audio [${channelName} - ${vidTitle}]"
                    if ! sqDb "UPDATE source_videos SET AUD_STATUS = 'failed', UPDATED = '$(date +%s)' WHERE ID = '${ytId}';"; then
                        badExit "225" "Unable to update status to [failed] for file ID [${ytId}]"
                    fi
                fi
                (( n++ ))
            fi
        done
        if [[ -n "${videoCount}" && "${videoCount}" -gt "0" ]]; then
            printOutput "4" "Downloaded [${videoCount}] video files"
        fi
        if [[ -n "${audioCount}" && "${audioCount}" -gt "0" ]]; then
            printOutput "4" "Downloaded [${audioCount}] audio files"
        fi
    fi
fi

if [[ "$(( videoCount + audioCount ))" -ge "1" ]]; then
    printOutput "3" "############ Beginning post-download tasks ############"
fi

# Scan library for changes
if [[ "${videoCount}" -ne "0" ]]; then
    # Scan the video library for changes
    refreshLibrary "${videoLibraryId}"
    # Rule of thumb: Wait 2 seconds per video, minimum of 30 seconds, maximum of 10 minutes
    scanWait="$(( videoCount * 2 ))"
    if [[ "${scanWait}" -lt "30" ]]; then
        scanWait="30"
    elif [[ "${scanWait}" -gt "600" ]]; then
        scanWait="600"
    fi
    printOutput "4" "Waiting [${scanWait}] seconds for Plex Media Scanner to update video file library"
    sleep "${scanWait}"
fi
if [[ "${audioCount}" -ne "0" ]]; then
    # Scan the audio library for changes
    refreshLibrary "${audioLibraryId}"
    # Rule of thumb: Wait 2 seconds per audio, minimum of 30 seconds, maximum of 10 minutes
    scanWait="$(( audioCount * 2 ))"
    if [[ "${scanWait}" -lt "30" ]]; then
        scanWait="30"
    elif [[ "${scanWait}" -gt "600" ]]; then
        scanWait="600"
    fi
    printOutput "2" "Waiting [${scanWait}] seconds for Plex Media Scanner to update audio file library"
    sleep "${scanWait}"
fi

# Fix metadata for any newly created channels
if [[ "$(( ${#newVideoDir[@]} + ${#newAudioDir[@]} + ${#albumsToProcess[@]} ))" -ge "1" ]]; then
    printOutput "3" "############## Correcting media metadata ##############"
fi
# This is for video
for i in "${newVideoDir[@]}"; do
    # i is channel ID
    updateShowRatingKey "${i}"
    # Now the rating key is stored in the database, retrieve it
    showRatingKey="$(sqDb "SELECT RATING_KEY FROM video_rating_key_by_channel WHERE CHANNEL_ID = '${i}';")"
    if ! validateInterger "${showRatingKey}"; then
        printOutput "1" "Variable showRatingKey [${showRatingKey}] failed to validate -- Unable to continue"
        return 1
    fi

    if ! setSeriesMetadata "${showRatingKey}"; then
        printOutput "1" "Failed to update metadata for series rating key [${ratingKey}]"
    fi
done
# This is for audio
for i in "${newAudioDir[@]}"; do
    updateAristRatingKey "${i}"
    # Now the rating key is stored in the database, retrieve it
    showRatingKey="$(sqDb "SELECT RATING_KEY FROM audio_rating_key_by_channel WHERE CHANNEL_ID = '${i}';")"
    if ! validateInterger "${showRatingKey}"; then
        printOutput "1" "Variable showRatingKey [${showRatingKey}] failed to validate -- Unable to continue"
        return 1
    fi

    if ! setArtistMetadata "${showRatingKey}"; then
        printOutput "1" "Failed to update metadata for artist rating key [${ratingKey}]"
    fi
done

# This will update metadata for any newly downloaded albums
for i in "${albumsToProcess[@]}"; do
    printOutput "4" "Updating audio metadata for file ID [${i}]"
    # Goal - Get the rating key for the album -- ${albumRatingKey}

    # First, get the rating key for the artist
    # Maybe we already know it?
    artistChanId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${i}';")"
    if [[ -z "${artistChanId}" ]]; then
        badExit "226" "Unable to retrieve artist ID for file ID [${i}] -- Possible database corruption"
    fi

    # Now check and see if we have an artist rating key for this channel ID
    artistRatingKey="$(sqDb "SELECT RATING_KEY FROM audio_rating_key_by_channel WHERE CHANNEL_ID = '${artistChanId}';")"
    if [[ -z "${artistChanId}" ]]; then
        # We don't know it. This technically shouldn't be possible, but in case we ever end up here, let's add a lookup for it.
        updateAristRatingKey "${artistChanId}"

        # Now look it up again.
        artistRatingKey="$(sqDb "SELECT RATING_KEY FROM audio_rating_key_by_channel WHERE CHANNEL_ID = '${artistChanId}';")"
        if [[ -z "${artistChanId}" ]]; then
            # If we still can't find it, we should panic for some reason
            printOutput "1" "Unable to determine artist ID for channel ID [${artistChanId}] -- This shouldn't be possible. Skipping file ID [${i}]"
            continue
        fi
    fi
    if ! validateInterger "${artistRatingKey}"; then
        printOutput "1" "Variable artistRatingKey [${artistRatingKey}] failed to validate -- Unable to continue"
        return 1
    fi

    # Then, get the rating key for the album and track
    # Maybe we already know it?
    albumRatingKey="$(sqDb "SELECT RATING_KEY FROM audio_rating_key_by_album WHERE ID = '${i}';")"
    if [[ -z "${albumRatingKey}" ]]; then
        # Get a list of the albums for that year, for that artist
        callCurl "${plexAdd}/library/metadata/${artistRatingKey}/children?X-Plex-Token=${plexToken}"
        albumYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${i}';")"
        if ! validateInterger "${albumYear}"; then
            printOutput "1" "Variable albumYear [${albumYear}] failed to validate -- Unable to continue"
            return 1
        fi
        
        readarray -t artistAlbums < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@year\" == \"${albumYear}\" ) .\"+@ratingKey\"" <<<"${curlOutput}")

        if [[ "${#artistAlbums[@]}" -eq "0" ]]; then
            printOutput "1" "No matching albums in year [${albumYear}] found for artist rating key [${artistRatingKey}] with channel ID [${artistChanId}] (Has Plex not yet picked up the media file?) -- Skipping album metadata update"
        else
            # For each album we've found (We have each album's rating key in ${artistAlbums[@]})
            # Check the album contents for the file ID that matches
            for z in "${artistAlbums[@]}"; do
                # Get the file ID for that album
                callCurl "${plexAdd}/library/metadata/${z}/children?X-Plex-Token=${plexToken}"
                readarray -t artistTracks < <(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | .Media.Part.\"+@file\"" <<<"${curlOutput}")
                # We read this into an array in case we have multiple matches
                if [[ "${#artistTracks[@]}" -ne "1" ]]; then
                    printOutput "2" "Multiple tracks [${artistTracks[*]}] detected for album rating key [${z}], artist rating key [${artistRatingKey}], of file ID [${i}], channel ID [${artistChanId}]"
                fi
                for artistTrack in "${artistTracks[@]}"; do
                    # Now extract the file ID
                    trackId="${artistTrack%\].*}"
                    trackId="${trackId##*\[}"
                    # Now compare it to the file ID we're working with
                    if [[ "${trackId}" == "${i}" ]]; then
                        # We've found it! Extract the rating key.
                        trackRatingKey="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")"
                        # Store the info we've retrieved
                        # We already know that we don't know the album rating key, nor the track rating key
                        # We do know the artist rating key

                        # Insert the album rating key
                        if sqDb "INSERT INTO audio_rating_key_by_album (RATING_KEY, ID, UPDATED) VALUES (${z}, '${i}', $(date +%s));"; then
                            printOutput "5" "Added album rating key [${z}] to database"
                        else
                            badExit "227" "Adding album rating key [${z}] to database failed"
                        fi

                        # Insert the track rating key
                        if sqDb "INSERT INTO audio_rating_key_by_item (RATING_KEY, ID, UPDATED) VALUES (${trackRatingKey}, '${i}', $(date +%s));"; then
                            printOutput "5" "Added track rating key [${trackRatingKey}] to database"
                        else
                            badExit "228" "Adding track rating key [${trackRatingKey}] to database failed"
                        fi

                        albumRatingKey="${z}"
                        break
                    fi
                done
            done
        fi
    fi

    if ! setAlbumMetadata "${albumRatingKey}"; then
        printOutput "1" "Failed to update metadata for album rating key [${ratingKey}]"
    fi
done

if [[ "${#reindexSeason[@]}" -ne "0" ]]; then
    printOutput "3" "########## Correcting media item positioning ##########"
fi
for seasonId in "${reindexSeason[@]}"; do
    printOutput "3" "Re-indexing rating keys for season ID [${seasonRatingKey}]"
    # Let's update the list of rating keys as correlated to file ID's from Plex
    callCurl "${plexAdd}/library/metadata/${seasonId}/children?X-Plex-Token=${plexToken}"
    while read -r epId; do
        # Media item rating key is epId
        ytId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${epId}\" ) .Media.Part.\"+@file\"" <<<"${curlOutput}")"
        ytId="${ytId%\]\.*}"
        ytId="${ytId##*\[}"
        
        # Get the rating key
        getVideoFileRatingKey "${ytId}"
        
        # Get the pre-move watch status
        callCurl "${plexAdd}/library/metadata/${videoFileRatingKey[_${ytId}]}?X-Plex-Token=${plexToken}"
        watchStatus="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .\"+@viewOffset\"" <<<"${curlOutput}")"
        if [[ "${watchStatus}" =~ ^[0-9]+$ ]]; then
            # It's partially watched
            reindexArr["_${ytId}"]="${watchStatus}"
        else
            # It's watched or unwatched
            # We need the viewCount
            watchStatus="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${videoFileRatingKey[_${ytId}]}\" ) .\"+@viewCount\"" <<<"${curlOutput}")"
            if [[ "${watchStatus}" == "null" ]]; then
                # It's unwatched
                reindexArr["_${ytId}"]="unwatched"
            else
                # It's unwatched
                reindexArr["_${ytId}"]="watched"
            fi
        fi
        
        # Make sure we have zero or (preferrably) one entry in the video_rating_key_by_item table
        dbCount="$(sqDb "SELECT COUNT(1) FROM video_rating_key_by_item WHERE ID = '${ytId}';")"
        if [[ "${dbCount}" -eq "0" ]]; then
            # We need to insert, which we'll do below
            true
        elif [[ "${dbCount}" -eq "1" ]]; then
            # We can't update the ID column (Rating key), and I didn't plan ahead to ID these columns by ${ytId}, so
            # we'll take the lazy way out and delete the row, and then add the new one.
            if sqDb "DELETE FROM video_rating_key_by_item WHERE ID = '${ytId}';"; then
                printOutput "5" "Removed file ID [${ytId}] rating key [${epId}] from database"
            else
                badExit "229" "Failed to remove file ID [${ytId}] rating key [${epId}] from database"
            fi
        else
            # We need to panic
            badExit "230" "Received unexpected output [${dbCount}] when checking video_rating_key_by_item table -- Possible database corruption"
        fi
        
        # Make sure we don't have the new rating key under and old file ID
        dbCount="$(sqDb "SELECT COUNT(1) FROM video_rating_key_by_item WHERE RATING_KEY = ${epId};")"
        if [[ "${dbCount}" -eq "0" ]]; then
            # We're good
            true
        elif [[ "${dbCount}" -eq "1" ]]; then
            # Get rid of the old one
            if sqDb "DELETE FROM video_rating_key_by_item WHERE RATING_KEY = ${epId};"; then
                printOutput "5" "Removed stale rating key [${epId}] from database"
            else
                badExit "231" "Failed to remove stale rating key [${epId}] from database"
            fi
        else
            # We need to panic
            badExit "232" "Received unexpected output [${dbCount}] when removing stale rating key [${epId}] from video_rating_key_by_item table -- Possible database corruption"
        fi
        
        # Add the new data
        videoFileRatingKey["_${ytId}"]="${epId}"
        if sqDb "INSERT INTO video_rating_key_by_item (RATING_KEY, ID, UPDATED) VALUES (${epId}, '${ytId}', $(date +%s));"; then
            printOutput "5" "Added file ID [${ytId}] with rating key to [${epId}] to database"
        else
            badExit "233" "Failed to update file ID [${ytId}] rating key to [${epId}]"
        fi
        
    done < <(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
done

if [[ "$(( ${#watchedArr[@]} + ${#reindexArr[@]} ))" -ne "0" ]]; then
    printOutput "3" "############ Correcting media watch status ############"
fi
for ytId in "${!reindexArr[@]}"; do
    # Unpad the key
    ytId="${ytId#_}"

    # Assign titles
    assignTitle "${ytId}"
    
    # Get the epId (rating key) for the file ID
    getVideoFileRatingKey "${ytId}"
    if ! validateInterger "${videoFileRatingKey[_${ytId}]}"; then
        printOutput "1" "Variable videoFileRatingKey[_${ytId}] [${videoFileRatingKey[_${ytId}]}] failed to validate -- Unable to continue"
        continue
    fi
    # Get the channel ID for the file ID
    channelId="$(sqDb "SELECT CHANNEL_ID from source_videos WHERE ID = '${ytId}';")"
    if [[ -z "${channelId}" ]]; then
        printOutput "1" "Unable to locate channel ID for file ID [${ytId}] -- Skipping"
        continue
    fi
    # Get the video year for the file ID
    vidYear="$(sqDb "SELECT YEAR from source_videos WHERE ID = '${ytId}';")"
    if ! validateInterger "${vidYear}"; then
        printOutput "1" "Variable vidYear [${vidYear}] failed to validate -- Unable to continue"
        continue
    fi
    
    # Get the current watch status for the episodes
    # We need the season's rating key
    seasonRatingKey="$(sqDb "SELECT RATING_KEY FROM video_rating_key_by_season WHERE CHANNEL_ID = '${channelId}' AND YEAR = ${vidYear};")"
    if ! validateInterger "${seasonRatingKey}"; then
        printOutput "1" "Variable seasonRatingKey [${seasonRatingKey}] failed to validate -- Unable to continue"
        continue
    fi
    # Get the watch status for the season
    callCurl "${plexAdd}/library/metadata/${seasonRatingKey}/children?X-Plex-Token=${plexToken}"
    # For each rating key in this season
    
    watchStatus="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${videoFileRatingKey[_${ytId}]}\" ) .\"+@viewOffset\"" <<<"${curlOutput}")"
    if [[ "${watchStatus}" =~ ^[0-9]+$ ]]; then
        # It's partially watched
        watchStatus="${watchStatus}"
    else
        # It's watched or unwatched
        # We need the viewCount
        watchStatus="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${videoFileRatingKey[_${ytId}]}\" ) .\"+@viewCount\"" <<<"${curlOutput}")"
        if [[ "${watchStatus}" == "null" ]]; then
            # It's unwatched
            watchStatus="unwatched"
        else
            # It's unwatched
            watchStatus="watched"
        fi
    fi
    
    if ! [[ "${watchStatus}" == "${reindexArr[_${ytId}]}" ]]; then
        # reindexArr[${ytId}] is the watch status/offset [interger of progress]
        printOutput "3" "Correcting watch status for file ID [${ytId}]"
        
        if [[ "${reindexArr[_${ytId}]}" == "watched" ]]; then
            # Issue the call to mark the item as watched
            printOutput "4" "Marking file ID [${ytId}] as watched"
            if callCurl "${plexAdd}/:/scrobble?identifier=com.plexapp.plugins.library&key=${videoFileRatingKey[_${ytId}]}&X-Plex-Token=${plexToken}"; then
                printOutput "5" "Success"
            else
                printOutput "1" "Failed to mark file ID [${ytId}] as watched via rating key [${videoFileRatingKey[_${ytId}]}]"
            fi
        elif [[ "${reindexArr[_${ytId}]}" == "unwatched" ]]; then
            # Issue the call to mark the item as unwatched
            printOutput "4" "Marking file ID [${ytId}] as unwatched"
            if callCurl "${plexAdd}/:/unscrobble?identifier=com.plexapp.plugins.library&key=${videoFileRatingKey[_${ytId}]}&X-Plex-Token=${plexToken}"; then
                printOutput "5" "Success"
            else
                printOutput "1" "Failed to mark file ID [${ytId}] as unwatched via rating key [${videoFileRatingKey[_${ytId}]}]"
            fi
        elif [[ "${reindexArr[_${ytId}]}" =~ ^[0-9]+$ ]]; then
            # Issue the call to mark the item as partially watched
            printOutput "4" "Marking file ID [${ytId}] as partially watched watched [$(msToTime "${reindexArr[_${ytId}]}")]"
            if callCurlPut "${plexAdd}/:/progress?key=${videoFileRatingKey[_${ytId}]}&identifier=com.plexapp.plugins.library&time=${reindexArr[_${ytId}]}&state=stopped&X-Plex-Token=${plexToken}"; then
                printOutput "5" "Success"
            else
                printOutput "1" "Failed to mark file ID [${ytId}] as partially watched [${reindexArr[_${ytId}]}|$(msToTime "${reindexArr[_${ytId}]}")] via rating key [${videoFileRatingKey[_${ytId}]}]"
            fi
        else
            badExit "234" "Unexpected watch status for [${ytId}]: ${reindexArr[_${ytId}]}"
        fi
    fi
done

# Next from any new media we've added
for ytId in "${watchedArr[@]}"; do
    # Assign titles
    assignTitle "${ytId}"
    
    # ytId is the file ID
    printOutput "3" "Marking file ID [${ytId}] as watched"
    
    # Get the epId for the file ID
    getVideoFileRatingKey "${ytId}"
    
    # Issue the call to mark the item as watched
    printOutput "4" "Marking file ID [${ytId}] as watched"
    if callCurl "${plexAdd}/:/scrobble?identifier=com.plexapp.plugins.library&key=${videoFileRatingKey[_${ytId}]}&X-Plex-Token=${plexToken}"; then
        printOutput "5" "Successfully marked file ID [${ytId}] as watched"
    else
        printOutput "1" "Failed to mark file ID [${ytId}] as watched via rating key [${videoFileRatingKey[_${ytId}]}]"
    fi
done

if [[ "$(( ${#newPlaylists[@]} + ${#updatedPlaylists[@]} ))" -ge "1" ]]; then
    printOutput "3" "######### Updating playlists and collections ##########"
fi

for plId in "${newPlaylists[@]}"; do
    if plTitle="$(sqDb "SELECT TITLE FROM source_playlists WHERE ID = '${plId}';")"; then
        # Expected outcome
        true
    else
        badExit "235" "Unable to retrieve playlist title from ID [${plId}] -- Possible database corruption"
    fi
    if plVis="$(sqDb "SELECT VISIBILITY FROM source_playlists WHERE ID = '${plId}';")"; then
        # Expected outcome
        true
    else
        badExit "236" "Unable to retrieve playlist title from ID [${plId}] -- Possible database corruption"
    fi
    
    if [[ "${plVis}" == "public" ]]; then
        # Treat is as a collection.
        
        # Get an indexed list of files in the collection, in order
        # We're going to start it from 1, because that makes debugging positioning easier on my brain
        unset dbPlaylistVids plVidsVideo plVidsAudio
        dbPlaylistVids[0]="null"
        while read -r i; do
            dbPlaylistVids+=("${i}")
        done < <(sqDb "SELECT ID FROM playlist_order WHERE PLAYLIST_KEY = '${plId}' ORDER BY PLAYLIST_INDEX ASC;")
        unset dbPlaylistVids[0]
        
        # Assign titles
        for ytId in "${dbPlaylistVids[@]}"; do
            assignTitle "${ytId}"
        done
        
        # Get an indexed list of files for a video collection
        for i in "${dbPlaylistVids[@]}"; do
            if vidStatus="$(sqDb "SELECT VID_STATUS FROM source_videos WHERE ID = '${i}';")"; then
                # Expected outcome
                # If it's 'downloaded', then add it to our video playlist array
                if [[ "${vidStatus}" == "downloaded" ]]; then
                    plVidsVideo+=("${i}")
                fi
            else
                badExit "237" "Unable to retrieve video status for file ID [${i}]"
            fi
            if audStatus="$(sqDb "SELECT AUD_STATUS FROM source_videos WHERE ID = '${i}';")"; then
                # Expected outcome
                # If it's 'downloaded', then add it to our audio playlist array
                if [[ "${audStatus}" == "downloaded" ]]; then
                    plVidsAudio+=("${i}")
                fi
            else
                badExit "238" "Unable to retrieve video status for file ID [${i}]"
            fi
        done
        
        # If we have videos, create a video collection
        if [[ "${#plVidsVideo[@]}" -ne "0" ]]; then
            # Make sure it doesn't already exist
            callCurl "${plexAdd}/library/sections/${videoLibraryId}/collections?X-Plex-Token=${plexToken}"
            collectionRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@title\" == \"${plTitle}\" ) .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -n "${collectionRatingKey}" ]]; then
                printOutput "1" "Video collection [${plTitle}] appears to already exist under rating key [${collectionRatingKey}] -- Skipping creation"
            else
                printOutput "3" "Creating video collection [${plTitle}]"
            
                # Encode our collection title
                collectionTitleEncoded="$(rawurlencode "${plTitle}")"
                
                # Get our first item's rating key to seed the collection
                getVideoFileRatingKey "${plVidsVideo[0]}"
                
                # Create the collection
                callCurlPost "${plexAdd}/library/collections?type=4&title=${collectionTitleEncoded}&smart=0&uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${videoFileRatingKey[_${plVidsVideo[0]}]}&sectionId=${videoLibraryId}&X-Plex-Token=${plexToken}"
                
                # Retrieve the rating key
                collectionRatingKey="$(yq -p xml ".MediaContainer.Directory.\"+@ratingKey\"" <<<"${curlOutput}")"
                # Verify it
                if [[ -z "${collectionRatingKey}" ]]; then
                    printOutput "1" "Received no output for video collection rating key for playlist ID [${plId}] on creation -- Skipping"
                    continue
                elif ! [[ "${collectionRatingKey}" =~ ^[0-9]+$ ]]; then
                    printOutput "1" "Received non-interger [${collectionRatingKey}] for video collection rating key for playlist ID [${plId}] on creation -- Skipping"
                else
                    printOutput "4" "Created video collection [${plTitle}] successfully"
                    printOutput "5" "Added [${plVidsVideo[0]}|${videoFileRatingKey[_${plVidsVideo[0]}]}] to video collection [${collectionRatingKey}]"
                fi
                # Store it
                # We already know we exist in the database, so this is an update call
                if sqDb "UPDATE source_playlists SET VID_RATING_KEY = ${collectionRatingKey} WHERE ID = '${plId}';"; then
                    printOutput "5" "Updated playlist ID [${plId}] video rating key to [${collectionRatingKey}]"
                else
                    badExit "239" "Failed to update playlist ID [${plId}] video rating key to [${collectionRatingKey}] -- Possible database corruption"
                fi
                
                # Set the order to 'Custom'
                if callCurlPut "${plexAdd}/library/metadata/${collectionRatingKey}/prefs?collectionSort=2&X-Plex-Token=${plexToken}"; then
                    printOutput "4" "Video collection [${collectionRatingKey}] order set to 'Custom'"
                else
                    printOutput "1" "Unable to change video collection [${collectionRatingKey}] order to 'Custom' -- Skipping"
                    continue
                fi
                
                # Update the description
                updateCollectionInfo "${plId}" "${collectionRatingKey}"
                
                # Add the rest of the videos
                # Start from element 1, as we already added element 0
                for i in "${plVidsVideo[@]:1}"; do
                    getVideoFileRatingKey "${i}"
                    if callCurlPut "${plexAdd}/library/collections/${collectionRatingKey}/items?uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${videoFileRatingKey[_${i}]}&X-Plex-Token=${plexToken}"; then
                        printOutput "4" "Added [${i}|${videoFileRatingKey[_${i}]}] to video collection [${collectionRatingKey}]"
                    else
                        printOutput "1" "Failed to add [${i}|${videoFileRatingKey[_${i}]}] to video collection [${collectionRatingKey}]"
                    fi
                done
                
                # Fix the order
                collectionVerifySort "${collectionRatingKey}" "video"
            fi
        fi
        
        # If we have songs, create an audio collection
        if [[ "${#plVidsAudio[@]}" -ne "0" ]]; then
            # Make sure it doesn't already exist
            callCurl "${plexAdd}/library/sections/${audioLibraryId}/collections?X-Plex-Token=${plexToken}"
            collectionRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@title\" == \"${plTitle}\" ) .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -n "${collectionRatingKey}" ]]; then
                printOutput "1" "Audio collection [${plTitle}] appears to already exist under rating key [${collectionRatingKey}] -- Skipping creation"
            else
                printOutput "3" "Creating audio collection [${plTitle}]"
                
                # Encode our collection title
                collectionTitleEncoded="$(rawurlencode "${plTitle}")"
                
                # Get our first item's rating key to seed the collection
                getAudioFileRatingKey "${plVidsAudio[0]}"
                
                # Create the collection
                callCurlPost "${plexAdd}/library/collections?type=10&title=${collectionTitleEncoded}&smart=0&uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${audioFileRatingKey[_${plVidsAudio[0]}]}&sectionId=${audioLibraryId}&X-Plex-Token=${plexToken}"
                
                # Retrieve the rating key
                collectionRatingKey="$(yq -p xml ".MediaContainer.Directory.\"+@ratingKey\"" <<<"${curlOutput}")"
                # Verify it
                if [[ -z "${collectionRatingKey}" ]]; then
                    printOutput "1" "Received no output for audio collection rating key for playlist ID [${plId}] on creation -- Skipping"
                    continue
                elif ! [[ "${collectionRatingKey}" =~ ^[0-9]+$ ]]; then
                    printOutput "1" "Received non-interger [${collectionRatingKey}] for audio collection rating key for playlist ID [${plId}] on creation -- Skipping"
                else
                    printOutput "4" "Created audio collection [${plTitle}] successfully"
                    printOutput "5" "Added [${plVidsAudio[0]}|${audioFileRatingKey[_${plVidsAudio[0]}]}] to audio collection [${collectionRatingKey}]"
                fi
                # Store it
                # We already know we exist in the database, so this is an update call
                if sqDb "UPDATE source_playlists SET AUD_RATING_KEY = ${collectionRatingKey} WHERE ID = '${plId}';"; then
                    printOutput "5" "Updated playlist ID [${plId}] audio rating key to [${collectionRatingKey}]"
                else
                    badExit "240" "Failed to update playlist ID [${plId}] audio rating key to [${collectionRatingKey}] -- Possible database corruption"
                fi
                
                # Set the order to 'Custom'
                if callCurlPut "${plexAdd}/library/metadata/${collectionRatingKey}/prefs?collectionSort=2&X-Plex-Token=${plexToken}"; then
                    printOutput "4" "Audio collection [${collectionRatingKey}] order set to 'Custom'"
                else
                    printOutput "1" "Unable to change audio collection [${collectionRatingKey}] order to 'Custom' -- Skipping"
                    continue
                fi
                
                # Update the description
                updateCollectionInfo "${plId}" "${collectionRatingKey}"
                
                # Add the rest of the videos
                # Start from element 1, as we already added element 0
                for i in "${plVidsAudio[@]:1}"; do
                    getAudioFileRatingKey "${i}"
                    if callCurlPut "${plexAdd}/library/collections/${collectionRatingKey}/items?uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${audioFileRatingKey[_${i}]}&X-Plex-Token=${plexToken}"; then
                        printOutput "4" "Added [${i}|${audioFileRatingKey[_${i}]}] to audio collection [${collectionRatingKey}]"
                    else
                        printOutput "1" "Failed to add [${i}|${audioFileRatingKey[_${i}]}] to audio collection [${collectionRatingKey}]"
                    fi
                done
                
                # Fix the order
                collectionVerifySort "${collectionRatingKey}" "audio"
            fi
        fi
        
    elif [[ "${plVis}" == "private" ]]; then
        # Treat it as a playlist
        
        # Get an indexed list of files in the playlist, in order
        # We're going to start it from 1, because that makes debugging positioning easier on my brain
        unset dbPlaylistVids plVidsVideo plVidsAudio
        dbPlaylistVids[0]="null"
        while read -r i; do
            dbPlaylistVids+=("${i}")
        done < <(sqDb "SELECT ID FROM playlist_order WHERE PLAYLIST_KEY = '${plId}' ORDER BY PLAYLIST_INDEX ASC;")
        unset dbPlaylistVids[0]
        
        # Assign titles
        for ytId in "${dbPlaylistVids[@]}"; do
            assignTitle "${ytId}"
        done
        
        # Get an indexed list of files for a video playlist and an audio playlist
        for i in "${dbPlaylistVids[@]}"; do
            if vidStatus="$(sqDb "SELECT VID_STATUS FROM source_videos WHERE ID = '${i}';")"; then
                # Expected outcome
                # If it's 'downloaded', then add it to our video playlist array
                if [[ "${vidStatus}" == "downloaded" ]]; then
                    plVidsVideo+=("${i}")
                fi
            else
                badExit "241" "Unable to retrieve video status for file ID [${i}]"
            fi
            if audStatus="$(sqDb "SELECT AUD_STATUS FROM source_videos WHERE ID = '${i}';")"; then
                # Expected outcome
                # If it's 'downloaded', then add it to our audio playlist array
                if [[ "${audStatus}" == "downloaded" ]]; then
                    plVidsAudio+=("${i}")
                fi
            else
                badExit "242" "Unable to retrieve video status for file ID [${i}]"
            fi
        done
           
        # If we have videos, create a video playlist
        if [[ "${#plVidsVideo[@]}" -ne "0" ]]; then
            # Make sure it doesn't already exist
            callCurl "${plexAdd}/playlists?X-Plex-Token=${plexToken}"
            playlistRatingKey="$(yq -p xml ".MediaContainer.Playlist | ([] + .) | .[] | select ( .\"+@playlistType\" == \"video\" ) | select ( .\"+@title\" == \"${plTitle}\" ) .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -n "${playlistRatingKey}" ]]; then
                printOutput "1" "Video playlist [${plTitle}] appears to already exist under rating key [${playlistRatingKey}] -- Skipping creation"
            else
                printOutput "3" "Creating video playlist [${plTitle}]"
            
                # Encode our playlist title
                playlistTitleEncoded="$(rawurlencode "${plTitle}")"
                
                # Get our first item's rating key to seed the playlist
                getVideoFileRatingKey "${plVidsVideo[0]}"
                
                # Create the playlist
                callCurlPost "${plexAdd}/playlists?type=video&title=${playlistTitleEncoded}&smart=0&uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${videoFileRatingKey[_${plVidsVideo[0]}]}&X-Plex-Token=${plexToken}"
                
                # Retrieve the rating key
                playlistRatingKey="$(yq -p xml ".MediaContainer.Playlist.\"+@ratingKey\"" <<<"${curlOutput}")"
                # Verify it
                if [[ -z "${playlistRatingKey}" ]]; then
                    printOutput "1" "Received no output for playlist rating key for playlist ID [${plId}] on creation -- Skipping"
                    continue
                elif ! [[ "${playlistRatingKey}" =~ ^[0-9]+$ ]]; then
                    printOutput "1" "Received non-interger [${playlistRatingKey}] for playlist rating key for playlist ID [${plId}] on creation -- Skipping"
                else
                    printOutput "3" "Created playlist [${plTitle}] successfully"
                    printOutput "4" "Added file ID [${plVidsVideo[0]}] via rating key [${videoFileRatingKey[_${plVidsVideo[0]}]}] to playlist [${playlistRatingKey}] [${titleById[_${plVidsVideo[0]}]}]"
                fi
                
                # Store it
                # We already know we exist in the database, so this is an update call
                if sqDb "UPDATE source_playlists SET VID_RATING_KEY = ${playlistRatingKey} WHERE ID = '${plId}';"; then
                    printOutput "5" "Updated playlist ID [${plId}] rating key to [${playlistRatingKey}]"
                else
                    badExit "243" "Failed to update playlist ID [${plId}] rating key to [${playlistRatingKey}] -- Possible database corruption"
                fi
                
                # Update the playlist info
                updatePlaylistInfo "${plId}" "${playlistRatingKey}"
                
                # Add the rest of the videos
                # Start from element 1, as we already added element 0
                for i in "${plVidsVideo[@]:1}"; do
                    getVideoFileRatingKey "${i}"
                    if callCurlPut "${plexAdd}/playlists/${playlistRatingKey}/items?uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${videoFileRatingKey[_${i}]}&X-Plex-Token=${plexToken}"; then
                        printOutput "4" "Added file ID [${i}] via rating key [${videoFileRatingKey[_${i}]}] to playlist [${playlistRatingKey}] [${titleById[_${i}]}]"
                    else
                        printOutput "1" "Failed to add [${i}|${videoFileRatingKey[_${i}]}] to playlist [${playlistRatingKey}]"
                    fi
                done
                
                # Fix the order
                playlistVerifySort "${playlistRatingKey}" "video"
            fi
        fi
        
        if [[ "${#plVidsAudio[@]}" -ne "0" ]]; then
            # Make sure it doesn't already exist
            callCurl "${plexAdd}/playlists?X-Plex-Token=${plexToken}"
            playlistRatingKey="$(yq -p xml ".MediaContainer.Playlist | ([] + .) | .[] | select ( .\"+@playlistType\" == \"audio\" ) | select ( .\"+@title\" == \"${plTitle}\" ) .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -n "${playlistRatingKey}" ]]; then
                printOutput "1" "Audio playlist [${plTitle}] appears to already exist under rating key [${playlistRatingKey}] -- Skipping creation"
            else
                printOutput "3" "Creating audio playlist [${plTitle}]"
            
                # Encode our playlist title
                playlistTitleEncoded="$(rawurlencode "${plTitle}")"
                
                # Get our first item's rating key to seed the playlist
                getAudioFileRatingKey "${plVidsAudio[0]}"
                
                # Create the playlist
                callCurlPost "${plexAdd}/playlists?type=audio&title=${playlistTitleEncoded}&smart=0&uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${audioFileRatingKey[_${plVidsAudio[0]}]}&X-Plex-Token=${plexToken}"
                
                # Retrieve the rating key
                playlistRatingKey="$(yq -p xml ".MediaContainer.Playlist.\"+@ratingKey\"" <<<"${curlOutput}")"
                # Verify it
                if [[ -z "${playlistRatingKey}" ]]; then
                    printOutput "1" "Received no output for playlist rating key for playlist ID [${plId}] on creation -- Skipping"
                    continue
                elif ! [[ "${playlistRatingKey}" =~ ^[0-9]+$ ]]; then
                    printOutput "1" "Received non-interger [${playlistRatingKey}] for playlist rating key for playlist ID [${plId}] on creation -- Skipping"
                else
                    printOutput "3" "Created playlist [${plTitle}] successfully"
                    printOutput "4" "Added file ID [${plVidsAudio[0]}] via rating key [${audioFileRatingKey[_${plVidsAudio[0]}]}] to playlist [${playlistRatingKey}] [${titleById[_${plVidsAudio[0]}]}]"
                fi
                
                # Store it
                # We already know we exist in the database, so this is an update call
                if sqDb "UPDATE source_playlists SET AUD_RATING_KEY = ${playlistRatingKey} WHERE ID = '${plId}';"; then
                    printOutput "5" "Updated playlist ID [${plId}] rating key to [${playlistRatingKey}]"
                else
                    badExit "244" "Failed to update playlist ID [${plId}] rating key to [${playlistRatingKey}] -- Possible database corruption"
                fi
                
                # Update the playlist info
                updatePlaylistInfo "${plId}" "${playlistRatingKey}"
                
                # Add the rest of the videos
                # Start from element 1, as we already added element 0
                for i in "${plVidsAudio[@]:1}"; do
                    getAudioFileRatingKey "${i}"
                    if callCurlPut "${plexAdd}/playlists/${playlistRatingKey}/items?uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${audioFileRatingKey[_${i}]}&X-Plex-Token=${plexToken}"; then
                        printOutput "4" "Added file ID [${i}] via rating key [${audioFileRatingKey[_${i}]}] to playlist [${playlistRatingKey}] [${titleById[_${i}]}]"
                    else
                        printOutput "1" "Failed to add [${i}|${audioFileRatingKey[_${i}]}] to playlist [${playlistRatingKey}]"
                    fi
                done
                
                # Fix the order
                playlistVerifySort "${playlistRatingKey}" "audio"
            fi
        fi
    fi    
done

for plId in "${updatedPlaylists[@]}"; do
    printOutput "3" "Updating playlist ID [${plId}]"
    if plTitle="$(sqDb "SELECT TITLE FROM source_playlists WHERE ID = '${plId}';")"; then
        # Expected outcome
        true
    else
        badExit "245" "Unable to retrieve playlist title from ID [${plId}] -- Possible database corruption"
    fi
    if plVis="$(sqDb "SELECT VISIBILITY FROM source_playlists WHERE ID = '${plId}';")"; then
        # Expected outcome
        true
    else
        badExit "246" "Unable to retrieve playlist title from ID [${plId}] -- Possible database corruption"
    fi
    
    if [[ "${plVis}" == "public" ]]; then
        # Treat is as a collection.
        # Check for a video rating key
        if playlistRatingKey="$(sqDb "SELECT VID_RATING_KEY FROM source_playlists WHERE ID = '${plId}';")"; then
            # Command executed successfully, check to see if we got a value
            if [[ -z "${playlistRatingKey}" ]]; then
                printOutput "2" "No video collection rating key found, skipping video collection update"
            elif ! [[ "${playlistRatingKey}" =~ ^[0-9]+$ ]]; then
                printOutput "1" "Video collection rating key lookup for playlist ID [${plId}] returned non-interger [${playlistRatingKey}] -- Skipping"
                continue
            else
                # Get an indexed list of files in the collection, in order starting from '1'
                printOutput "5" "Obtaining order of items in collection from database"
                unset dbPlaylistVids
                dbPlaylistVids[0]="null"
                while read -r i; do
                    if vidStatus="$(sqDb "SELECT VID_STATUS FROM source_videos WHERE ID = '${i}';")"; then
                        if [[ "${vidStatus}" == "downloaded" ]]; then
                            dbPlaylistVids+=("${i}")
                        fi
                    fi
                done < <(sqDb "SELECT ID FROM playlist_order WHERE PLAYLIST_KEY = '${plId}' ORDER BY PLAYLIST_INDEX ASC;")
                unset dbPlaylistVids[0]
                for arrIndex in "${!dbPlaylistVids[@]}"; do
                    assignTitle "${ytId}"
                    printOutput "5" "   dbCollectionOrder | ${arrIndex} => ${dbPlaylistVids[${arrIndex}]} [${titleById[_${dbPlaylistVids[${arrIndex}]}]}]"
                done
                # Add missing items
                collectionVerifyAdd "${playlistRatingKey}" "video"
                # Remove old items
                collectionVerifyDelete "${playlistRatingKey}" "video"
                # Correct the order
                collectionVerifySort "${playlistRatingKey}" "video"
            fi
        fi
        if playlistRatingKey="$(sqDb "SELECT AUD_RATING_KEY FROM source_playlists WHERE ID = '${plId}';")"; then
            # Command executed successfully, check to see if we got a value
            if [[ -z "${playlistRatingKey}" ]]; then
                printOutput "2" "No audio collection rating key found, skipping audio collection update"
            elif ! [[ "${playlistRatingKey}" =~ ^[0-9]+$ ]]; then
                printOutput "1" "Audio collection rating key lookup for playlist ID [${plId}] returned non-interger [${playlistRatingKey}] -- Skipping"
                continue
            else
                # Get an indexed list of files in the collection, in order starting from '1'
                printOutput "5" "Obtaining order of items in collection from database"
                unset dbPlaylistVids
                dbPlaylistVids[0]="null"
                while read -r i; do
                    if vidStatus="$(sqDb "SELECT AUD_STATUS FROM source_videos WHERE ID = '${i}';")"; then
                        if [[ "${vidStatus}" == "downloaded" ]]; then
                            dbPlaylistVids+=("${i}")
                        fi
                    fi
                done < <(sqDb "SELECT ID FROM playlist_order WHERE PLAYLIST_KEY = '${plId}' ORDER BY PLAYLIST_INDEX ASC;")
                unset dbPlaylistVids[0]
                for arrIndex in "${!dbPlaylistVids[@]}"; do
                    assignTitle "${ytId}"
                    printOutput "5" "   dbCollectionOrder | ${arrIndex} => ${dbPlaylistVids[${arrIndex}]} [${titleById[_${dbPlaylistVids[${arrIndex}]}]}]"
                done
                # Add missing items
                collectionVerifyAdd "${playlistRatingKey}" "audio"
                # Remove old items
                collectionVerifyDelete "${playlistRatingKey}" "audio"
                # Correct the order
                collectionVerifySort "${playlistRatingKey}" "audio"
            fi
        fi
    elif [[ "${plVis}" == "private" ]]; then
        # Treat it as a playlist
        # Check for a video rating key
        if playlistRatingKey="$(sqDb "SELECT VID_RATING_KEY FROM source_playlists WHERE ID = '${plId}';")"; then
            # Command executed successfully, check to see if we got a value
            if [[ -z "${playlistRatingKey}" ]]; then
                printOutput "2" "No video playlist rating key found, skipping video playlist update"
            elif ! [[ "${playlistRatingKey}" =~ ^[0-9]+$ ]]; then
                printOutput "1" "Video playlist rating key lookup for playlist ID [${plId}] returned non-interger [${playlistRatingKey}] -- Skipping"
                continue
            else
                # Get an indexed list of files in the playlist, in order starting from '1'
                printOutput "5" "Obtaining order of items in video playlist from database"
                unset dbPlaylistVids
                dbPlaylistVids[0]="null"
                while read -r i; do
                    if vidStatus="$(sqDb "SELECT VID_STATUS FROM source_videos WHERE ID = '${i}';")"; then
                        if [[ "${vidStatus}" == "downloaded" ]]; then
                            dbPlaylistVids+=("${i}")
                        fi
                    fi
                done < <(sqDb "SELECT ID FROM playlist_order WHERE PLAYLIST_KEY = '${plId}' ORDER BY PLAYLIST_INDEX ASC;")
                unset dbPlaylistVids[0]
                for arrIndex in "${!dbPlaylistVids[@]}"; do
                    assignTitle "${ytId}"
                    printOutput "5" "   dbCollectionOrder | ${arrIndex} => ${dbPlaylistVids[${arrIndex}]} [${titleById[_${dbPlaylistVids[${arrIndex}]}]}]"
                done
                # Add missing items
                playlistVerifyAdd "${playlistRatingKey}" "video"
                # Remove old items
                playlistVerifyDelete "${playlistRatingKey}" "video"
                # Correct the order
                playlistVerifySort "${playlistRatingKey}" "video"
            fi
        fi
        if playlistRatingKey="$(sqDb "SELECT AUD_RATING_KEY FROM source_playlists WHERE ID = '${plId}';")"; then
            # Command executed successfully, check to see if we got a value
            if [[ -z "${playlistRatingKey}" ]]; then
                printOutput "2" "No audio playlist rating key found, skipping audio playlist update"
            elif ! [[ "${playlistRatingKey}" =~ ^[0-9]+$ ]]; then
                printOutput "1" "Audio playlist rating key lookup for playlist ID [${plId}] returned non-interger [${playlistRatingKey}] -- Skipping"
                continue
            else
                # Get an indexed list of files in the playlist, in order starting from '1'
                printOutput "5" "Obtaining order of items in audio playlist from database"
                unset dbPlaylistVids
                dbPlaylistVids[0]="null"
                while read -r i; do
                    if vidStatus="$(sqDb "SELECT AUD_STATUS FROM source_videos WHERE ID = '${i}';")"; then
                        if [[ "${vidStatus}" == "downloaded" ]]; then
                            dbPlaylistVids+=("${i}")
                        fi
                    fi
                done < <(sqDb "SELECT ID FROM playlist_order WHERE PLAYLIST_KEY = '${plId}' ORDER BY PLAYLIST_INDEX ASC;")
                unset dbPlaylistVids[0]
                for arrIndex in "${!dbPlaylistVids[@]}"; do
                    assignTitle "${ytId}"
                    printOutput "5" "   dbCollectionOrder | ${arrIndex} => ${dbPlaylistVids[${arrIndex}]} [${titleById[_${dbPlaylistVids[${arrIndex}]}]}]"
                done
                # Add missing items
                playlistVerifyAdd "${playlistRatingKey}" "audio"
                # Remove old items
                playlistVerifyDelete "${playlistRatingKey}" "audio"
                # Correct the order
                playlistVerifySort "${playlistRatingKey}" "audio"
            fi
        fi
    fi    
done

if [[ -n "${telegramBotId}" && -n "${telegramChannelId}" && "${#msgArr[@]}" -ge "1" ]]; then
    printOutput "3" "############## Sending Telegram messages ##############"
    if [[ "${#msgArr[*]}" -gt "4000" ]]; then
        firstMsg="1"
        while read -r msg; do
            if [[ "${firstMsg}" -eq "1" ]]; then
                sendTelegramMessage "<b>${0##*/}</b>${lineBreak}${lineBreak}${msg}"
                firstMsg="0"
            else
                sendTelegramMessage "${msg}"
            fi
        done < <(fold -w 4000 <<<"${msgArr[*]}")
    else
        sendTelegramMessage "<b>${0##*/}</b>${lineBreak}${lineBreak}${msgArr[*]}"
    fi
fi

cleanExit
