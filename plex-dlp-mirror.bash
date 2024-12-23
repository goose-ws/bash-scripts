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
# This script can mirror a media source in a Plex TV series compatible style.
# While it is not the first script to offering media mirroring/downloading, I have yet to find one
# that can do so in the format of a TV series. The only choice was to treat each media item as a movie,
# which is not productive to the way I want to consume media. So I made this, instead.
# It also can mirror media in audio-only format; however, each song will be its own album.

#############################
##        Changelog        ##
#############################
# 2024-12-23
# Functional, I think
# 2024-11-18
# Mostly a total rewrite. Still need to bang out collection/playlist functionality, but seems to be
# working well otherwise.
# 2024-07-29
# Initial commit, script is in 'alpha' testing at this point

#############################
##       Installation      ##
#############################
# 1. Download the script .bash file somewhere safe
# 2. Download the script .env file somewhere safe
# 3. Set up your Videos folder in Plex:
#     - On your Plex Media Server, do "Add a library"
#     - Select your library type: TV Shows
#     - Add folders: Path to your ${outputDir}
#     - Advanced > Scanner: Plex Series Scanner
#     - Advanced > Agent: Personal Media Shows
#     * You probably also want to disable Intro/Credit detection, and Ad Detection
# 4. Edit the .env file to your liking
# 5. Create a video config directory
#    So if you name the script "plex-dlp-mirror.bash"
#    Then in the same folder you would create the directory "plex-dlp-mirror.sources"
#    And within that directory, you would place a "source.env" file for each source
#    you want to add. The files can be named anything, as long as they end in ".env"
#    Here is an example source.env: https://github.com/goose-ws/bash-scripts/blob/testing/plex-dlp-mirror.env.example
# 6. Set the script to run via cron on whatever your time preference is

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
depsArr=("awk" "basename" "chmod" "cmp" "column" "convert" "curl" "date" "date" "date" "date" "date" "date" "date" "date" "date" "date" "date" "date" "date" "date" "date" "date" "date" "docker" "ffmpeg" "find" "grep" "identify" "mkdir" "mktemp" "mv" "printf" "realpath" "shuf" "sort" "sqlite3" "sqlite3" "xxd" "yq" "yt-dlp")
depFail="0"
for i in "${depsArr[@]}"; do
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
updateURL="https://raw.githubusercontent.com/goose-ws/bash-scripts/main/plex-dlp-mirror.bash"
# For ease of printing messages
lineBreak=$'\n\n'
scriptStart="$(($(date +%s%N)/1000000))"

#############################
##         Lockfile        ##
#############################
if [[ -e "${lockFile}" ]]; then
    if kill -s 0 "$(<"${lockFile}")" > /dev/null 2>&1; then
        # We only need to print the lockfile warning if we're not being spawned by cron
        if [[ -t 1 ]]; then
            echo "Lockfile present [PID $(<"${lockFile}")], refusing to run"
        fi
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
    5) logLevel="[DEBUG]";; # Super Secret Debug Mode
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
if [[ -n "${tmpDir}" ]]; then
    if ! rm -rf "${tmpDir}"; then
        printOutput "1" "Failed to clean up tmp folder [${tmpDir}]"
    fi
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
    exit "1"
fi
}

function cleanExit {
if [[ "${1}" == "silent" ]]; then
    rm -rf "${tmpDir}"
    removeLock "silent"
else
    apiCount
    if [[ -n "${tmpDir}" ]]; then
        if ! rm -rf "${tmpDir}"; then
            printOutput "1" "Failed to clean up tmp folder [${tmpDir}]"
        fi
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

function callCurlGet {
# URL to call should be ${1}
# Custom UA can be ${2}
# Will return the variable ${curlOutput}
if [[ -z "${1}" ]]; then
    badExit "1" "No input URL provided for GET"
fi
if [[ -z "${2}" ]]; then
    curlOutput="$(curl -skL -m 15 "${1}" 2>&1)"
else
    curlOutput="$(curl -skL -m 15 -A "${2}" "${1}" 2>&1)"
fi
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
callCurlGet "https://api.telegram.org/bot${telegramBotId}/getMe"
if ! [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
    printOutput "1" "Telegram bot API check failed"
else
    printOutput "4" "Telegram bot API key authenticated [$(yq -p json ".result.username" <<<"${curlOutput}")]"
    for chanId in "${telegramChannelId[@]}"; do
        if [[ -n "${2}" ]]; then
            chanId="${2}"
        fi
        callCurlGet "https://api.telegram.org/bot${telegramBotId}/getChat?chat_id=${telegramChannelId}"
        if [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
            printOutput "4" "Telegram channel authenticated [$(yq -p json ".result.title" <<<"${curlOutput}")]"
            msgEncoded="$(rawUrlEncode "${1}")"
            callCurlGet "https://api.telegram.org/bot${telegramBotId}/sendMessage?chat_id=${chanId}&parse_mode=html&text=${msgEncoded}"
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

function sendTelegramImage {
# Message to send should be passed as function positional parameter #1
# Image path should be passed as funcion positonal parameter #2
callCurlGet "https://api.telegram.org/bot${telegramBotId}/getMe"
if ! [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
    printOutput "1" "Telegram bot API check failed"
else
    printOutput "4" "Telegram bot API key authenticated [$(yq -p json ".result.username" <<<"${curlOutput}")]"
    for chanId in "${telegramChannelId[@]}"; do
        callCurlGet "https://api.telegram.org/bot${telegramBotId}/getChat?chat_id=${telegramChannelId}"
        if [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
            printOutput "4" "Telegram channel authenticated [$(yq -p json ".result.title" <<<"${curlOutput}")]"
            callCurlPost "tgimage" "https://api.telegram.org/bot${telegramBotId}/sendPhoto" "${chanId}" "${1}" "${2}"
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

function apiCount {
# Notify of how many API calls were made
if [[ "${apiCallsYouTube}" -ne "0" ]]; then
    printOutput "3" "Made [${apiCallsYouTube}] API calls to YouTube"
    printOutput "3" "Costed [${totalUnits}] units in total"
    # Make the total cost breakdown block
    readarray -t columnArr < <( (for apiKey in "${usedApiKeys[@]}"; do
        echo "API Key [${apiKey}] | [${costArr[videos_${apiKey}]}] video | [${costArr[captions_${apiKey}]}] captions | [${costArr[channels_${apiKey}]}] channels | [${costArr[playlists_${apiKey}]}] playlists"
    done
    echo "Totals | [${totalVideoUnits}] video | [${totalCaptionsUnits}] captions | [${totalChannelsUnits}] channels | [${totalPlaylistsUnits}] playlists") | column -t -s "|")
    # Now print each line of the columnArr via 'printOutput'
    for line in "${columnArr[@]}"; do
        printOutput "4" "${line}"
    done
fi
if [[ "${apiCallsLemnos}" -ne "0" ]]; then
    printOutput "3" "Made [${apiCallsLemnos}] API calls to LemnosLife"
fi
if [[ "${apiCallsSponsor}" -ne "0" ]]; then
    printOutput "3" "Made [${apiCallsSponsor}] API calls to SponsorBlock"
fi 
}

function rawUrlEncode {
local string="${1}"
local strlen="${#string}"
local encoded=()  # Declare encoded as an array
local pos c o

for (( pos=0 ; pos<strlen ; pos++ )); do
    c="${string:$pos:1}"
    if [[ "$c" =~ [[:ascii:]] ]]; then 
        case "${c}" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * ) printf -v o '%%%02x' "'${c}" ;; 
        esac
    else
        o=$(echo -n "$c" | xxd -p -c1 | while read -r line; do echo -n "%${line}"; done)
    fi
    encoded+=("${o}")  # Add the encoded character to the array
done
printf "%s" "${encoded[@]}"
}

function sqDb {
# Log the command we're executing to the database, for development purposes
# Execute the command
if sqOutput="$(sqlite3 "${sqliteDb}" "${1}" 2>&1)"; then
    if [[ -n "${sqOutput}" ]]; then
        echo "${sqOutput}"
    fi
else
    sqlite3 "${sqliteDb}" "INSERT INTO db_log (TIME, COMMAND, RESULT, OUTPUT) VALUES ('$(date)', '${1//\'/\'\'}', 'Failure', '${sqOutput//\'/\'\'}');"
    if [[ -n "${sqOutput}" ]]; then
        echo "${sqOutput}"
    fi
    return 1
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

function throttleDlp {
if ! [[ "${throttleMin}" -eq "0" && "${throttleMax}" -eq "0" ]]; then
    printOutput "4" "Throttling after yt-dlp download call"
    randomSleep "${throttleMin}" "${throttleMax}"
fi
}

## Curl functions
function callCurlPost {
# URL to call should be ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "No input URL provided for POST"
    return 1
fi
# ${2} could be --data-binary and ${3} could be an image to be uploaded
if [[ "${2}" == "--data-binary" ]]; then
    printOutput "5" "Issuing curl command [curl -skL -X POST \"${1}\" --data-binary \"${3}\"]"
    curlOutput="$(curl -skL -X POST "${1}" --data-binary "${3}" 2>&1)"
elif [[ "${1}" == "tgimage" ]]; then
    # We're sending an image to telegram
    # Positional parameter 2 is the URL
    # Positional parameter 3 is the chat ID
    # Positional parameter 4 is the caption
    # Positional parameter 5 is the image
    printOutput "5" "Issuing curl command [curl -skL -X POST \"${2}?chat_id=${3}&parse_mode=html&caption=$(rawUrlEncode "${4}")\" -F \"photo=@\"${5}\"\"]"
    curlOutput="$(curl -skL -X POST "${2}?chat_id=${3}&parse_mode=html&caption=$(rawUrlEncode "${4}")" -F "photo=@\"${5}\"" 2>&1)"
else
    printOutput "5" "Issuing curl command [curl -skL -X POST \"${1}\"]"
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
printOutput "5" "Issuing curl command [curl -skL -X DELETE \"${1}\"]"
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

## Indexing functions
function ytIdToDb {
unset dbCount vidTitle vidTitleClean channelId uploadDate epochDate uploadYear vidDesc vidType vidStatus vidError sponsorCurl
# Get the video info
# Because we can't get the time string through yt-dlp, there's no point in trying to use it as our fake API here, we *have* to API query YouTube

# There is a possibility that we only need to query the SponsorBlock API, if this video is just being checkd for an upgrade
# If we're not skipping the video, and SponsorBlock is enabled, check for availability for our video
dbCount="$(sqDb "SELECT COUNT(1) FROM source_videos WHERE ID = '${1//\'/\'\'}';")"
if [[ "${dbCount}" -eq "1" ]]; then
    vidStatus="$(sqDb "SELECT STATUS FROM source_videos WHERE ID = '${1//\'/\'\'}';")"
    # If the video status is not skipped
    if ! [[ "${vidStatus}" == "skipped" ]]; then
        # And the video status is not import
        if ! [[ "${vidStatus}" == "import" ]]; then
            # And SponsorBlock is not disabled
            if ! [[ "${sponsorblockEnable}" == "disable" ]]; then
                # Get the SponsorBlock status of the video
                sponsorApiCall "searchSegments?videoID=${1}"
                sponsorCurl="${curlOutput}"
                # If it is not found
                if [[ "${sponsorCurl}" == "Not Found" ]]; then
                    printOutput "5" "No SponsorBlock data available for video"
                    sponsorblockAvailable="Not found [$(date)]"
                    # And we are required to have it for download
                    if [[ "${sponsorblockRequire}" == "true" ]]; then
                        # Skip the download the wait for a future run
                        vidStatus="sb_wait"
                        vidError="SponsorBlock data required, but not available"
                    else
                        # Check and see if we've already grabbed this video
                        dbVidStatus="$(sqDb "SELECT SB_AVAILABLE FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
                        if [[ "${sponsorblockAvailable%% \[*}" == "Not found" ]]; then
                            # We've previously indexed this video, and SponsorBlock data was not available at that time.
                            # It's still not available, so we don't need to re-download this video.
                            printOutput "4" "Item has no updated SponsorBlock data -- Skipping"
                            return 0
                        fi    
                    fi
                else
                    # It was found
                    printOutput "5" "SponsorBlock data found for video"
                    sponsorblockAvailable="Found [$(date)]"
                fi
            fi
        else
            # The video is being imported
            true
        fi
    fi
fi

# Query the YouTube API for the video info
printOutput "5" "Calling API for video info [${1}]"
ytApiCall "videos?id=${1}&part=snippet,liveStreamingDetails"
# Check to make sure we got a result
apiResults="$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")"
# Validate it
if [[ -z "${apiResults}" ]]; then
    printOutput "1" "No data provided to validate integer"
    return 1
elif [[ "${apiResults}" =~ ^[0-9]+$ ]]; then
    # Expected outcome
    true
elif ! [[ "${apiResults}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Data [${apiResults}] failed to validate as an integer"
    return 1
else
    badExit "11" "Impossible condition"
fi
if [[ "${apiResults}" -eq "0" ]]; then
    printOutput "2" "API lookup for video ID [${1}] zero results (Is the video private?)"
    if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
        printOutput "3" "Re-attempting video ID [${1}] lookup via yt-dlp + cookie"
        dlpApiCall="$(yt-dlp --no-warnings -J --cookies "${cookieFile}" "https://www.youtube.com/watch?v=${1}" 2>/dev/null)"
        
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
            ## This is not provided by the yt-dlp payload. It cannot be looked up via the official API without oauth,
            ## which I do not want to implement for a number of reasons. Instead, I am going to get this via some very
            ## shameful code. Please do not read the below 2 lines, I am ashamed of them.
            uploadDate="$(curl -b "${cookieFile}" -skL "https://www.youtube.com/watch?v=${1}")"
            uploadDate="$(grep -E -o "<meta itemprop=\"datePublished\" content=\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}\">" <<<"${uploadDate}")"
            ## Ok I'm done, you can read it again.
            uploadDate="${uploadDate%\">}"
            uploadDate="${uploadDate##*\"}"
            # Get the video type
            vidType="$(yq -p json ".live_status" <<<"${dlpApiCall}")"
            # We just need this to be a non-null value
            broadcastStart="dlp"
            # Get the maxres thumbnail URL
            thumbUrl="$(yq -p json ".thumbnail" <<<"${dlpApiCall}")"
            thumbUrl="${thumbUrl%\?*}"
        else
            printOutput "1" "Unable to preform lookup on video ID [${1}] via yt-dlp -- Skipping"
            return 1
        fi
    else
        printOutput "1" "Video ID [${1}] API lookup failed, and no cookie file provided to attempt to yt-dlp lookup -- Skipping"
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
    vidType="$(yq -p json ".items[0].snippet.liveBroadcastContent" <<<"${curlOutput}")"
    # Get the broadcast start time (Will only return value if it's a live broadcast)
    broadcastStart="$(yq -p json ".items[0].liveStreamingDetails.actualStartTime" <<<"${curlOutput}")"
    # Get the maxres thumbnail URL
    thumbUrl="$(yq -p json ".items[0].snippet.thumbnails | to_entries | .[-1].value.url" <<<"${curlOutput}")"
else
    badExit "12" "Impossible condition"
fi

# Now that we have the channel name, let's do a quick comparison to validate that it hasn't changed
verifyChannelName "${channelId}" "${chanName}"

# Get the video title
if [[ -z "${vidTitle}" ]]; then
    printOutput "1" "Video title returned blank result [${vidTitle}]"
    return 1
fi
printOutput "5" "Video title [${vidTitle}]"

# Get the clean video title
vidTitleClean="${vidTitle}"
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
# Replace any colons :
vidTitleClean="${vidTitleClean//\\/_}"
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
if [[ -z "${vidTitleClean}" ]]; then
    printOutput "1" "Clean video title returned blank result [${vidTitle}]"
    return 1
fi
printOutput "5" "Clean video title [${vidTitleClean}]"

# Get the channel ID
if ! [[ "${channelId}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
    printOutput "1" "Unable to validate channel ID [${channelId}]"
    return 1
fi
printOutput "5" "Channel ID [${channelId}]"

# Get the upload timestamp
if [[ -z "${uploadDate}" ]]; then
    printOutput "1" "Upload date lookup failed for video [${1}]"
    return 1
fi
# Convert the date to a Unix timestamp
uploadEpoch="$(date --date="${uploadDate}" "+%s")"
if ! [[ "${uploadEpoch}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Unable to convert upload date [${uploadDate}] to unix epoch timestamp [${uploadEpoch}]"
    return 1
fi
printOutput "5" "Upload timestamp [${uploadEpoch}]"

# Get the upload year
uploadYear="${uploadDate:0:4}"
if ! [[ "${uploadYear}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Unable to extrapolate upload year [${uploadYear}] from upload date [${uploadDate}]"
    return 1
fi
printOutput "5" "Upload year [${uploadYear}]"

# Get the episode index number
# Update this after it's been added to the database (skip for now)

# Get the video description
if [[ "${vidDesc}" == " " ]]; then
    unset vidDesc
fi
if [[ -z "${vidDesc}" ]]; then
    printOutput "5" "No video description"
else
    printOutput "5" "Video description present [${#vidDesc} characters]"
fi

# Get the video type (Regular / Short / Live)
if [[ -z "${vidType}" ]]; then
    printOutput "1" "Video type lookup returned blank result [${vidType}]"
    return 1
elif [[ "${vidType}" == "none" || "${vidType}" == "not_live" || "${vidType}" == "was_live" ]]; then
    # Not currently live
    # Check to see if it's a previous broadcast
    if [[ -z "${broadcastStart}" ]]; then
        # This should not be blank, it should be 'null' or a date/time
        printOutput "1" "Broadcast start time lookup returned blank result [${broadcastStart}] -- Skipping"
        return 1
    elif [[ "${broadcastStart}" == "null" || "${vidType}" == "not_live" ]]; then
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
            vidType="short"
        elif [[ "${httpCode}" == "303" ]]; then
            # It's a regular video
            printOutput "4" "Determined video to be a standard video"
            vidType="normal"
        elif [[ "${httpCode}" == "404" ]]; then
            # No such video exists
            printOutput "1" "Curl lookup returned HTTP code 404 for video ID [${1}] -- Skipping"
            return 1
        else
            printOutput "1" "Curl lookup to determine video ID [${1}] type returned unexpected result [${httpCode}] -- Skipping"
            return 1
        fi
    elif [[ "${broadcastStart}" =~ ^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$ || "${vidType}" == "was_live" ]]; then
        printOutput "4" "Video ID [${1}] detected to be a past live broadcast"
        vidType="waslive"
    else
        printOutput "Broadcast start time lookup returned unexpected result [${broadcastStart}] -- Skipping"
        return 1
    fi
elif [[ "${vidType}" == "live" || "${vidType}" == "is_live" || "${vidType}" == "upcoming" ]]; then
    # Currently live
    liveType="${vidType}"
    printOutput "2" "Video ID [${1}] detected to be a live broadcast"
    vidType="live"
else
    printOutput "1" "Video ID [${1}] lookup video type returned invalid result [${vidType}] -- Skipping"
    return 1
fi
printOutput "5" "Video type [${vidType}]"

# We have the video format option
# We have the include shorts option
# We have the include live option
# We have the mark watched option

# Determine our status (queued/skipped)
# In case we're doing this as an update, check and see if it's already logged
dbCount="$(sqDb "SELECT COUNT(1) FROM source_videos WHERE ID = '${1//\'/\'\'}';")"
if [[ "${dbCount}" -eq "0" ]]; then
    if [[ "${2}" == "import" ]]; then
        vidStatus="import"
        # Using the error field as a cheap place to store where we need to move the file from
        vidError="${3}"
    else
        vidStatus="queued"
        if [[ "${vidType}" == "live" ]]; then
            # Can't download a currently live video
            vidStatus="waiting"
            vidError="Video has live status [${liveType}] at time of indexing"
        elif [[ "${vidType}" == "short" && "${includeShorts}" == "false" ]]; then
            # Shorts aren't allowed
            vidStatus="skipped"
            vidError="Shorts not allowed per config"
        elif [[ "${vidType}" == "waslive" ]]; then
            if [[ "${includeLiveBroadcasts}" == "false" ]]; then
                # Past live broadcasts aren't allowed
                vidStatus="skipped"
                vidError="Past live broadcasts not allowed per config"
            elif [[ "${includeLiveBroadcasts}" == "true" ]]; then
                # Past live broadcasts are allowed
                vidError="null"
            fi
        fi
    fi
elif [[ "${dbCount}" -eq "1" ]]; then
    vidStatus="$(sqDb "SELECT STATUS FROM source_videos WHERE ID = '${1//\'/\'\'}';")"
    if [[ "${vidStatus}" == "waiting" ]]; then
        if [[ "${vidType}" == "waslive" ]]; then
            if [[ "${includeLiveBroadcasts}" == "false" ]]; then
                # Past live broadcasts aren't allowed
                vidStatus="skipped"
                vidError="Past live broadcasts not allowed per config"
            elif [[ "${includeLiveBroadcasts}" == "true" ]]; then
                # Past live broadcasts are allowed
                vidStatus="queued"
                vidError="null"
            fi
        fi
    fi
else
    badExit "13" "Found [${dbCount}] results in source_videos table for video ID [${1}] -- Possible database corruption"
fi

# If we're not skipping the video
if ! [[ "${vidStatus}" == "skipped" ]]; then
    # If SponsorBlock is not 'disable'
    if ! [[ "${sponsorblockEnable}" == "disable" ]]; then
        # Check if it's available, if we haven't already
        if [[ -z "${sponsorCurl}" ]]; then
            sponsorApiCall "searchSegments?videoID=${1}"
            sponsorCurl="${curlOutput}"
        fi
        if [[ "${sponsorCurl}" == "Not Found" ]]; then
            printOutput "5" "No SponsorBlock data available for video"
            sponsorblockAvailable="Not found [$(date)]"
            if [[ "${sponsorblockRequire}" == "true" ]]; then
                vidStatus="sb_wait"
                vidError="SponsorBlock data required, but not available"
            fi
        else
            printOutput "5" "SponsorBlock data found for video"
            sponsorblockAvailable="Found [$(date)]"
        fi
    fi
fi

# Create the database channel entry if needed
chanDbCount="$(sqDb "SELECT COUNT(1) FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
if [[ "${chanDbCount}" -eq "0" ]]; then
    if ! channelToDb "${channelId}"; then
        printOutput "1" "Failed to add channel ID [${channelId}] to database -- Skipping"
        return 1
    fi
elif [[ "${chanDbCount}" -eq "1" ]]; then
    # Safety check
    true
else
    badExit "14" "Counted [${chanDbCount}] occurances of channel ID [${channelId}] -- Possible database corruption"
fi

if [[ "${dbCount}" -eq "0" ]]; then
    # Insert what we have
    if sqDb "INSERT INTO source_videos (ID, UPDATED) VALUES ('${1//\'/\'\'}', $(date +%s));"; then
        printOutput "3" "Added video ID [${1}] to database"
    else
        badExit "15" "Failed to add video ID [${1}] to database"
    fi
elif [[ "${dbCount}" -eq "1" ]]; then
    # Safety check
    true
else
    badExit "16" "Found [${dbCount}] results in source_videos table for video ID [${1}] -- Possible database corruption"
fi

# Update the title
if sqDb "UPDATE source_videos SET TITLE = '${vidTitle//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated title for video ID [${1}]"
else
    printOutput "1" "Failed to update title for video ID [${1}]"
fi

# Update the clean title
if sqDb "UPDATE source_videos SET TITLE_CLEAN = '${vidTitleClean//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated clean title for video ID [${1}]"
else
    printOutput "1" "Failed to update clean title for video ID [${1}]"
fi

# Update the channel ID
if sqDb "UPDATE source_videos SET CHANNEL_ID = '${channelId//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated channel ID for video ID [${1}]"
else
    printOutput "1" "Failed to update channel ID enable for video ID [${1}]"
fi

# Update the upload timestamp
if sqDb "UPDATE source_videos SET TIMESTAMP = ${uploadEpoch}, UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated upload timestamp for video ID [${1}]"
else
    printOutput "1" "Failed to update upload timestamp enable for video ID [${1}]"
fi

# Update the thumbnail URL
if sqDb "UPDATE source_videos SET THUMBNAIL = '${thumbUrl//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated thumbnail URL for video ID [${1}]"
else
    printOutput "1" "Failed to update thumbnail URL enable for video ID [${1}]"
fi

# Update the upload year
if sqDb "UPDATE source_videos SET YEAR = ${uploadYear}, UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated upload year for video ID [${1}]"
else
    printOutput "1" "Failed to update upload year enable for video ID [${1}]"
fi

# Update the description, if it's not empty
if [[ -n "${vidDesc}" ]]; then
    if sqDb "UPDATE source_videos SET DESC = '${vidDesc//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
        printOutput "5" "Updated descrption for video ID [${1}]"
    else
        printOutput "1" "Failed to update description for video ID [${1}]"
    fi
fi

# Update the video type
if sqDb "UPDATE source_videos SET TYPE = '${vidType//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated item type for video ID [${1}]"
else
    printOutput "1" "Failed to update item type enable for video ID [${1}]"
fi

# Update the item's output resolution
if sqDb "UPDATE source_videos SET FORMAT = '${outputResolution//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated output resolution for video ID [${1}]"
else
    printOutput "1" "Failed to update output resolution enable for video ID [${1}]"
fi

# Update the item's include shorts rule
if sqDb "UPDATE source_videos SET SHORTS = '${includeShorts//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated include shorts for video ID [${1}]"
else
    printOutput "1" "Failed to update include shorts enable for video ID [${1}]"
fi

# Update the item's include live broadcasts rule
if sqDb "UPDATE source_videos SET LIVE = '${includeLiveBroadcasts//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated include live broadcasts for video ID [${1}]"
else
    printOutput "1" "Failed to update include live broadcasts enable for video ID [${1}]"
fi

# Update the item's marked as watched rule
if sqDb "UPDATE source_videos SET WATCHED = '${markWatched//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated mark as watched rule for video ID [${1}]"
else
    printOutput "1" "Failed to update mark as watched rule enable for video ID [${1}]"
fi

# Update the item's status
if sqDb "UPDATE source_videos SET STATUS = '${vidStatus//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated SponsorBlock enable for video ID [${1}]"
else
    printOutput "1" "Failed to update SponsorBlock enable for video ID [${1}]"
fi

# Update the error, if needed
if [[ -n "${vidError}" ]]; then
    # If we have a "NULL", the null it
    if [[ "${vidError,,}" == "null" ]]; then
        if sqDb "UPDATE source_videos SET ERROR = null, UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
            printOutput "5" "Removed error for video ID [${1}]"
        else
            printOutput "1" "Failed to remove error for video ID [${1}]"
        fi
    else
        if sqDb "UPDATE source_videos SET ERROR = '${vidError//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
            printOutput "5" "Updated error for video ID [${1}]"
        else
            printOutput "1" "Failed to update error for video ID [${1}]"
        fi
    fi
fi

# Update the SponsorBlock enabled
if sqDb "UPDATE source_videos SET SB_ENABLE = '${sponsorblockEnable//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated SponsorBlock enable for video ID [${1}]"
else
    printOutput "1" "Failed to update SponsorBlock enable for video ID [${1}]"
fi
if [[ ! "${sponsorblockEnable}" == "disable" ]]; then
    # Update the SponsorBlock requirement
    if sqDb "UPDATE source_videos SET SB_REQUIRE = '${sponsorblockEnable//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
        printOutput "5" "Updated SponsorBlock requirement for video ID [${1}]"
    else
        printOutput "1" "Failed to update SponsorBlock requirement for video ID [${1}]"
    fi
    # Update the SponsorBlock availability
    if sqDb "UPDATE source_videos SET SB_AVAILABLE = '${sponsorblockAvailable//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
        printOutput "5" "Updated SponsorBlock availability for video ID [${1}]"
    else
        printOutput "1" "Failed to update SponsorBlock availability for video ID [${1}]"
    fi
fi

# Get the order of all items in that season
readarray -t seasonOrder < <(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${channelId//\'/\'\'}' AND YEAR = ${uploadYear} ORDER BY TIMESTAMP ASC;")

# Iterate through the season until our ID matches, so we know our position
vidIndex="1"
for z in "${seasonOrder[@]}"; do
    printOutput "5" "Determining index - Year [${uploadYear}] - Position [${vidIndex}] - Item [${z}]"
    if [[ "${z}" == "${1}" ]]; then
        break
    fi
    (( vidIndex++ ))
done
printOutput "5" "Found index position [${vidIndex}] from [${#seasonOrder[@]}] items"

# Make sure there isn't already something there
indexCheck="$(sqDb "SELECT COUNT(1) FROM source_videos WHERE CHANNEL_ID = '${channelId//\'/\'\'}' AND YEAR = ${uploadYear} AND EP_INDEX = ${vidIndex} AND ID != '${1//\'/\'\'}';")"

# Update the index number
if sqDb "UPDATE source_videos SET EP_INDEX = ${vidIndex}, UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated season index to position [${vidIndex}] for video ID [${1}]"
else
    printOutput "1" "Failed to update season index for video ID [${1}]"
fi

# If we had another item in our position, straighten out our indexes
if [[ "${indexCheck}" -ne "0" ]]; then
    # We're not going to find a watch status for the video we're processing in Plex, so let's assign it now as watched/unwatched based on our config
    # If it was to be marked watched, it already was. We only need to set this if we need to mark it was unwatched.
    if [[ "${markWatched}" == "true" ]]; then
        if [[ -z "${watchedArr["_${ytId}"]}" ]]; then
            watchedArr["_${ytId}"]="watched"
        else
            if [[ "${watchedArr["_${ytId}"]}" == "watched" ]]; then
                printOutput "5" "Video ID [${ytId}] already marked as [watched]"
            else
                printAngryWarning
                printOutput "2" "Attempted to overwrite video ID [${ytId}] watch status of [${watchedArr["_${ytId}"]}] with [watched]"
            fi
        fi
    elif [[ "${markWatched}" == "false" ]]; then
        if [[ -z "${watchedArr["_${ytId}"]}" ]]; then
            watchedArr["_${ytId}"]="unwatched"
        else
            if [[ "${watchedArr["_${ytId}"]}" == "unwatched" ]]; then
                printOutput "5" "Video ID [${ytId}] already marked as [unwatched]"
            else
                printAngryWarning
                printOutput "2" "Attempted to overwrite video ID [${ytId}] watch status of [${watchedArr["_${ytId}"]}] with [unwatched]"
            fi
        fi
    else
        badExit "17" "Impossible condition"
    fi
    # Update any misordered old index numbers
    printOutput "5" "Begining retroactive index check"
    readarray -t seasonOrder < <(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${channelId//\'/\'\'}' AND YEAR = ${uploadYear} ORDER BY TIMESTAMP ASC;")
    vidIndex="1"
    getSeasonWatched="0"
    for z in "${seasonOrder[@]}"; do
        foundIndex="$(sqDb "SELECT EP_INDEX FROM source_videos WHERE ID = '${z//\'/\'\'}';")"
        printOutput "5" "Checking video ID [${z}] - Expecting position [${vidIndex}] - Current position [${foundIndex}]"
        if [[ "${foundIndex}" -ne "${vidIndex}" ]]; then
            # Doesn't match, update it
            if sqDb "UPDATE source_videos SET EP_INDEX = ${vidIndex}, UPDATED = '$(date +%s)' WHERE ID = '${z}';"; then
                printOutput "5" "Retroactively updated season index from [${foundIndex}] to [${vidIndex}] for video ID [${z}]"
                # If the file has already been downloaded, we need to re-index it
                vidStatus="$(sqDb "SELECT STATUS FROM source_videos WHERE ID = '${z//\'/\'\'}';")"
                if [[ "${vidStatus}" == "downloaded" ]]; then
                    printOutput "5" "Marking video ID [${z}] for move due to re-index"
                    getSeasonWatched="1"
                    printOutput "5" "Getting watch status for video ID [${z}] prior to move"
                    # Add the affected files to our moveArr so we can move them
                    # Only do this if it's not set, as we could be re-indexing a video multiple times
                    if [[ -z "${reindexArr["_${z}"]}" ]]; then
                        tmpChannelPath="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
                        tmpChannelNameClean="$(sqDb "SELECT NAME_CLEAN FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
                        tmpVidYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${z//\'/\'\'}';")"
                        tmpVidTitleClean="$(sqDb "SELECT TITLE_CLEAN FROM source_videos WHERE ID = '${z//\'/\'\'}';")"
                        # Log the video ID as the key, and path we can find the old file at as the value
                        reindexArr["_${z}"]="${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${foundIndex}") - ${tmpVidTitleClean} [${z}].mp4"
                    fi
                fi
            else
                printOutput "1" "Failed to retroactively update season index for video ID [${z}]"
            fi
        fi
        (( vidIndex++ ))
    done
    
    if [[ "${getSeasonWatched}" -eq "1" ]]; then
        # We also need to record watch status for the whole rest of the season, or Plex is gonna fuck it up when we start moving files around
        while read -r tmpId; do
            # Record their watch status
            if ! getWatchStatus "${tmpId}"; then
                printOutput "1" "Failed to get watch status for video ID [${tmpId}]"
            fi
        done < <(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${channelId//\'/\'\'}' AND YEAR = ${tmpVidYear} AND STATUS = 'downloaded';")
    fi
fi
}

function ytApiCall {
if [[ -z "${1}" ]]; then
    printOutput "1" "No API endpoint passed for YouTube API call"
    return 1
fi
if [[ "${#ytApiKeys[@]}" -ne "0" ]]; then
    useLemnos="0"
    if [[ -z "${apiKeyNum}" ]]; then
        for apiKeyNum in "${!ytApiKeys[@]}"; do
            printOutput "3" "Using YouTube API key [${apiKeyNum}] [${ytApiKeys[${apiKeyNum}]}]"
            usedApiKeys+=("${ytApiKeys[${apiKeyNum}]}")
            costArr["videos_${ytApiKeys[${apiKeyNum}]}"]=0
            costArr["captions_${ytApiKeys[${apiKeyNum}]}"]=0
            costArr["channels_${ytApiKeys[${apiKeyNum}]}"]=0
            costArr["playlists_${ytApiKeys[${apiKeyNum}]}"]=0
            break
        done
        # We now are using the first key of our array
    fi
    # Use a YouTube API key, with no throttling
    callCurlGet "https://www.googleapis.com/youtube/v3/${1}&key=${ytApiKeys[${apiKeyNum}]}"
    # Check for a 400 or 403 error code
    errorCode="$(yq -p json ".error.code" <<<"${curlOutput}")"
    if [[ "${errorCode}" == "403" || "${errorCode}" == "400" ]]; then
        while [[ "${errorCode}" == "403" || "${errorCode}" == "400" ]]; do
            if [[ "${errorCode}" == "403" ]]; then
                printOutput "2" "API key [$(( apiKeyNum+ 1 ))] exhaused, rotating to next available key"
            elif [[ "${errorCode}" == "400" ]]; then
                printOutput "1" "API key [${ytApiKeys[${apiKeyNum}]}] appears to be invalid"
                printOutput "2" "Rotating to next available API key"
            fi
            
            # Shift to the next available API key
            unset ytApiKeys["${apiKeyNum}"]
            for apiKeyNum in "${!ytApiKeys[@]}"; do
                printOutput "3" "Using YouTube API key [$(( apiKeyNum + 1 ))]"
                usedApiKeys+=("${ytApiKeys[${apiKeyNum}]}")
                costArr["videos_${ytApiKeys[${apiKeyNum}]}"]=0
                costArr["captions_${ytApiKeys[${apiKeyNum}]}"]=0
                costArr["channels_${ytApiKeys[${apiKeyNum}]}"]=0
                costArr["playlists_${ytApiKeys[${apiKeyNum}]}"]=0
                break
            done
            
            if [[ "${#ytApiKeys[@]}" -ne "0"  ]]; then
                # Call curl again
                callCurlGet "https://www.googleapis.com/youtube/v3/${1}&key=${ytApiKeys[${apiKeyNum}]}"
                # Check for a 400 or 403 error code
                errorCode="$(yq -p json ".error.code" <<<"${curlOutput}")"
                if ! [[ "${errorCode}" == "403" || "${errorCode}" == "400" ]]; then
                    (( apiCallsYouTube++ ))
                    # Account for unit cost
                    if [[ "${1%%\?*}" == "videos" ]]; then
                        # Costs 5 units
                        totalUnits="$(( totalUnits + 5 ))"
                        totalVideoUnits="$(( totalVideoUnits + 5 ))"
                        costArr["videos_${ytApiKeys[${apiKeyNum}]}"]="$(( ${costArr["videos_${ytApiKeys[${apiKeyNum}]}"]} + 5 ))"
                    elif [[ "${1%%\?*}" == "captions" ]]; then
                        # Costs 50 units
                        totalUnits="$(( totalUnits + 50 ))"
                        totalCaptionsUnits="$(( totalCaptionsUnits + 50 ))"
                        costArr["captions_${ytApiKeys[${apiKeyNum}]}"]="$(( ${costArr["captions_${ytApiKeys[${apiKeyNum}]}"]} + 50 ))"
                    elif [[ "${1%%\?*}" == "channels" ]]; then
                        # Costs 8 units
                        totalUnits="$(( totalUnits + 8 ))"
                        totalChannelsUnits="$(( totalChannelsUnits + 8 ))"
                        costArr["channels_${ytApiKeys[${apiKeyNum}]}"]="$(( ${costArr["channels_${ytApiKeys[${apiKeyNum}]}"]} + 8 ))"
                    elif [[ "${1%%\?*}" == "playlists" ]]; then
                        # Costs 3 units
                        totalUnits="$(( totalUnits + 3 ))"
                        totalPlaylistsUnits="$(( totalPlaylistsUnits + 3 ))"
                        costArr["playlists_${ytApiKeys[${apiKeyNum}]}"]="$(( ${costArr["playlists_${ytApiKeys[${apiKeyNum}]}"]} + 3 ))"
                    fi
                fi
            else
                printOutput "1" "Exhaused available API keys, switching to LemnosLife"
                unset ytApiKeys
                useLemnos="1"
                break
            fi
        done
    else
        (( apiCallsYouTube++ ))
        # Account for unit cost
        if [[ "${1%%\?*}" == "videos" ]]; then
            # Costs 5 units
            totalUnits="$(( totalUnits + 5 ))"
            totalVideoUnits="$(( totalVideoUnits + 5 ))"
            costArr["videos_${ytApiKeys[${apiKeyNum}]}"]="$(( ${costArr["videos_${ytApiKeys[${apiKeyNum}]}"]} + 5 ))"
        elif [[ "${1%%\?*}" == "captions" ]]; then
            # Costs 50 units
            totalUnits="$(( totalUnits + 50 ))"
            totalCaptionsUnits="$(( totalCaptionsUnits + 50 ))"
            costArr["captions_${ytApiKeys[${apiKeyNum}]}"]="$(( ${costArr["captions_${ytApiKeys[${apiKeyNum}]}"]} + 50 ))"
        elif [[ "${1%%\?*}" == "channels" ]]; then
            # Costs 8 units
            totalUnits="$(( totalUnits + 8 ))"
            totalChannelsUnits="$(( totalChannelsUnits + 8 ))"
            costArr["channels_${ytApiKeys[${apiKeyNum}]}"]="$(( ${costArr["channels_${ytApiKeys[${apiKeyNum}]}"]} + 8 ))"
        elif [[ "${1%%\?*}" == "playlists" ]]; then
            # Costs 3 units
            totalUnits="$(( totalUnits + 3 ))"
            totalPlaylistsUnits="$(( totalPlaylistsUnits + 3 ))"
            costArr["playlists_${ytApiKeys[${apiKeyNum}]}"]="$(( ${costArr["playlists_${ytApiKeys[${apiKeyNum}]}"]} + 3 ))"
        fi
    fi
else
    useLemnos="1"
fi

if [[ "${useLemnos}" -eq "1" ]]; then
    # If our endpoint is 'captions', Lemnos can't call it
    if [[ "${1}" =~ ^captions\?.*$ ]]; then
        printOutput "1" "LemnosLife is unable to call the 'captions' API endpoint -- Skipping request for [${1}]"
        sleep 10
        return 1
    fi
    # Use the free/no-key lemnoslife API, and throttle ourselves out of courtesy
    callCurlGet "https://yt.lemnoslife.com/noKey/${1}" "goose's bash script - contact [github <at> goose <dot> ws] for any concerns or questions"
    (( apiCallsLemnos++ ))
    randomSleep "3" "7"
fi
}

function downloadSubs {
if [[ -z "${1}" ]]; then
    printOutput "1" "No video ID provided for subtitles"
    return 1
fi
# If we don't want any subtitles, don't bother looking them up
if [[ "${#subLanguages[@]}" -eq "0" ]]; then
    return 0
fi

# Get captions data from YouTube Data API v3 using ytApiCall
if ! ytApiCall "captions?part=snippet&videoId=${1}"; then
    printOutput "1" "Unable to call API for video ID [${1}] -- Skipping"
    return 1
fi

subStatus="$(sqDb "SELECT SQID FROM subtitle_versions WHERE ID = '${1//\'/\'\'}' AND LANG_CODE = 'No subs available';")"
if [[ "$(yq ".items | length" <<<"${curlOutput}")" -eq "0" ]]; then
    printOutput "3" "No subtitle tracks available for video ID [${1}]"
    # Update or insert subtitle version in the database
    if [[ -z "${subStatus}" ]]; then
        # Insert new subtitle version
        sqDb "INSERT INTO subtitle_versions (ID, LANG_CODE, UPDATED) VALUES ('${1//\'/\'\'}', 'No subs available', '${lastUpdated//\'/\'\'}');"
    else
        # Update existing subtitle version
        sqDb "UPDATE subtitle_versions SET UPDATED = '${lastUpdated//\'/\'\'}' WHERE ID = '${1//\'/\'\'}' AND LANG_CODE = 'No subs available';"
    fi
    return 0
elif [[ -n "${subStatus}" ]]; then
    # Remove the old record, we now have subs
    if sqDb "DELETE FROM playlist_order WHERE SQID = ${subStatus};"; then
        printOutput "5" "Removed stale record of no subtitles available for video ID [${1}]"
    else
        printOutput "1" "Failed to remove stale record with SQID [${subStatus}] of no subtitles available for video ID [${1}]"
    fi
fi

# Extract caption IDs and details using yq
readarray -t captionIds < <(yq eval '.items[].id' <<<"${curlOutput}")
readarray -t languages < <(yq eval '.items[].snippet.language' <<<"${curlOutput}")
readarray -t lastUpdates < <(yq eval '.items[].snippet.lastUpdated' <<< "${curlOutput}")

# Build our output path
# Get our video channel ID
local channelId
channelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${1//\'/\'\'}';")"
# Get our video year
local vidYear
vidYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${1//\'/\'\'}';")"
# Get our video index
local vidIndex
vidIndex="$(sqDb "SELECT EP_INDEX FROM source_videos WHERE ID = '${1//\'/\'\'}';")"
# Get our video clean title
local vidTitleClean
vidTitleClean="$(sqDb "SELECT TITLE_CLEAN FROM source_videos WHERE ID = '${1//\'/\'\'}';")"
# Get our channel path
local channelPath
channelPath="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
# Get our clean channel name
local channelNameClean
channelNameClean="$(sqDb "SELECT NAME_CLEAN FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"

# Array to keep track of downloaded languages
unset downloaded_langs
declare -A downloaded_langs

local capId
local langCode
local downloaded_langs
local subStatus
local lastUpdated
local vttData
local srtData
local subPath
local loopNum

# Loop through each caption ID
loopNum="0"
for i in "${!captionIds[@]}"; do
    (( loopNum++ ))
    capId="${captionIds[${i}]}"
    langCode="${languages[${i}]}"
    lastUpdated="${lastUpdates[${i}]}"

    isWanted="0"
    for wanted in "${subLanguages[@]}"; do
        if [[ "${langCode}" == "${wanted}" ]]; then
            isWanted="1"
            break
        fi
    done
    if [[ "${isWanted}" -eq "0" ]]; then
        printOutput "5" "Skipping unwanted language [${language}]"
        continue
    fi

    # Check if forced track is not available for the language
    if ! [[ "${langCode}" == "en.forced" ]]; then
        # Prefer standard over ASR
        if [[ "${trackKind}" == "standard" ]] || [[ ! "${downloaded_langs[${langCode}]}" == "standard" ]]; then
            langCode="${langCode}"
            downloaded_langs["${langCode}"]="standard" # Mark language as downloaded with standard track
        elif [[ "${trackKind}" == "ASR" ]] && [[ ! "${downloaded_langs[${langCode}]}" ]]; then
            langCode="${langCode}"
            downloaded_langs["${langCode}"]="ASR" # Mark language as downloaded with ASR track
        else
            continue # Skip this track if a preferred one is already downloaded
        fi
    fi
    
    # Check if subtitles already exist and if they need updating
    subStatus="$(sqDb "SELECT UPDATED FROM subtitle_versions WHERE ID = '${1//\'/\'\'}' AND LANG_CODE = '${langCode//\'/\'\'}';")"

    if [[ -z "${subStatus}" ]]; then
        # No existing subtitles, download them
        printOutput "4" "No existing [${langCode}] subtitles for video ID [${1}]"
    elif [[ "${subStatus}" == "${lastUpdated}" ]]; then
        # Subtitles are up-to-date, skip downloading
        printOutput "4" "Subtitles [${langCode}] for video ID [${1}] are up-to-date"
        continue
    else
        # Subtitles need updating, download them
        printOutput "3" "Subtitles [${langCode}] for video ID [${1}] have been updated"
    fi
    
    # Download the subtitle using yt-dlp
    if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
        readarray -t dlpOutput < <(yt-dlp --cookies "${cookieFile}" --sleep-requests 1.25 --no-warnings --write-subs --write-auto-subs --sub-langs "${langCode}" --skip-download -o "${tmpDir}/%(id)s.%(sub_lang)s.%(ext)s" "https://www.youtube.com/watch?v=${1}")
    else
        readarray -t dlpOutput < <(yt-dlp --sleep-requests 1.25 --no-warnings --write-subs --write-auto-subs --sub-langs "${langCode}" --skip-download -o "${tmpDir}/%(id)s.%(sub_lang)s.%(ext)s" "https://www.youtube.com/watch?v=${1}")
    fi
    
    # Rename to remove ".NA" if necessary
    if [[ -e "${tmpDir}/${1}.NA.${langCode}.vtt" ]]; then
        mv "${tmpDir}/${1}.NA.${langCode}.vtt" "${tmpDir}/${1}.${langCode}.vtt"
    fi

    # Convert VTT to SRT if needed
    if [[ -e "${tmpDir}/${1}.${langCode}.vtt" ]]; then
        readarray -t ffmpegOutput < <(ffmpeg -i "${tmpDir}/${1}.${langCode}.vtt" "${tmpDir}/${1}.${langCode}.srt" 2>&1)
        rm "${tmpDir}/${1}.${langCode}.vtt"
        if ! [[ -e "${tmpDir}/${1}.${langCode}.srt" ]]; then
            printOutput "1" "Failed to pull [${langCode}] subtitles for video ID [${1}]"
            for line in "${ffmpegOutput[@]}"; do
                printOutput "1" "  ${line}"
            done
            continue
        fi
    else
        if [[ "${dlpOutput[-1]}" == "[info] There are no subtitles for the requested languages" ]]; then
            # No subs available
            subStatus="$(sqDb "SELECT SQID FROM subtitle_versions WHERE ID = '${1//\'/\'\'}' AND LANG_CODE = 'No subs available';")"
            # Update or insert subtitle version in the database
            if [[ -z "${subStatus}" ]]; then
                # Insert new subtitle version
                sqDb "INSERT INTO subtitle_versions (ID, LANG_CODE, UPDATED) VALUES ('${1//\'/\'\'}', 'No subs available', '${lastUpdated//\'/\'\'}');"
            else
                # Update existing subtitle version
                sqDb "UPDATE subtitle_versions SET UPDATED = '${lastUpdated//\'/\'\'}' WHERE ID = '${1//\'/\'\'}' AND LANG_CODE = 'No subs available';"
            fi
            return 0
        else
            printOutput "1" "Failed to download any subtitle files for video ID [${1}]"
            for line in "${dlpOutput[@]}"; do
                printOutput "1" "  ${line}"
            done
        fi
        continue
    fi

    # Complete the output path
    subPath="${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].${langCode%-*}.srt"

    # Save the file
    mv "${tmpDir}/${1}.${langCode}.srt" "${subPath}"
    if [[ -e "${subPath}" ]]; then
        printOutput "3" "Wrote [${langCode}] subtitles for video ID [${1}]"
    else
        printOutput "1" "Failed to write [${langCode}] subtitles for video ID [${1}]"
        continue
    fi
    
    # Update or insert subtitle version in the database
    if [[ -z "${subStatus}" ]]; then
        # Insert new subtitle version
        sqDb "INSERT INTO subtitle_versions (ID, LANG_CODE, UPDATED) VALUES ('${1//\'/\'\'}', '${langCode//\'/\'\'}', '${lastUpdated//\'/\'\'}');"
    else
        # Update existing subtitle version
        sqDb "UPDATE subtitle_versions SET UPDATED = '${lastUpdated//\'/\'\'}' WHERE ID = '${1//\'/\'\'}' AND LANG_CODE = '${langCode//\'/\'\'}';"
    fi
    
    # Throttle yt-dlp, if necessary
    if [[ "${loopNum}" -ne "${#captionIds[@]}" ]]; then
        throttleDlp
    fi
done
}

function sponsorApiCall {
callCurlGet "https://sponsor.ajay.app/api/${1}" "goose's bash script - contact [github <at> goose <dot> ws] for any concerns or questions"
(( apiCallsSponsor++ ))
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

function makeShowImage {
# ${1} is ${channelId}

# Get the channel image
local dbReply
local channelPath
dbReply="$(sqDb "SELECT IMAGE FROM source_channels WHERE ID = '${1//\'/\'\'}';")"
channelPath="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${1//\'/\'\'}';")"
if [[ -n "${dbReply}" ]]; then
    # If the video directory does not exist, create it
    if ! [[ -d "${outputDir}/${channelPath}" ]]; then
        if ! mkdir -p "${outputDir}/${channelPath}"; then
            printOutput "1" "Failed to create output directory [${outputDir}/${channelPath}]"
            return 1
        fi
        newVideoDir+=("${channelId}")
    fi
fi

# If ${2} is a year, we're just creating a new season, don't need to pull/create all new images
if [[ "${2}" =~ ^[0-9]+$ ]]; then
    year="${2}"
    # Make sure we have a base show image to work with
    if ! [[ -e "${outputDir}/${channelPath}/show.jpg" ]]; then
        printOutput "1" "No show image found for channel ID [${1}]"
        return 1
    fi
    # Add the season folder, if required
    if ! [[ -d "${outputDir}/${channelPath}/Season ${year}" ]]; then
        if ! mkdir -p "${outputDir}/${channelPath}/Season ${year}"; then
            badExit "18" "Unable to create season folder [${outputDir}/${channelPath}/Season ${year}]"
        fi
    fi
    # Create the image
    if [[ -e "${outputDir}/${channelPath}/show.jpg" ]]; then
        # Get the height of the show image
        posterHeight="$(identify -format "%h" "${outputDir}/${channelPath}/show.jpg")"
        # We want 0.3 of the height, with no trailing decimal
        # We have to use 'awk' here, since bash doesn't like floating decimals
        textHeight="$(awk '{print $1 * $2}' <<<"${posterHeight} 0.3")"
        textHeight="${textHeight%\.*}"
        strokeHeight="$(awk '{print $1 * $2}' <<<"${textHeight} 0.03")"
        strokeHeight="${strokeHeight%\.*}"
        convert "${outputDir}/${channelPath}/show.jpg" -gravity Center -pointsize "${textHeight}" -fill white -stroke black -strokewidth "${strokeHeight}" -annotate 0 "${year}" "${outputDir}/${channelPath}/Season ${year}/Season${year}.jpg"
    else
        printOutput "1" "Unable to generate season poster for channel ID [${1}] season [${year}]"
    fi
    return 0
fi

if [[ -e "${outputDir}/${channelPath}/show.jpg" ]]; then
    printOutput "5" "Existing show image found, downloading new version to compare"
    callCurlDownload "${dbReply}" "${tmpDir}/${1}.jpg"
    if cmp -s "${outputDir}/${channelPath}/show.jpg" "${tmpDir}/${1}.jpg"; then
        printOutput "5" "No changes detected, removing newly downloaded show image file"
        if ! rm -f "${tmpDir}/${1}.jpg"; then
            printOutput "1" "Failed to remove newly downloaded show image file for channel ID [${1}]"
        fi
    else
        printOutput "4" "New show image detected, backing up old show image and replacing with new one"
        if ! mv "${outputDir}/${channelPath}/show.jpg" "${outputDir}/${channelPath}/.show.bak-$(date +%s).jpg"; then
            printOutput "1" "Failed to back up previously downloaded show image file for channel ID [${1}]"
        fi
        if ! mv "${tmpDir}/${1}.jpg" "${outputDir}/${channelPath}/show.jpg"; then
            printOutput "1" "Failed to move newly downloaded show image file for channel ID [${1}]"
        fi
        # Get a list of seasons for the series
        readarray -t seasonYears < <(sqDb "SELECT DISTINCT YEAR FROM source_videos WHERE CHANNEL_ID = '${1//\'/\'\'}' AND STATUS = 'downloaded';")
        # Create the season images
        for year in "${seasonYears[@]}"; do
            # Make sure we have a base show image to work with
            if ! [[ -e "${outputDir}/${channelPath}/show.jpg" ]]; then
                printOutput "1" "No show image found for channel ID [${1}]"
                return 1
            fi
            # Add the season folder, if required
            if ! [[ -d "${outputDir}/${channelPath}/Season ${year}" ]]; then
                if ! mkdir -p "${outputDir}/${channelPath}/Season ${year}"; then
                    badExit "19" "Unable to create season folder [${outputDir}/${channelPath}/Season ${year}]"
                fi
            fi
            # Create the image
            if [[ -e "${outputDir}/${channelPath}/show.jpg" ]]; then
                # Get the height of the show image
                posterHeight="$(identify -format "%h" "${outputDir}/${channelPath}/show.jpg")"
                # We want 0.3 of the height, with no trailing decimal
                # We have to use 'awk' here, since bash doesn't like floating decimals
                textHeight="$(awk '{print $1 * $2}' <<<"${posterHeight} 0.3")"
                textHeight="${textHeight%\.*}"
                strokeHeight="$(awk '{print $1 * $2}' <<<"${textHeight} 0.03")"
                strokeHeight="${strokeHeight%\.*}"
                convert "${outputDir}/${channelPath}/show.jpg" -gravity Center -pointsize "${textHeight}" -fill white -stroke black -strokewidth "${strokeHeight}" -annotate 0 "${year}" "${outputDir}/${channelPath}/Season ${year}/Season${year}.jpg"
            else
                printOutput "1" "Unable to generate season poster for channel ID [${1}] season [${year}]"
            fi
        done
    fi
else
    callCurlDownload "${dbReply}" "${outputDir}/${channelPath}/show.jpg"
    printOutput "5" "Show image created for channel directory [${channelPath}]"
fi

# Get the background image, if one exists
dbReply="$(sqDb "SELECT BANNER FROM source_channels WHERE ID = '${1//\'/\'\'}';")"
if [[ -n "${dbReply}" ]]; then    
    if [[ -e "${outputDir}/${channelPath}/background.jpg" ]]; then
        printOutput "5" "Existing background image found, downloading new version to compare"
        callCurlDownload "${dbReply}" "${tmpDir}/${1}.jpg"
        if cmp -s "${outputDir}/${channelPath}/background.jpg" "${tmpDir}/${1}.jpg"; then
            printOutput "5" "No changes detected, removing newly downloaded background image file"
            if ! rm -f "${tmpDir}/${1}.jpg"; then
                printOutput "1" "Failed to remove newly downloaded background image file for channel ID [${1}]"
            fi
        else
            printOutput "4" "New background image detected, backing up old image and replacing with new one"
            if ! mv "${outputDir}/${channelPath}/background.jpg" "${outputDir}/${channelPath}/.background.bak-$(date +%s).jpg"; then
                printOutput "1" "Failed to back up previously downloaded background image file for channel ID [${1}]"
            fi
            if ! mv "${tmpDir}/${1}.jpg" "${outputDir}/${channelPath}/background.jpg"; then
                printOutput "1" "Failed to move newly downloaded background image file for channel ID [${1}]"
            fi
        fi
    else
        callCurlDownload "${dbReply}" "${outputDir}/${channelPath}/background.jpg"
        printOutput "5" "Background image created for channel directory [${channelPath}]"
    fi
fi
}

function channelToDb {
# Get the channel info from the YouTube API
unset chanName chanNameClean chanDate chanEpochDate chanSubs chanCountry chanUrl chanVids chanViews chanDesc chanPathClean chanImage chanBanner

# API call
printOutput "5" "Calling API for channel info [${1}]"
ytApiCall "channels?id=${1}&part=snippet,statistics,brandingSettings"
apiResults="$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")"

# Validate it
if [[ -z "${apiResults}" ]]; then
    printOutput "1" "No data provided to validate integer"
    return 1
elif [[ "${apiResults}" =~ ^[0-9]+$ ]]; then
    # Expected outcome
    true
elif ! [[ "${apiResults}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Data [${apiResults}] failed to validate as an integer"
    return 1
else
    badExit "20" "Impossible condition"
fi

if [[ "${apiResults}" -eq "0" ]]; then
    printOutput "1" "API lookup for channel info returned zero results -- Skipping"
    return 1
fi

# Get the channel name
chanName="$(yq -p json ".items[0].snippet.title" <<<"${curlOutput}")"
# Validate it
if [[ -z "${chanName}" ]]; then
    printOutput "1" "No channel name returned from API lookup for channel ID [${1}] -- Skipping"
    return 1
fi
printOutput "5" "Channel name [${chanName}]"

# Store the clean channel name for our directory name
chanNameClean="${chanName}"
# Trim any leading spaces and/or periods
while [[ "${chanNameClean:0:1}" =~ ^( |\.)$ ]]; do
    chanNameClean="${chanNameClean# }"
    chanNameClean="${chanNameClean#\.}"
done
# Trim any trailing spaces and/or periods
while [[ "${chanNameClean:$(( ${#chanNameClean} - 1 )):1}" =~ ^( |\.)$ ]]; do
    chanNameClean="${chanNameClean% }"
    chanNameClean="${chanNameClean%\.}"
done
# Replace any forward or back slashes \ /
chanNameClean="${chanNameClean//\//_}"
chanNameClean="${chanNameClean//\\/_}"
# Replace any colons :
chanNameClean="${chanNameClean//:/}"
# Replace any stars *
chanNameClean="${chanNameClean//\*/}"
# Replace any question marks ?
chanNameClean="${chanNameClean//\?/}"
# Replace any quotation marks "
chanNameClean="${chanNameClean//\"/}"
# Replace any brackets < >
chanNameClean="${chanNameClean//</}"
chanNameClean="${chanNameClean//>/}"
# Replace any vertical bars |
chanNameClean="${chanNameClean//\|/}"
# Condense any instances of '_-_'
while [[ "${chanNameClean}" =~ .*"_-_".* ]]; do
    chanNameClean="${chanNameClean//_-_/ - }"
done
# Condense any multiple spaces
while [[ "${chanNameClean}" =~ .*"  ".* ]]; do
    chanNameClean="${chanNameClean//  / }"
done
if [[ -z "${chanNameClean}" ]]; then
    printOutput "1" "Channel clean name returned blank result [${vidTitle}]"
    return 1
fi
printOutput "5" "Channel clean name [${chanNameClean}]"

# Get the channel creation date
chanDate="$(yq -p json ".items[0].snippet.publishedAt" <<<"${curlOutput}")"
# Convert the date to a Unix timestamp
chanEpochDate="$(date --date="${chanDate}" "+%s")"
if ! [[ "${chanEpochDate}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Unable to convert creation date to unix epoch timestamp [${chanDate}][${chanEpochDate}] for channel ID [${1}] -- Skipping"
    return 1
fi
printOutput "5" "Channel creation date [${chanDate}] with epoch date [${chanEpochDate}]"

# Get the channel sub count
chanSubs="$(yq -p json ".items[0].statistics.subscriberCount" <<<"${curlOutput}")"
if [[ "${chanSubs}" == "null" ]]; then
    chanSubs="0"
elif ! [[ "${chanSubs}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid subscriber count returned [${chanSubs}] for channel ID [${1}] -- Skipping"
    return 1
fi
if [[ "${chanSubs}" -ge "1000" ]]; then
    chanSubs="$(printf "%'d" "${chanSubs}")"
fi
printOutput "5" "Channel sub count [${chanSubs}]"

# Get the channel country
chanCountry="$(yq -p json ".items[0].snippet.country" <<<"${curlOutput}")"
if [[ "${chanCountry}" == "null" ]]; then
    chanCountry="an unknown country"
else
    # Safety check is done within this function
    if ! getChannelCountry "${chanCountry}"; then
        printOutput "1" "Unknown country code [${chanCountry}] for channel ID [${1}] -- Skipping";
        return 1
    fi
fi
printOutput "5" "Channel country [${chanCountry}]"

# Get the channel custom URL
chanUrl="$(yq -p json ".items[0].snippet.customUrl" <<<"${curlOutput}")"
if [[ -z "${chanUrl}" ]]; then
    ### SKIP CONDITION
    printOutput "1" "No custom URL returned for channel ID [${1}] -- Skipping"
    return 1
fi
chanUrl="https://www.youtube.com/${chanUrl}"
printOutput "5" "Channel custom URL [${chanUrl}]"

# Get the channel video count
chanVids="$(yq -p json ".items[0].statistics.videoCount" <<<"${curlOutput}")"
if [[ "${chanVids}" == "null" ]]; then
    chanVids="0"
elif ! [[ "${chanVids}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid video count returned [${chanVids}] for channel ID [${1}] -- Skipping"
    return 1
fi
if [[ "${chanVids}" -ge "1000" ]]; then
    chanVids="$(printf "%'d" "${chanVids}")"
fi
printOutput "5" "Channel video count [${chanVids}]"

# Get the channel view count
chanViews="$(yq -p json ".items[0].statistics.viewCount" <<<"${curlOutput}")"
if [[ "${chanViews}" == "null" ]]; then
    chanViews="0"
elif ! [[ "${chanViews}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid view count returned [${chanViews}] for channel ID [${1}] -- Skipping"
    return 1
fi
if [[ "${chanViews}" -ge "1000" ]]; then
    chanViews="$(printf "%'d" "${chanViews}")"
fi
printOutput "5" "Channel view count [${chanViews}]"

# Get the channel description
chanDesc="$(yq -p json ".items[0].snippet.description" <<<"${curlOutput}")"
if [[ -z "${chanDesc}" || "${chanDesc}" == "null" ]]; then
    # No channel description set
    printOutput "5" "No channel description set"
    chanDesc="${chanUrl}${lineBreak}${chanSubs} subscribers${lineBreak}${chanVids} videos${lineBreak}${chanViews} views${lineBreak}Joined YouTube $(date --date="@${chanEpochDate}" "+%b. %d, %Y")${lineBreak}Based in ${chanCountry}${lineBreak}Channel ID: ${1}${lineBreak}Channel description and statistics last updated $(date)"
else
    printOutput "5" "Channel description found [${#chanDesc} characters]"
    chanDesc="${chanDesc}${lineBreak}-----${lineBreak}${chanUrl}${lineBreak}${chanSubs} subscribers${lineBreak}${chanVids} videos${lineBreak}${chanViews} views${lineBreak}Joined YouTube $(date --date="@${chanEpochDate}" "+%b. %d, %Y")${lineBreak}Based in ${chanCountry}${lineBreak}Channel ID: ${1}${lineBreak}Channel description and statistics last updated $(date)"
fi

# Define our video path
chanPathClean="${chanNameClean} [${1}]"
printOutput "5" "Channel output path [${chanPathClean}]"

# Extract the URL for the channel image, if one exists
chanImage="$(yq -p json ".items[0].snippet.thumbnails | to_entries | sort_by(.value.height) | reverse | .0 | .value.url" <<<"${curlOutput}")"
printOutput "5" "Channel image URL [${chanImage}]"

# Extract the URL for the channel background, if one exists
chanBanner="$(yq -p json ".items[0].brandingSettings.image.bannerExternalUrl" <<<"${curlOutput}")"
# If we have a banner, crop it correctly
if [[ -n "${chanBanner}" && ! "${chanBanner}" == "null" ]]; then
    chanBanner="${chanBanner}=w2560-fcrop64=1,00005a57ffffa5a8-k-c0xffffffff-no-nd-rj"
    printOutput "5" "No channel banner set"
else
    unset chanBanner
    printOutput "5" "Channel banner found"
fi

dbCount="$(sqDb "SELECT COUNT(1) FROM source_channels WHERE ID = '${1//\'/\'\'}';")"
if [[ "${dbCount}" -eq "0" ]]; then
    # Insert it into the database
    if sqDb "INSERT INTO source_channels (ID, UPDATED) VALUES ('${1//\'/\'\'}', $(date +%s));"; then
        printOutput "3" "Added channel ID [${1}] to database"
    else
        badExit "21" "Adding channel ID [${1}] to database failed"
    fi
elif [[ "${dbCount}" -eq "1" ]]; then
    # Exists as a safety check
    true
else
    # PANIC
    badExit "22" "Multiple matches found for channel ID [${1}] -- Possible database corruption"
fi

# Set the channel name
if sqDb "UPDATE source_channels SET NAME = '${chanName//\'/\'\'}', UPDATED = $(date +%s) WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated channel name [${chanName}] for channel ID [${1}] in database"
else
    badExit "23" "Updating channel name [${chanName}] for channel ID [${1}] in database failed"
fi


# Set the channel clean name
if sqDb "UPDATE source_channels SET NAME_CLEAN = '${chanNameClean//\'/\'\'}', UPDATED = $(date +%s) WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated channel clean name [${chanNameClean}] for channel ID [${1}] in database"
else
    badExit "24" "Updating channel clean name [${chanNameClean}] for channel ID [${1}] in database failed"
fi

# Set the timestamp
if sqDb "UPDATE source_channels SET TIMESTAMP = ${chanEpochDate}, UPDATED = $(date +%s) WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated timestamp [${chanEpochDate}] for channel ID [${1}] in database"
else
    badExit "25" "Updating timestamp [${chanEpochDate}] for channel ID [${1}] in database failed"
fi

# Set the subscriber count
if sqDb "UPDATE source_channels SET SUB_COUNT = ${chanSubs//,/}, UPDATED = $(date +%s) WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated subscriber count [${chanSubs}] for channel ID [${1}] in database"
else
    badExit "26" "Updating subscriber count [${chanSubs}] for channel ID [${1}] in database failed"
fi

# Set the channel country
if sqDb "UPDATE source_channels SET COUNTRY = '${chanCountry//\'/\'\'}', UPDATED = $(date +%s) WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated country [${chanCountry}] for channel ID [${1}] in database"
else
    badExit "27" "Updating country [${chanCountry}] for channel ID [${1}] in database failed"
fi

# Set the channel URL
if sqDb "UPDATE source_channels SET URL = '${chanUrl//\'/\'\'}', UPDATED = $(date +%s) WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated URL [${chanUrl}] for channel ID [${1}] in database"
else
    badExit "28" "Updating URL [${chanUrl}] for channel ID [${1}] in database failed"
fi

# Set the video count
if sqDb "UPDATE source_channels SET VID_COUNT = ${chanVids//,/}, UPDATED = $(date +%s) WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated video count [${chanVids}] for channel ID [${1}] in database"
else
    badExit "29" "Updating video count [${chanVids}] for channel ID [${1}] in database failed"
fi

# Set the view count
if sqDb "UPDATE source_channels SET VIEW_COUNT = ${chanViews//,/}, UPDATED = $(date +%s) WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated view count [${chanViews}] for channel ID [${1}] in database"
else
    badExit "30" "Updating view count [${chanViews}] for channel ID [${1}] in database failed"
fi

# Set the channel description
if sqDb "UPDATE source_channels SET DESC = '${chanDesc//\'/\'\'}', UPDATED = $(date +%s) WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated channel description [${#chanDesc} characters] for channel ID [${1}] in database"
else
    badExit "31" "Updating channel description [${#chanDesc} characters] for channel ID [${1}] in database failed"
fi

# Set the channel path
if sqDb "UPDATE source_channels SET PATH = '${chanPathClean//\'/\'\'}', UPDATED = $(date +%s) WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated channel path [${chanPathClean}] for channel ID [${1}] in database"
else
    badExit "32" "Updating channel path [${chanPathClean}] for channel ID [${1}] in database failed"
fi

# Set the channel image
if sqDb "UPDATE source_channels SET IMAGE = '${chanImage//\'/\'\'}', UPDATED = $(date +%s) WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated channel image [${chanImage}] for channel ID [${1}] in database"
else
    badExit "33" "Updating channel image [${chanImage}] for channel ID [${1}] in database failed"
fi

# If we have a channel banner, add that
if [[ -n "${chanBanner}" && ! "${chanBanner}" == "null" ]]; then
    if sqDb "UPDATE source_channels SET BANNER = '${chanBanner}' WHERE ID = '${1//\'/\'\'}';"; then
        printOutput "5" "Appended channel banner to database entry for channel ID [${1}]"
    else
        badExit "34" "Unable to append channel banner to database entry for channel ID [${1}]"
    fi
fi
}

function getPlaylistInfo {
# Playlist ID should be passed as ${1}
unset plVis plTitle plDesc plImage
# Get the necessary information
ytApiCall "playlists?id=${1}&part=id,snippet"
apiResults="$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")"
# Validate it
if [[ -z "${apiResults}" ]]; then
    printOutput "1" "No data provided to validate integer"
    return 1
elif [[ "${apiResults}" =~ ^[0-9]+$ ]]; then
    # Expected outcome
    true
elif ! [[ "${apiResults}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Data [${apiResults}] failed to validate as an integer"
    return 1
else
    badExit "35" "Impossible condition"
fi

if [[ "${apiResults}" -eq "0" ]]; then
    printOutput "2" "API lookup for playlist parsing returned zero results (Is the playlist private?)"

    if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
        printOutput "3" "Re-attempting playlist lookup via yt-dlp + cookie"
        dlpApiCall="$(yt-dlp --no-warnings -J --playlist-items 0 --cookies "${cookieFile}" "https://www.youtube.com/playlist?list=${1}" 2>/dev/null)"
        
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
    badExit "36" "Impossible condition"
fi

if [[ -z "${plTitle}" ]]; then
    printOutput "1" "Unable to find title for playlist [${1}]"
    return 1
fi
if [[ -z "${plImage}" ]]; then
    printOutput "1" "Unable to find image for playlist [${1}]"
    return 1
fi

# Returns variables:
# plVis
# plTitle
# plDesc (May be blank)
# plImage
}

function playlistToDb {
# Pass the playlist ID as ${1}
# Get the playlist info
if ! getPlaylistInfo "${1}"; then
    printOutput "1" "Failed to retrieve playlist info for [${1}] -- Skipping source"
    return 1
fi
# Do we already know of this playlist?
dbCount="$(sqDb "SELECT COUNT(1) FROM source_playlists WHERE ID = '${1//\'/\'\'}';")"
if [[ "${dbCount}" -eq "0" ]]; then
    # Nope. Add it to the database.
    if sqDb "INSERT INTO source_playlists (ID, UPDATED) VALUES ('${1//\'/\'\'}', $(date +%s));"; then
        printOutput "3" "Added playlist ID [${1}] to database"
    else
        badExit "37" "Failed to add playlist ID [${1}] to database"
    fi
elif [[ "${dbCount}" -eq "1" ]]; then
    # Safety check
    true
else
    badExit "38" "Counted [${dbCount}] instances of playlist ID [${1}] in database -- Possible database corruption"
fi

# Update the visibility
if sqDb "UPDATE source_playlists SET VISIBILITY = '${plVis//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated visibility for playlist ID [${1}]"
else
    printOutput "1" "Failed to update visibility for playlist ID [${1}]"
fi

# Update the title
if sqDb "UPDATE source_playlists SET TITLE = '${plTitle//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated title for playlist ID [${1}]"
else
    printOutput "1" "Failed to update title for playlist ID [${1}]"
fi

# Update the title
if [[ -n "${plDesc}" ]]; then
    if sqDb "UPDATE source_playlists SET DESC = '${plDesc//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
        printOutput "5" "Updated description for playlist ID [${1}]"
    else
        printOutput "1" "Failed to description title for playlist ID [${1}]"
    fi 
fi

# Update the image
if sqDb "UPDATE source_playlists SET IMAGE = '${plImage//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated image for playlist ID [${1}]"
else
    printOutput "1" "Failed to update image for playlist ID [${1}]"
fi
}

function verifyChannelName {
# Channel ID is ${1}
# Retrieved channel name is ${2}
# Is it already marked as safe?
if [[ -z "${verifiedArr["${1}"]}" ]]; then
    # No we have not
    # Have we previously indexed this channel?
    dbCount="$(sqDb "SELECT COUNT(1) FROM source_channels WHERE ID = '${1//\'/\'\'}';")"
    if [[ "${dbCount}" -eq "0" ]]; then
        # Safety check
        verifiedArr["${1}"]="true"
    elif [[ "${dbCount}" -eq "1" ]]; then
        dbChanName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${1//\'/\'\'}';")"
        if [[ "${2}" == "${dbChanName}" ]]; then
            printOutput "5" "Verified channel name is unchanged"
        else
            printOutput "1" "Channel ID [${1}] appears to have changed channel names from [${dbChanName}] to [${2}] -- Updating existing source"
            
            # Get a list of our affected (currently downloaded items)
            unset moveArr
            declare -A moveArr
            while read -r tmpId; do
                # Record their watch status
                if ! getWatchStatus "${tmpId}"; then
                    printOutput "1" "Failed to get watch status for video ID [${tmpId}]"
                fi
                # Get the existing channelPath, vidYear, channelNameClean, vidIndex, vidTitleClean
                tmpChannelPath="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${1//\'/\'\'}';")"
                tmpChannelNameClean="$(sqDb "SELECT NAME_CLEAN FROM source_channels WHERE ID = '${1//\'/\'\'}';")"
                tmpVidYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${tmpId//\'/\'\'}';")"
                tmpVidIndex="$(sqDb "SELECT EP_INDEX FROM source_videos WHERE ID = '${tmpId//\'/\'\'}';")"
                tmpVidTitleClean="$(sqDb "SELECT TITLE_CLEAN FROM source_videos WHERE ID = '${tmpId//\'/\'\'}';")"
                # Add the affected files to our moveArr so we can move them
                if [[ -e "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].mp4" ]]; then
                    moveArr["_${tmpId}"]="Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].mp4"
                else
                    printOutput "1" "Video ID [${tmpId}] is marked as downloaded, but does not appear to exist on file system at expected path [${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].mp4]"
                fi
            done < <(sqDb "SELECT id FROM source_videos WHERE CHANNEL_ID = '${1//\'/\'\'}' AND STATUS = 'downloaded';")
            
            # Now update the channel information in the database
            channelToDb "${1}"
            
            # We're good to move our files
            # Get our new channel path
            channelPath="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${1//\'/\'\'}';")"
            # Move our base directory
            # Move the video and thumbail of each video in the base directory
            # Check if the base channel directory exists
            if [[ -d "${outputDir}/${channelPath}" ]]; then
                badExit "39" "Directory [${outputDir}/${channelPath}] already exists, unable to update [${outputDir}/${tmpChannelPath}]"
            else
                # Move it
                if ! mv "${outputDir}/${tmpChannelPath}" "${outputDir}/${channelPath}"; then
                    badExit "40" "Failed to move old directory [${outputDir}/${tmpChannelPath}] to new directory [${outputDir}/${channelPath}]"
                fi
                # Create the series image - This will also re-create season images if needed
                makeShowImage "${1}"
            fi
            
            # Move the individual videos, and their thumbnails
            for tmpId in "${!moveArr[@]}"; do
                tmpId="${tmpId#_}"
                tmpChannelPath="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${1//\'/\'\'}';")"
                tmpChannelName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${1//\'/\'\'}';")"
                tmpChannelNameClean="$(sqDb "SELECT NAME_CLEAN FROM source_channels WHERE ID = '${1//\'/\'\'}';")"
                tmpVidYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${tmpId//\'/\'\'}';")"
                tmpVidIndex="$(sqDb "SELECT EP_INDEX FROM source_videos WHERE ID = '${tmpId//\'/\'\'}';")"
                tmpVidTitle="$(sqDb "SELECT TITLE FROM source_videos WHERE ID = '${tmpId//\'/\'\'}';")"
                tmpVidTitleClean="$(sqDb "SELECT TITLE_CLEAN FROM source_videos WHERE ID = '${tmpId//\'/\'\'}';")"
                # Check to see if the season folder exists
                if ! [[ -d "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}" ]]; then
                    # Create it
                    if ! mkdir -p "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}"; then
                        badExit "41" "Unable to create directory [${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}]"
                    fi
                fi
                
                # Move our file
                if ! mv "${outputDir}/${tmpChannelPath}/${moveArr[_${tmpId}]}" "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].mp4"; then
                    printOutput "1" "Failed to move video ID [${tmpId}] to destination [${tmpChannelPath}/Season ${tmpVidYear}]"
                fi
                
                # If we have a thumbnail
                if [[ -e "${outputDir}/${tmpChannelPath}/${moveArr[_${tmpId}]%mp4}jpg" ]]; then
                    # Move it
                    if ! mv "${outputDir}/${tmpChannelPath}/${moveArr[_${tmpId}]%mp4}jpg" "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].jpg"; then
                        printOutput "1" "Failed to move thumbnail for video ID [${tmpId}] to destination [${tmpChannelPath}/Season ${tmpVidYear}]"
                    fi
                fi
                if ! [[ -e "${outputDir}/${tmpChannelPath}/${moveArr[_${tmpId}]%mp4}jpg" ]]; then
                    # Still don't have one, so get it from web
                    printOutput "5" "Pulling thumbail from web"
                    callCurlDownload "https://img.youtube.com/vi/${tmpId}/maxresdefault.jpg" "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].jpg"
                    if ! [[ -e "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].jpg" ]]; then
                        printOutput "1" "Failed to get thumbnail for video ID [${tmpId}]"
                    fi
                fi

                if [[ -e "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].mp4" ]]; then
                    printOutput "3" "Imported video [${tmpChannelName} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitle}]"
                else
                    printOutput "1" "Failed to import [${tmpChannelName} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitle}]"
                fi
            done
            
            # Get the rating key of the old series
            seriesRatingKey="$(sqDb "SELECT RATING_KEY FROM rating_key WHERE ID = '${1//\'/\'\'}';")"
            
            # Remove the old series
            callCurlDelete "${plexAdd}/library/metadata/${seriesRatingKey}?&X-Plex-Token=${plexToken}"
            
            # Issue a library refresh
            refreshSleep="$(( ${#moveArr[@]} * 3 ))"
            if [[ "${refreshSleep}" -lt "30" ]]; then
                refreshSleep="30"
            elif [[ "${refreshSleep}" -gt "300" ]]; then
                refreshSleep="300"
            fi
            refreshLibrary "${libraryId}"
            printOutput "3" "Sleeping for [${refreshSleep}] seconds to give the Plex Scanner time to work"
            sleep "${refreshSleep}"

            # Search the PMS library for the rating key of the series
            # This will also save the rating key to the database (Set series rating key)
            setSeriesRatingKey "${1}"
            # We now have ${showRatingKey} set
            
            # Update the series metadata
            setSeriesMetadata "${showRatingKey}"
            
            # Fix the watch status for the series
            for tmpId in "${!moveArr[@]}"; do
                if ! setWatchStatus "${tmpId#_}"; then
                    printOutput "1" "Unable to update watch status for video ID [${tmpId#_}]"
                fi
            done
            
            # Move on with life
        fi
        verifiedArr["${1}"]="true"
    else
        badExit "42" "Counted [${dbCount}] instances of channel ID [${1}] -- Possible database corruption"
    fi
fi
}

function defineTitle {
if [[ -z "${titleArr[_${1}]}" ]]; then
    # Get the channel ID of our video ID
    local channelId
    channelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${1//\'/\'\'}';")"
    if [[ -z "${channelId}" ]]; then
        printOutput "1" "Unable to retrieve channel ID for video ID [${1}] -- Possible database corruption"
        return 1
    fi
    # Define our title
    local tmpChan
    local tmpYear
    local tmpIndex
    local tmpTitle
    tmpChan="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
    tmpYear=$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${1//\'/\'\'}';")
    tmpIndex=$(sqDb "SELECT EP_INDEX FROM source_videos WHERE ID = '${1//\'/\'\'}';")
    tmpIndex="$(printf '%03d' "${tmpIndex}")"
    tmpTitle=$(sqDb "SELECT TITLE FROM source_videos WHERE ID = '${1//\'/\'\'}';")
    titleArr["_${1}"]="${tmpChan} - S${tmpYear}E${tmpIndex} - ${tmpTitle}"
fi
}

## Plex functions
function refreshLibrary {
# Issue a "Scan Library" command -- The desired library ID must be passed as ${1}
if [[ -z "${1}" ]]; then
    badExit "43" "No library ID passed to be scanned"
fi
printOutput "3" "Issuing a 'Scan Library' command to Plex for library ID [${1}]"
callCurlGet "${plexAdd}/library/sections/${1}/refresh?X-Plex-Token=${plexToken}"
}

function setSeriesRatingKey {
lookupTime="$(($(date +%s%N)/1000000))"
# Channel ID should be passed as ${1}
if [[ -z "${1}" ]]; then
    badExit "44" "No channel ID passed for series rating key update"
fi
chanName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${1//\'/\'\'}';")"
printOutput "3" "Retrieving rating key from Plex for show [${chanName}] with channel ID [${1}]"
# Can we take the easy way out? Try to match the series by name
lookupMatch="0"
# Get a list of all the series in the video library
callCurlGet "${plexAdd}/library/sections/${libraryId}/all?X-Plex-Token=${plexToken}"

# Load the rating keys into an associative array, with the show title as the key and the rating key as the value
unset ratingKeyArr
declare -A ratingKeyArr
while read -r ratingKey seriesTitle; do
    printOutput "5" "Assigning value [${ratingKey}] for key [${seriesTitle,,}]"
    ratingKeyArr["${seriesTitle,,}"]="${ratingKey}"
done < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | (.\"+@ratingKey\" + \" \" + .\"+@title\")" <<<"${curlOutput}")

# See if we can flatly match any of these via ${chanName}
if [[ -n "${ratingKeyArr[${chanName,,}]}" ]]; then
    showRatingKey="${ratingKeyArr[${chanName,,}]}"
    # We could!
    printOutput "4" "Located series rating key [${showRatingKey}] via most efficient lookup method [Took $(timeDiff "${lookupTime}")]"
    dbCount="$(sqDb "SELECT COUNT(1) FROM rating_key WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
    if [[ "${dbCount}" -eq "0" ]]; then
        # Doesn't exist, insert it
        if sqDb "INSERT INTO rating_key (CHANNEL_ID, RATING_KEY, UPDATED) VALUES ('${1//\'/\'\'}', ${showRatingKey}, $(date +%s));"; then
            printOutput "5" "Added rating key [${showRatingKey}] for channel ID [${1}] to database"
        else
            badExit "45" "Added series rating key [${showRatingKey}] to database failed"
        fi
    elif [[ "${dbCount}" -eq "1" ]]; then
        # Exists, update it
        if ! sqDb "UPDATE rating_key SET RATING_KEY = '${showRatingKey}', UPDATED = $(date +%s) WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
            badExit "46" "Failed to update series rating key [${showRatingKey}] for channel ID [${channelId}]"
        fi
    else
        badExit "47" "Database count for series rating key [${showRatingKey}] in rating_key table returned unexpected output [${dbCount}] -- Possible database corruption"
    fi
    lookupMatch="1"
else
    # We could not
    # Best way would be the first episode of the first season of the channel ID in question
    firstEpisode="$(sqDb "SELECT ID FROM source_videos WHERE CHANNEL_ID = '${1//\'/\'\'}' ORDER BY TIMESTAMP ASC LIMIT 1;")"
    # Having the year would help as we can skip series which do not have the first year season we want
    firstYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${firstEpisode}';")"
    # To do this, we need to find a matching episode by YT ID in Plex
    # The "lazy" way to do this is to only compare items which have the same first character as our channel name
    
    chanNameLower="${chanName,,}"
    for seriesTitle in "${!ratingKeyArr[@]}"; do
        # If the first letter matches
        if [[ "${seriesTitle:0:1}" == "${chanNameLower:0:1}" ]]; then
            # See if we have a matching year for that series
            showRatingKey="${ratingKeyArr[${seriesTitle}]}"
            if [[ -z "${showRatingKey}" ]]; then
                printOutput "1" "No data provided to validate integer"
                return 1
            elif [[ "${showRatingKey}" =~ ^[0-9]+$ ]]; then
                # Expected outcome
                true
            elif ! [[ "${showRatingKey}" =~ ^[0-9]+$ ]]; then
                printOutput "1" "Data [${showRatingKey}] failed to validate as an integer"
                return 1
            else
                badExit "48" "Impossible condition"
            fi
            
            # Get the rating key of a season that matches our video year
            callCurlGet "${plexAdd}/library/metadata/${showRatingKey}/children?X-Plex-Token=${plexToken}"
            seasonRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@index\" == \"${firstYear}\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -z "${seasonRatingKey}" ]]; then
                printOutput "4" "No matching season with year [${firstYear}] found for series [${seriesTitle}] via series rating key [${showRatingKey}], skipping series"
                # We can unset this as we know it's not what we're looking for, and removing it now will make any inefficient search slightly more efficient
                unset ratingKeyArr["${seriesTitle}"]
                continue
            elif [[ "${seasonRatingKey}" =~ ^[0-9]+$ ]]; then
                # Expected outcome
                true
            elif ! [[ "${seasonRatingKey}" =~ ^[0-9]+$ ]]; then
                printOutput "1" "Data [${seasonRatingKey}] failed to validate as an integer"
                return 1
            else
                badExit "49" "Impossible condition"
            fi
            
            if [[ -n "${seasonRatingKey}" ]]; then
                # Get the episode list for the season
                callCurlGet "${plexAdd}/library/metadata/${seasonRatingKey}/children?X-Plex-Token=${plexToken}"
                # Get the YT ID from the file path of the first episode of the first season
                firstEpisodeId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                firstEpisodeId="${firstEpisodeId%\]\.*}"
                firstEpisodeId="${firstEpisodeId##*\[}"
                if [[ -z "${firstEpisodeId}" ]]; then
                    badExit "50" "Failed to isolate ID for first episode of [${plexTitleArr[${z}]}] season [${firstYear}] -- Incorrect file name scheme?"
                fi
                # We have now extracted the ID of the first episode of the first season. Compare it to ours, and hope for a match.
                if [[ "${firstEpisodeId}" == "${firstEpisode}" ]]; then
                    # We've matched!
                    printOutput "4" "Located series rating key [${showRatingKey}] via semi-efficient lookup method [Took $(timeDiff "${lookupTime}")]"

                    # Add the series rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM rating_key WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Doesn't exist, insert it
                        if sqDb "INSERT INTO rating_key (CHANNEL_ID, RATING_KEY, UPDATED) VALUES ('${1//\'/\'\'}', ${showRatingKey}, $(date +%s));"; then
                            printOutput "5" "Added rating key [${showRatingKey}] for channel ID [${1}] to database"
                        else
                            badExit "51" "Added series rating key [${showRatingKey}] to database failed"
                        fi
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # Exists, update it
                        if ! sqDb "UPDATE rating_key SET RATING_KEY = '${showRatingKey}', UPDATED = $(date +%s) WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
                            badExit "52" "Failed to update series rating key [${showRatingKey}] for channel ID [${channelId}]"
                        fi
                    else
                        badExit "53" "Database count for series rating key [${showRatingKey}] in rating_key table returned unexpected output [${dbCount}] -- Possible database corruption"
                    fi
                    lookupMatch="1"

                    # Break the loop
                    break
                else
                    printOutput "4" "No matching episode with video ID [${firstEpisode}] detected for series rating key [${showRatingKey}] with season rating key [${seasonRatingKey}]"
                    # We can unset this as we know it's not what we're looking for, and removing it now will make any inefficient search slightly more efficient
                    unset ratingKeyArr["${seriesTitle}"]
                fi
            fi
        fi
    done

    # If we've gotten this far, and not matched anything, we should do an inefficient search with the leftover titles from the ratingKeyArr[@]
    if [[ "${lookupMatch}" -eq "0" ]]; then
        for showRatingKey in "${ratingKeyArr[@]}"; do
            # Get the rating key of a season that matches our video year
            callCurlGet "${plexAdd}/library/metadata/${showRatingKey}/children?X-Plex-Token=${plexToken}"
            seasonRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@index\" == \"${firstYear}\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -n "${seasonRatingKey}" ]]; then
                printOutput "5" "Retrieved season rating key [${seasonRatingKey}]"
                callCurlGet "${plexAdd}/library/metadata/${seasonRatingKey}/children?X-Plex-Token=${plexToken}"
                # Get the YT ID from the file path of the first episode of the first season
                firstEpisodeId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                firstEpisodeId="${firstEpisodeId%\]\.*}"
                firstEpisodeId="${firstEpisodeId##*\[}"
                # We have now extracted the ID of the first episode of the first season. Compare it to ours, and pray for a match.
                if [[ "${firstEpisodeId}" == "${firstEpisode}" ]]; then
                    printOutput "4" "Located series rating key [${showRatingKey}] via least efficient lookup method [Took $(timeDiff "${lookupTime}")]"

                    # Add the series rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM rating_key WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Doesn't exist, insert it
                        if sqDb "INSERT INTO rating_key (CHANNEL_ID, RATING_KEY, UPDATED) VALUES ('${1//\'/\'\'}', ${showRatingKey}, $(date +%s));"; then
                            printOutput "5" "Added rating key [${showRatingKey}] for channel ID [${1}] to database"
                        else
                            badExit "54" "Added series rating key [${showRatingKey}] to database failed"
                        fi
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # Exists, update it
                        if ! sqDb "UPDATE rating_key SET RATING_KEY = '${showRatingKey}', UPDATED = $(date +%s) WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
                            badExit "55" "Failed to update series rating key [${showRatingKey}] for channel ID [${channelId}]"
                        fi
                    else
                        badExit "56" "Database count for series rating key [${showRatingKey}] in rating_key table returned unexpected output [${dbCount}] -- Possible database corruption"
                    fi
                    lookupMatch="1"
                    
                    # Break the loop
                    break
                fi
            else
                printOutput "5" "No seasons matching year [${firstYear}] found for series rating key [${showRatingKey}] -- Skipping series"
            fi
        done
    fi

    if [[ "${lookupMatch}" -eq "0" ]]; then
        printOutput "1" "Unable to locate rating key for series [${chanName}] -- Is Plex aware of the series?"
        return 1
    fi
fi
}

function setSeriesMetadata {
printOutput "3" "Setting series metadata for rating key [${1}]"

# Get the channel ID from the rating key
channelId="$(sqDb "SELECT CHANNEL_ID FROM rating_key WHERE RATING_KEY = ${1};")"

# Get the channel name
showName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${channelId}';")"
if [[ -z "${showName}" ]]; then
    printOutput "1" "Unable to retrieve series name for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi
# Encode it
showNameEncoded="$(rawUrlEncode "${showName}")"
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
showDescEncoded="$(rawUrlEncode "${showDesc}")"
if [[ -z "${showDescEncoded}" ]]; then
    printOutput "1" "Unable to encode series description for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi

# Get the channel creation date
showCreation="$(sqDb "SELECT TIMESTAMP FROM source_channels WHERE ID = '${channelId}';")"
# Validate it
if [[ -z "${showCreation}" ]]; then
    printOutput "1" "No data provided to validate integer"
    return 1
elif [[ "${showCreation}" =~ ^[0-9]+$ ]]; then
    # Expected outcome
    true
elif ! [[ "${showCreation}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Data [${showCreation}] failed to validate as an integer"
    return 1
else
    badExit "57" "Impossible condition"
fi
# Convert it to YYYY-MM-DD
showCreation="$(date --date="@${showCreation}" "+%Y-%m-%d")"

if callCurlPut "${plexAdd}/library/sections/${libraryId}/all?type=2&id=${1}&includeExternalMedia=1&title.value=${showNameEncoded}&titleSort.value=${showNameEncoded}&summary.value=${showDescEncoded}&studio.value=YouTube&originallyAvailableAt.value=${showCreation}&title.locked=1&titleSort.locked=1&originallyAvailableAt.locked=1&studio.locked=1&summary.locked=1&X-Plex-Token=${plexToken}"; then
    printOutput "4" "Metadata for series [${showName}] sucessfully updated"
else
    printOutput "1" "Metadata for series [${showName}] failed"
fi
}

function setWatchStatus {
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass a video ID to update the watch status for"
    return 1
fi

# Get its rating key
if ! getFileRatingKey "${1}"; then
    printOutput "1" "Failed to retrieve rating key for video ID [${1}]"
    return 1
fi

printOutput "3" "Correcting watch status for video ID [${1}]" 
if [[ "${watchedArr[_${1}]}" == "watched" ]]; then
    # Issue the call to mark the item as watched
    printOutput "4" "Marking video ID [${1}] as watched"
    if callCurlGet "${plexAdd}/:/scrobble?identifier=com.plexapp.plugins.library&key=${ratingKey}&X-Plex-Token=${plexToken}"; then
        printOutput "5" "Successfully marked video ID [${1}] as watched"
        unset watchedArr["_${1}"]
    else
        printOutput "1" "Failed to mark video ID [${1}] as watched via rating key [${ratingKey}]"
    fi
elif [[ "${watchedArr[_${1}]}" == "unwatched" ]]; then
    # Issue the call to mark the item as unwatched
    printOutput "4" "Marking video ID [${1}] as unwatched"
    if callCurlGet "${plexAdd}/:/unscrobble?identifier=com.plexapp.plugins.library&key=${ratingKey}&X-Plex-Token=${plexToken}"; then
        printOutput "5" "Successfully marked video ID [${1}] as unwatched"
        unset watchedArr["_${1}"]
    else
        printOutput "1" "Failed to mark video ID [${1}] as unwatched via rating key [${ratingKey}]"
    fi
elif [[ "${watchedArr[_${1}]}" =~ ^[0-9]+$ ]]; then
    # Issue the call to mark the item as partially watched
    printOutput "4" "Marking video ID [${1}] as partially watched watched [$(msToTime "${watchedArr[_${1}]}")]"
    if callCurlPut "${plexAdd}/:/progress?key=${ratingKey}&identifier=com.plexapp.plugins.library&time=${watchedArr[_${1}]}&state=stopped&X-Plex-Token=${plexToken}"; then
        printOutput "5" "Successfully marked video ID [${1}] as partially watched [$(msToTime "${watchedArr[_${1}]}")]"
        unset watchedArr["_${1}"]
    else
        printOutput "1" "Failed to mark video ID [${1}] as partially watched [${watchedArr[_${1}]}|$(msToTime "${watchedArr[_${1}]}")] via rating key [${ratingKey}]"
    fi
else
    badExit "58" "Unexpected watch status for [${1}]: ${watchedArr[_${1}]}"
fi
}

function getFileRatingKey {
local lookupTime
lookupTime="$(($(date +%s%N)/1000000))"
# Video ID should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass video ID to getFileRatingKey function"
    return 1
elif [[ -n "${rkArr[_${1}]}" ]]; then
    ratingKey="${rkArr[_${1}]}"
    return 0
fi

# Get the channel ID of our video ID
local channelId
channelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${1//\'/\'\'}';")"
if [[ -z "${channelId}" ]]; then
    printOutput "1" "Unable to retrieve channel ID for video ID [${1}] -- Possible database corruption"
    return 1
fi

defineTitle "${1}"

# Get the rating key for this series
local showRatingKey
showRatingKey="$(sqDb "SELECT RATING_KEY FROM rating_key WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
if [[ -z "${showRatingKey}" ]]; then
    if ! setSeriesRatingKey "${channelId}"; then
        printOutput "1" "Failed to set series rating key for channel ID [${channelId}]"
        return 1
    fi
    # If we've gotten this far, we still have ${showRatingKey} defined from the setSeriesRatingKey function
fi

# Get the year for the video ID
local vidYear
vidYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${1//\'/\'\'}';")"
if [[ -z "${vidYear}" ]]; then
    badExit "59" "Failed to retrieve year for video ID [${1}] -- Possible database corruption"
fi

# Get the rating key for the season matching the year
callCurlGet "${plexAdd}/library/metadata/${showRatingKey}/children?X-Plex-Token=${plexToken}"
seasonRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@index\" == \"${vidYear}\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
if [[ -z "${seasonRatingKey}" ]]; then
    printOutput "1" "No matching season with year [${vidYear}] found for channel ID [${channelId}]"
    return 1
elif [[ "${seasonRatingKey}" =~ ^[0-9]+$ ]]; then
    # Expected outcome
    true
elif ! [[ "${seasonRatingKey}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Data [${seasonRatingKey}] failed to validate as an integer"
    return 1
else
    badExit "60" "Impossible condition"
fi

# Get the episode list for the season
callCurlGet "${plexAdd}/library/metadata/${seasonRatingKey}/children?X-Plex-Token=${plexToken}"

while read -r ratingKey fileId; do
    fileId="${fileId%\]\.*}"
    fileId="${fileId##*\[}"
    if [[ -z "${fileId}" ]]; then
        printOutput "1" "Failed to isolate video ID for item rating key [${ratingKey}] of season rating key [${seasonRatingKey}]"
        return 1
    fi
    if [[ "${fileId}" == "${1}" ]]; then
        # We've matched!
        printOutput "4" "Located episode rating key [${ratingKey}] for video ID [${1}] [Took $(timeDiff "${lookupTime}")]"

        # Save it
        rkArr["_${1}"]="${ratingKey}"
        
        # Break the loop
        break
    fi
done < <(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | (.\"+@ratingKey\" + \" \" + .Media.Part.\"+@file\")" <<<"${curlOutput}")
}

function getWatchStatus {
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass video ID to getWatchStatus function"
    return 1
fi
if [[ -n "${watchedArr[_${1}]}" ]]; then
    printOutput "5" "Watch status for video ID [${1}] already defined as [${watchedArr[_${1}]}]"
    return 0
fi
if ! getFileRatingKey "${1}"; then
    printOutput "1" "Failed to retrieve rating key for video ID [${1}]"
fi
# We now have the file's rating key assigned as ${ratingKey}
# Now, get the file's watch status from Plex
callCurlGet "${plexAdd}/library/metadata/${ratingKey}?X-Plex-Token=${plexToken}"
watchStatus="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .\"+@viewOffset\"" <<<"${curlOutput}")"
if [[ "${watchStatus}" =~ ^[0-9]+$ ]]; then
    # It's in progress
    printOutput "4" "Detected video ID [${1}] as in-progress with view offset [${watchStatus}]"
    if [[ -z "${watchedArr["_${1}"]}" ]]; then
        watchedArr["_${1}"]="${watchStatus}"
    else
        if [[ "${watchedArr["_${1}"]}" == "${watchStatus}" ]]; then
            printOutput "5" "Video ID [${1}] already marked as [${watchStatus}]"
        else
            printAngryWarning
            printOutput "2" "Attempted to overwrite video ID [${1}] watch status of [${watchedArr["_${1}"]}] with [${watchStatus}]"
        fi
    fi
else
    # Not in progress, we need to check the view count
    watchStatus="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .\"+@viewCount\"" <<<"${curlOutput}")"
    if [[ "${watchStatus}" == "null" ]]; then
        # It's unwatched
        printOutput "4" "Detected video ID [${1}] as unwatched"
        if [[ -z "${watchedArr["_${1}"]}" ]]; then
            watchedArr["_${1}"]="unwatched"
        else
            if [[ "${watchedArr["_${1}"]}" == "unwatched" ]]; then
                printOutput "5" "Video ID [${1}] already marked as [unwatched]"
            else
                printAngryWarning
                printOutput "2" "Attempted to overwrite video ID [${1}] watch status of [${watchedArr["_${1}"]}] with [unwatched]"
            fi
        fi
    else
        # It's watched
        printOutput "4" "Detected video ID [${1}] as watched"
        if [[ -z "${watchedArr["_${1}"]}" ]]; then
            watchedArr["_${1}"]="watched"
        else
            if [[ "${watchedArr["_${1}"]}" == "watched" ]]; then
                printOutput "5" "Video ID [${1}] already marked as [watched]"
            else
                printAngryWarning
                printOutput "2" "Attempted to overwrite video ID [${1}] watch status of [${watchedArr["_${1}"]}] with [watched]"
            fi
        fi
    fi
fi
if [[ -z "${watchedArr[_${1}]}" ]]; then
    printOutput "1" "Unable to detect watch status for video ID [${1}]"
    return 1
fi
# We should now have watchedArr[_${ytId}] defined as 'watched', 'unwatched', or a numerical viewing offset (in progress)
}

function collectionGetOrder {
# Collection rating key should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a collection rating key please"
    return 1
fi

printOutput "5" "Obtaining order of items in collection from Plex"
unset plexCollectionOrder
# Start our indexing from one, it makes it easier for my smooth brain to debug playlist positioning
plexCollectionOrder[0]="null"
callCurlGet "${plexAdd}/library/collections/${1}/children?X-Plex-Token=${plexToken}"
while read -r ii; do
    if [[ -z "${ii}" || "${ii}" == "null" ]]; then
        printOutput "1" "No items in collection"
        return 1
    fi
    ii="${ii%\]\.*}"
    ii="${ii##*\[}"
    plexCollectionOrder+=("${ii}")
done < <(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .Media.Part.\"+@file\"" <<<"${curlOutput}")
unset plexCollectionOrder[0]
for ii in "${!plexCollectionOrder[@]}"; do
    printOutput "5" " plexCollectionOrder | ${ii} => ${plexCollectionOrder[${ii}]} [${titleArr[_${plexCollectionOrder[${ii}]}]}]"
done
}

function collectionVerifyMove {
# Collection rating key should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a collection rating key please"
    return 1
fi
# Video ID should be passed as ${2}
if [[ -z "${2}" ]]; then
    printOutput "1" "Pass me a video ID please"
    return 1
fi

# Get the order of items in the collection
printOutput "5" "Verifying order of items in collection from Plex"
unset plexVerifyOrder
# Start our indexing from one, it makes it easier for my smooth brain to debug playlist positioning
plexVerifyOrder[0]="null"
callCurlGet "${plexAdd}/library/collections/${1}/children?X-Plex-Token=${plexToken}"
while read -r ii; do
    if [[ -z "${ii}" || "${ii}" == "null" ]]; then
        printOutput "1" "No items in collection"
        return 1
    fi
    ii="${ii%\]\.*}"
    ii="${ii##*\[}"
    plexVerifyOrder+=("${ii}")
done < <(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .Media.Part.\"+@file\"" <<<"${curlOutput}")
unset plexVerifyOrder[0]

# Check and see if our video ID is in the correct position
local pos
for pos in "${!plexVerifyOrder[@]}"; do
    if [[ "${plexVerifyOrder[${pos}]}" == "${2}" ]]; then
        # ${pos} is where we are in the playlist
        # Get the video ID of the file we follow, unless we're position 1
        if [[ "${pos}" -eq "1" ]]; then
            printOutput "5" "Video ID [${2}] is at the start of the collection"
            break
        else
            posFollow="${plexVerifyOrder[$(( pos - 1 ))]}"
            # The video ID we are following is now ${posFollow}
            # Find the position that this video ID should be in, compared to the proper ordering
            local correctPos
            for correctPos in "${!plVidList[@]}"; do
                if [[ "${plVidList[${correctPos}]}" == "${2}" ]]; then
                    # ${correctPos} is where we should be in the playlist
                    # Get the video ID of the file we should be following
                    correctPosFollow="${plVidList[$(( correctPos - 1 ))]}"
                    # Check and see if we're following the correct video ID
                    if [[ "${posFollow}" == "${correctPosFollow}" ]]; then
                        printOutput "5" "SORT VERIFY - Video ID [${2}] is correctly following [${correctPosFollow}] in position [${pos}]"
                    else
                        printOutput "4" "SORT VERIFY - Video ID [${2}] is incorrectly following [${posFollow}] in position [${pos}], should be behind [${correctPosFollow}] in position [${correctPos}]"
                    fi
                    break 2
                fi
            done
        fi
    fi
done
}

function collectionSort {
# Collection rating key should be passed as ${1}

printOutput "3" "Checking for items to be re-ordered in collection"

# Get the order of the collection from Plex
# This assigns the ${plexCollectionOrder[@]} array
collectionGetOrder "${1}"

# Make sure that both our Plex array and our Playlist array have matching elements
local id_1
local id_2
for id_1 in "${plexCollectionOrder[@]}"; do
    for id_2 in "${plVidList[@]}"; do
        if [[ "${id_1}" == "${id_2}" ]]; then
            printOutput "5" "Verified video ID [${id_1}] present in both arrays on first check"
            continue 2
        fi
    done
    # If we've gotten this far, we failed to match
    printOutput "1" "Failed to verify video ID [${id_1}] in plVidList array"
    return 1
done
for id_1 in "${plVidList[@]}"; do
    for id_2 in "${plexCollectionOrder[@]}"; do
        if [[ "${id_1}" == "${id_2}" ]]; then
            printOutput "5" "Verified video ID [${id_1}] present in both arrays on second check"
            continue 2
        fi
    done
    # If we've gotten this far, we failed to match
    printOutput "1" "Failed to verify video ID [${id_1}] in plexCollectionOrder array"
    return 1
done

# For each item in the playlist array
miscount="0"
for ii in "${!plVidList[@]}"; do
    # ii = position integer [starts from 1]
    # plVidList[${ii}] = video ID
    printOutput "5" "Checking position [${ii}] with video ID [${plVidList[${ii}]}][${titleArr[_${plVidList[${ii}]}]}]"
    
    # If the Plex array position matches
    if [[ "${plVidList[${ii}]}" == "${plexCollectionOrder[${ii}]}" ]]; then
        # We're good
        printOutput "5" "Verified video ID [${plVidList[${ii}]}] in correct position"
    else
        # Plex has something else where this video ID should be
        (( miscount++ ))
        printOutput "5" "Video ID [${plVidList[${ii}]}] not found in position [${ii}] - Found video ID [${plexCollectionOrder[${ii}]}]"
        # Are we the first item in the collection?
        if [[ "${ii}" -eq "1" ]]; then
            # Yes. Move it to position 1.
            getFileRatingKey "${plVidList[${ii}]}"
            urlRatingKey="${ratingKey}"
            printOutput "4" "Moving video ID [${plVidList[${ii}]}][${titleArr[_${plVidList[1]}]}] to position 1"
            printOutput "5" "Moving rating key [${ratingKey}] to position 1"
            callCurlPut "${plexAdd}/library/collections/${1}/items/${urlRatingKey}/move?type=2&X-Plex-Token=${plexToken}"
        else
            # No, find the video ID that should come before.
            correctPos="$(( ii - 1 ))"
            # Get the rating key of the file we're dealing with
            getFileRatingKey "${plVidList[${ii}]}"
            urlRatingKey="${ratingKey}"
            # Get the rating key of the file it should come after
            getFileRatingKey "${plVidList[${correctPos}]}"
            urlRatingKeyAfter="${ratingKey}"
            
            printOutput "4" "Moving video ID [${plVidList[${ii}]}][${titleArr[_${plVidList[${ii}]}]}] after video ID [${plVidList[${correctPos}]}][${titleArr[_${plVidList[${correctPos}]}]}]"
            printOutput "5" "Moving rating key [${urlRatingKey}][${plVidList[${ii}]}] after rating key [${urlRatingKeyAfter}][${plVidList[${correctPos}]}]"
            
            # Move it
            callCurlPut "${plexAdd}/library/collections/${1}/items/${urlRatingKey}/move?type=2&after=${urlRatingKeyAfter}&X-Plex-Token=${plexToken}"
        fi
        
        # Get a new collection order
        collectionGetOrder "${1}"
    fi
done

if [[ "${miscount}" -eq "0" ]]; then
    printOutput "3" "Verified [${#plVidList[@]}] files to be in correct positions"
else
    printOutput "2" "Found [${miscount}] misplaced files of [${#plVidList[@]}] total files"
fi
}

function collectionAdd {
# Collection rating key should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a collection rating key please"
    return 1
fi

collectionGetOrder "${1}"

printOutput "3" "Checking for items to be added to collection"
# For each index from the database
for ii in "${plVidList[@]}"; do
    # ii = video ID
    needNewOrder="0"
    inPlaylist="0"
    # For each video in the collection
    for iii in "${plexCollectionOrder[@]}"; do
        # iii = video ID
        if [[ "${ii}" == "${iii}" ]]; then
            inPlaylist="1"
            break
        fi
    done
    if [[ "${inPlaylist}" -eq "0" ]]; then
        # This is the file we want to add
        getFileRatingKey "${ii}"
        urlRatingKey="${ratingKey}"
        needNewOrder="1"
        callCurlPut "${plexAdd}/library/collections/${1}/items?uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${urlRatingKey}&X-Plex-Token=${plexToken}"
        printOutput "3" "Added video ID [${ii}] to collection [${1}]"
    fi
    if [[ "${needNewOrder}" -eq "1" ]]; then
        collectionGetOrder "${1}"
    fi
done
}

function collectionDelete {
# Collection rating key should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a collection rating key please"
    return 1
fi

collectionGetOrder "${1}"

printOutput "3" "Checking for items to be removed from collection"
for ii in "${plexCollectionOrder[@]}"; do
    # ii = video ID
    needNewOrder="0"
    inDbPlaylist="0"
    for iii in "${plVidList[@]}"; do
        if [[ "${ii}" == "${iii}" ]]; then
            inDbPlaylist="1"
            break
        fi
    done
    if [[ "${inDbPlaylist}" -eq "0" ]]; then
        # This is the file we want to remove
        getFileRatingKey "${ii}"
        urlRatingKey="${ratingKey}"
        needNewOrder="1"
        callCurlDelete "${plexAdd}/library/collections/${1}/children/${urlRatingKey}?excludeAllLeaves=1&X-Plex-Token=${plexToken}"
        printOutput "3" "Removed video ID [${ii}] from collection [${1}]"
    fi
done
if [[ "${needNewOrder}" -eq "1" ]]; then
    collectionGetOrder "${1}"
fi
}

function collectionUpdate {
# ${plId} is ${1}
# ${collectionRatingKey} is ${2}
collectionDesc="$(sqDb "SELECT DESC FROM source_playlists WHERE ID = '${1//\'/\'\'}';")"
if [[ -z "${collectionDesc}" || "${collectionDesc}" == "null" ]]; then
    # No playlist description set
    collectionDesc="https://www.youtube.com/playlist?list=${1}${lineBreak}Playlist last updated $(date)"
else
    collectionDesc="${collectionDesc}${lineBreak}-----${lineBreak}https://www.youtube.com/playlist?list=${1}${lineBreak}Playlist last updated $(date)"
fi
collectionDescEncoded="$(rawUrlEncode "${collectionDesc}")"
if callCurlPut "${plexAdd}/library/sections/${libraryId}/all?type=18&id=${2}&includeExternalMedia=1&summary.value=${collectionDescEncoded}&summary.locked=1&X-Plex-Token=${plexToken}"; then
    printOutput "5" "Updated description for collection ID [${1}]"
else
    printOutput "1" "Failed to update description for collection ID [${1}]"
fi

# Update the image
collectionImg="$(sqDb "SELECT IMAGE FROM source_playlists WHERE ID = '${1//\'/\'\'}';")"
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
fi

printOutput "5" "Obtaining order of items for playlist [${1}] from Plex"
unset plexPlaylistOrder
# Start our indexing from one, it makes it easier for my smooth brain to debug playlist positioning
plexPlaylistOrder[0]="null"
callCurlGet "${plexAdd}/playlists/${1}/items?X-Plex-Token=${plexToken}"
while read -r ii; do
    if [[ -z "${ii}" || "${ii}" == "null" ]]; then
        printOutput "1" "No items in playlist"
        return 1
    fi
    ii="${ii%\]\.*}"
    ii="${ii##*\[}"
    printOutput "5" "Found [${ii}] in position [${#plexPlaylistOrder[@]}]"
    plexPlaylistOrder+=("${ii}")
done < <(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .Media.Part.\"+@file\"" <<<"${curlOutput}")
unset plexPlaylistOrder[0]
for ii in "${!plexPlaylistOrder[@]}"; do
    printOutput "5" " plexPlaylistOrder | ${ii} => ${plexPlaylistOrder[${ii}]}"
done
}

function playlistSort {
# Playlist rating key should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a playlist rating key please"
    return 1
fi

playlistGetOrder "${1}"

printOutput "3" "Checking for items to be re-ordered for playlist"

for ii in "${!plexPlaylistOrder[@]}"; do
    # ii = position integer [starts from 1]
    # plexPlaylistOrder[${ii}] = video ID
    
    needNewOrder="0"
    if [[ "${ii}" -eq "1" ]]; then
        if ! [[ "${plexPlaylistOrder[1]}" == "${plVidList[1]}" ]]; then
            printOutput "4" "Moving video ID [${plVidList[1]}] to position 1"
            getFileRatingKey "${plVidList[1]}"
            callCurlGet "${plexAdd}/playlists/${1}/items?X-Plex-Token=${plexToken}"
            playlistItemId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${ratingKey}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
            printOutput "5" "Item RK [${ratingKey}] | Item PLID [${playlistItemId}]"
            callCurlPut "${plexAdd}/library/playlists/${1}/items/${playlistItemId}/move?X-Plex-Token=${plexToken}"
            needNewOrder="1"
        fi
    elif [[ "${ii}" -ge "1" ]]; then
        if ! [[ "${plexPlaylistOrder[${ii}]}" == "${plVidList[${ii}]}" ]]; then
            # The file in position ${plexPlaylistOrder[${ii}]} does not match what it should be [${plVidList[${ii}]}]
            for correctPos in "${!plVidList[@]}"; do
                if [[ "${plexPlaylistOrder[${ii}]}" == "${plVidList[${correctPos}]}" ]]; then
                    # Correct 'after' is -1 from our current position ${correctPos}
                    (( correctPos-- ))
                    break
                fi
            done
            
                # This is the file we want to move
                getFileRatingKey "${plexPlaylistOrder[${ii}]}"
                ratingKeyItem="${ratingKey}"
                callCurlGet "${plexAdd}/playlists/${1}/items?X-Plex-Token=${plexToken}"
                playlistItemId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${ratingKeyItem}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
                # This is the file it should come after
                getFileRatingKey "${plVidList[${correctPos}]}"
                callCurlGet "${plexAdd}/playlists/${1}/items?X-Plex-Token=${plexToken}"
                playlistItemIdAfter="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${ratingKey}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
                printOutput "5" "Item RK [${ratingKeyItem}] | Item PLID [${playlistItemId}] | Item pos [${ii}] | After RK [${ratingKey}] | After PLID [${playlistItemIdAfter}] | After pos [${correctPos}]"
            
            printOutput "4" "File ID [${plexPlaylistOrder[${ii}]}] misplaced in position [${ii}], moving to position [$(( correctPos + 1 ))]"
            
            # Move it
            callCurlPut "${plexAdd}/playlists/${1}/items/${playlistItemId}/move?after=${playlistItemIdAfter}&X-Plex-Token=${plexToken}"
            needNewOrder="1"
        fi
    else
        badExit "61" "Impossible condition"
    fi
    
    if [[ "${needNewOrder}" -eq "1" ]]; then
        playlistGetOrder "${1}"
    fi
done
}

function playlistAdd {
# Playlist rating key should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a playlist rating key please"
    return 1
fi

playlistGetOrder "${1}"

printOutput "3" "Checking for items to be added to playlist"
# For each index from the database
for ii in "${plVidList[@]}"; do
    # ii = video ID
    needNewOrder="0"
    inPlaylist="0"
    # For each video in the playlist
    for iii in "${plexPlaylistOrder[@]}"; do
        # iii = video ID
        if [[ "${ii}" == "${iii}" ]]; then
            inPlaylist="1"
            break
        fi
    done
    if [[ "${inPlaylist}" -eq "0" ]]; then
            # This is the file we want to add
        getFileRatingKey "${ii}"
        needNewOrder="1"
        callCurlPut "${plexAdd}/playlists/${1}/items?uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${ratingKey}&X-Plex-Token=${plexToken}"
        printOutput "3" "Added video ID [${ii}][${titleById[_${ii}]}] to playlist [${1}]"
    fi
    if [[ "${needNewOrder}" -eq "1" ]]; then
        playlistGetOrder "${1}"
    fi
done
}

function playlistDelete {
# Playlist rating key should be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "Pass me a playlist rating key please"
    return 1
fi

playlistGetOrder "${1}"

printOutput "3" "Checking for items to be removed from playlist"
for ii in "${plexPlaylistOrder[@]}"; do
    printOutput "5" "Checking Plex item [${ii}]"
    # ii = video ID
    needNewOrder="0"
    inDbPlaylist="0"
    for iii in "${plVidList[@]}"; do
        printOutput "5" "Comparing against DB item [${iii}]"
        if [[ "${ii}" == "${iii}" ]]; then
            # It's supposed to be in the playlist
            inDbPlaylist="1"
            break
        fi
    done
    if [[ "${inDbPlaylist}" -eq "0" ]]; then
        # This is the file we want to remove
        getFileRatingKey "${ii}"
        callCurlGet "${plexAdd}/playlists/${1}/items?X-Plex-Token=${plexToken}"
        playlistItemId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${ratingKey}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
        needNewOrder="1"
        callCurlDelete "${plexAdd}/playlists/${1}/items/${playlistItemId}?X-Plex-Token=${plexToken}"
        printOutput "3" "Removed video ID [${ii}] from playlist [${1}] [${titleById[_${ii}]}]"
    fi
done
if [[ "${needNewOrder}" -eq "1" ]]; then
    playlistGetOrder "${1}"
fi
}

function playlistUpdate {
# ${plId} is ${1}
# ${playlistRatingKey} is ${2}
# Update the description
playlistDesc="$(sqDb "SELECT DESC FROM source_playlists WHERE ID = '${1//\'/\'\'}';")"
if [[ -z "${playlistDesc}" || "${playlistDesc}" == "null" ]]; then
    # No playlist description set
    playlistDesc="https://www.youtube.com/playlist?list=${1}${lineBreak}Playlist last updated $(date)"
else
    playlistDesc="${playlistDesc}${lineBreak}-----${lineBreak}https://www.youtube.com/playlist?list=${1}${lineBreak}Playlist last updated $(date)"
fi
playlistDescEncoded="$(rawUrlEncode "${playlistDesc}")"
if callCurlPut "${plexAdd}/playlists/${2}?summary=${playlistDescEncoded}&X-Plex-Token=${plexToken}"; then
    printOutput "5" "Updated description for playlist ID [${1}]"
else
    printOutput "1" "Failed to update description for playlist ID [${1}]"
fi

# Update the image
playlistImg="$(sqDb "SELECT IMAGE FROM source_playlists WHERE ID = '${1//\'/\'\'}';")"
if [[ -n "${playlistImg}" ]] && ! [[ "${playlistImg}" == "null" ]]; then
    callCurlDownload "${playlistImg}" "${tmpDir}/${1}.jpg"
    callCurlPost "${plexAdd}/library/metadata/${2}/posters?X-Plex-Token=${plexToken}" --data-binary "@${tmpDir}/${1}.jpg"
    rm -f "${tmpDir}/${1}.jpg"
    printOutput "4" "Playlist [${2}] image set"
fi
}

#############################
##       Signal Traps      ##
#############################
trap "badExit SIGINT" INT
trap "badExit SIGQUIT" QUIT

#############################
##   Initiate .env file    ##
#############################
if [[ -e "${realPath%/*}/${scriptName%.bash}.env" ]]; then
    source "${realPath%/*}/${scriptName%.bash}.env"
else
    badExit "62" "Error: \"${realPath%/*}/${scriptName%.bash}.env\" does not appear to exist"
fi

# Validate config 
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
if ! [[ -d "${outputDir}" ]]; then
    printOutput "1" "Video output dir [${outputDir}] does not appear to exist -- Please create it, and add it to Plex"
    varFail="1"
else
    outputDir="${outputDir%/}"
fi
if [[ -z "${tmpDir}" ]]; then
    printOutput "1" "Temporary directory [${tmpDir}] is not set"
    varFail="1"
else
    tmpDir="${tmpDir%/}"
    # Create our tmpDir
    if ! [[ -d "${tmpDir}" ]]; then
        if ! mkdir -p "${tmpDir}"; then
            badExit "63" "Unable to create tmp dir [${tmpDir}]"
        fi
    fi
    tmpDir="$(mktemp -d -p "${tmpDir}")"
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
    badExit "64" "Please fix above errors"
fi

#############################
##  Positional parameters  ##
#############################
# We can run the positional parameter options without worrying about lockFile
printHelp="0"
doUpdate="0"
skipDownload="0"
verifyMedia="0"
updateRatingKeys="0"
skipSource="0"
dbVacuum="0"

# Define some global variables
sqliteDb="${realPath%/*}/.${scriptName}.db"
apiCallsYouTube="0"
apiCallsLemnos="0"
apiCallsSponsor="0"
totalUnits="0"
totalVideoUnits="0"
totalCaptionsUnits="0"
totalChannelsUnits="0"
totalPlaylistsUnits="0"

declare -A reindexArr watchedArr verifiedArr updateMetadataChannel updateMetadataVideo updatePlaylist updateSubtitles titleArr rkArr costArr chanIdLookup

while [[ -n "${*}" ]]; do
    case "${1,,}" in
    "-h"|"--help")
        printHelp="1"
    ;;
    "-u"|"--update")
        doUpdate="1"
    ;;
    "-id"|"--channel-id")
        if [[ "${2:0:1}" == "@" ]]; then
            chanIdLookup["_${2}"]="true"
        else
            printOutput "1" "Invalid option [${2}] passed for channel ID lookup (Did you forget the leading @)"
        fi
        shift
    ;;
    "-q"|"--skip-source")
        skipSource="1"
    ;;
    "-s"|"--skip-download")
        skipDownload="1"
    ;;
    "-i"|"--import-media")
        shift
        importDir+=("${1}")
    ;;
    "-z"|"--verify-media")
        verifyMedia="1"
    ;;
    "-r"|"--rating-key-update")
        updateRatingKeys="1"
    ;;
    "-c"|"--channel-metadata")
        # Validate our following parameter
        if [[ "${2}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
            # We were passed a specific channel ID to update
            # Make sure we're not already updating all
            if [[ "${updateMetadataChannel[0]}" == "all" ]]; then
                printOutput "2" "Ignoring channel metadata update call for channel ID [${2}] as all channels are already being updated"
            else
                printOutput "4" "Marking channel ID [${2}] for metadata update"
                updateMetadataChannel["${2}"]="true"
            fi
        elif [[ "${2}" == "all" ]]; then
            # We are updating all channels
            if ! [[ "${updateMetadataChannel[0]}" == "all" ]]; then
                unset updateMetadataChannel
                updateMetadataChannel[0]="all"
                printOutput "4" "Marking all channels for metadata update"
            fi
        else
            printOutput "1" "Invalid option [${2}] passed for updating channel metadata"
        fi
        shift
    ;;
    "-p"|"--playlist-metadata")
        # Validate our following parameter
        if [[ "${2}" =~ ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$|^(LL|WL)$ ]]; then
            # We were passed a specific playlist ID to update
            # Make sure we're not already updating all
            if [[ "${updatePlaylist[0]}" == "all" ]]; then
                printOutput "2" "Ignoring playlist metadata update call for playlist ID [${2}] as all playlists are already being updated"
            else
                printOutput "4" "Marking playlist ID [${2}] for metadata update"
                updatePlaylist["_${2}"]="true"
            fi
        elif [[ "${2}" == "all" ]]; then
            # We are updating all playlists
            if ! [[ "${updatePlaylist[0]}" == "all" ]]; then
                unset updatePlaylist
                updatePlaylist[0]="all"
                printOutput "4" "Marking all playlists for metadata update"
            fi
        else
            printOutput "1" "Invalid option [${2}] passed for updating playlist metadata"
        fi
        shift
    ;;
    "-v"|"--video-metadata")
        # Validate our following parameter
        if [[ "${2}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
            # We were passed a specific video ID to update
            # Make sure we're not already updating all
            if [[ "${updateMetadataVideo[0]}" == "all" ]]; then
                printOutput "2" "Ignoring video metadata update call for video ID [${2}] as all videos are already being updated"
            # Make sure we're not already updating missing
            elif [[ "${updateMetadataVideo[0]}" == "missing" ]]; then
                printOutput "2" "Ignoring video metadata update call for video ID [${2}] as missing videos are already being updated"
            else
                printOutput "4" "Marking video ID [${2}] for metadata update"
                updateMetadataVideo["_${2}"]="true"
            fi
        elif [[ "${2}" == "all" ]]; then
            # We are updating all videos
            if ! [[ "${updateMetadataVideo[0]}" == "all" ]]; then
                unset updateMetadataVideo
                updateMetadataVideo[0]="all"
                printOutput "4" "Marking all videos for metadata update"
            fi
        else
            printOutput "1" "Invalid option [${2}] passed for updating video metadata"
        fi
        shift
    ;;
    "-t"|"--subtitles")
        # Validate our following parameter
        if [[ "${2}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
            # We were passed a specific video ID to update
            # Make sure we're not already updating all
            if [[ "${updateSubtitles[0]}" == "all" ]]; then
                printOutput "2" "Ignoring video subtitle update call for video ID [${2}] as all videos are already being updated"
            # Make sure we're not already updating missing
            elif [[ "${updateSubtitles[0]}" == "missing" ]]; then
                printOutput "2" "Ignoring video subtitle update call for video ID [${2}] as missing videos are already being updated"
            else
                printOutput "4" "Marking video ID [${2}] for subtitle update"
                updateSubtitles["_${2}"]="true"
            fi
        elif [[ "${2}" == "all" ]]; then
            # We are updating all videos
            if ! [[ "${updateSubtitles[0]}" == "all" ]]; then
                unset updateSubtitles
                updateSubtitles[0]="all"
                printOutput "4" "Marking all videos for subtitle update"
            fi
        elif [[ "${2}" == "missing" ]]; then
            # We are updating all videos
            if ! [[ "${updateSubtitles[0]}" == "missing" ]]; then
                unset updateSubtitles
                updateSubtitles[0]="missing"
                printOutput "4" "Marking videos missing subtitles for subtitle update"
            fi
        else
            printOutput "1" "Invalid option [${2}] passed for updating video subtitles"
        fi
        shift
    ;;
    "-x"|"--ignore")
        # Validate our following parameter
        if [[ "${2}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
            ignoreId+=("${2}")
        else
            printOutput "1" "Invalid options [${2}] passed for video ID to be ignored"
        fi
        shift
    ;;
    "-d"|"--db-maintenance")
        dbVacuum="1"
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

    echo "            ${0##*/} | Version date [${scriptVer}]

-h  --help                  Displays this help message.

-u  --update                Self update to the most recent version.

-id --channel-id            Retrieves a channel ID based off the
                             handle passed (Must start with @).

-q  --skip-source           Skips processing of sources.
                             Can be useful for if you only want to
                             do maintenance tasks.

-s  --skip-download         Skips processing of the download queue.
                             Can be useful for if you only want to
                             do maintenance tasks.

-i  --import-media          Imports media from a supplied directory.

                             Usage is: -i \"/path/to/directory\"
                             It will recurseively search for files in
                             that directory path that match the file
                             name format [VIDEO_ID].mp4, where
                             'VIDEO_ID' is the 11 character video ID
                             enclosed in square brackets.

-z  --verify-media          Compares media on the file system to
                             media in the database, and adds any
                             missing items to the database.
                             Can be useful if you've manually added
                             any media the script is unaware of.
                             * NOTE, this requires that the naming
                             scheme for untracked media to end in
                             '[VIDEO_ID].mp4' where 'VIDEO_ID' is
                             the 11 character video ID enclosed in
                             square brackets.
                            
-r  --rating-key-update     Verifies the correct ID referencing
                             known files in Plex. Useful it you're
                             having issues with incorrect items
                             being added/removed/re-ordered in
                             playlists and collections.

-c  --channel-metadata      Updates descriptions and images for
                             series already downloaded.
                             
                             Usage is: -p \"TARGET\"
                             If you want to update a specific channel,
                             list its channel ID as the TARGET, or you
                             can use the ALL if you want to update all
                             channels.

-p  --playlist-metadata     Updates descriptions and images for
                             playlists and colletions already made.
                             
                             Usage is: -c \"TARGET\"
                             If you want to update a specific playlist,
                             list its playlist ID as the TARGET, or you
                             can use the ALL if you want to update all
                             playlists.

-v  --video-metadata        Updates titles and thumbnails for
                             videos already downloaded.
                             
                             Usage is: -v \"TARGET\"
                             If you want to update a specific video,
                             list its video ID as the TARGET. You can
                             use ALL if you want to update all videos.
                             
-t  --subtitles             Updates subtitles for a video.

                             Usage is: -t \"TARGET\"
                             If you want to udpate a specific video,
                             list its video ID as the TARGET. You can
                             use ALL if you want to update all videos,
                             or MISSING if you only want to update
                             videos which do not have subtitle tracks.

-x  --ignore                Marks a video ID to be ignored.

                              Usage is: -x \"TARGET\"
                              If you want to ignore a specific video,
                              list its video ID as the TARGET.

-d  --db-maintenance        Preforms a 'vacuum' on the sqlite database."

    cleanExit "silent"
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
            badExit "65" "Update downloaded, but unable to \`chmod +x\`"
        fi
    else
        badExit "66" "Unable to download Update"
    fi
    cleanExit
fi

if [[ "${#chanIdLookup[@]}" -ne "0" ]]; then
    for handle in "${!chanIdLookup[@]}"; do
        ytId="${handle#_}"
        ytId="${ytId#@}"
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
        
        channelId="$(yq -p json ".channel_id" <<<"${channelId}")"
        if ! [[ "${channelId}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
            # We don't, let's try the official API
            printOutput "3" "Calling API to obtain channel ID from channel handle [@${ytId}]"
            ytApiCall "channels?forHandle=@${ytId}&part=snippet"
            apiResults="$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")"
            
            # Validate it
            if [[ -z "${apiResults}" ]]; then
                printOutput "1" "API lookup for channel ID of handle [${ytId}] returned blank results output (Bad API call?)"
                continue
            elif [[ "${apiResults}" =~ ^[0-9]+$ ]]; then
                # Expected outcome
                true
            elif ! [[ "${apiResults}" =~ ^[0-9]+$ ]]; then
                printOutput "1" "API lookup for channel ID of handle [${ytId}] returned non-integer results [${apiResults}]"
                continue
            else
                badExit "67" "Impossible condition"
            fi
            
            if [[ "${apiResults}" -eq "0" ]]; then
                printOutput "1" "API lookup for source parsing returned zero results"
                continue
            fi
            if [[ "$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")" -eq "1" ]]; then
                channelId="$(yq -p json ".items[0].id" <<<"${curlOutput}")"
                # Validate it
                if ! [[ "${channelId}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
                    printOutput "1" "Unable to validate channel ID for [@${ytId}]"
                    continue
                fi
            else
                printOutput "1" "Unable to isolate channel ID for [@${ytId}]"
                continue
            fi
        fi
        if [[ -n "${channelId}" ]]; then
            printOutput "3" "Found channel ID [${channelId}] for handle [@${ytId}]"
        else
            printOutput "3" "Failed to locate channel ID for handle [@${ytId}]"
        fi
    done
    cleanExit
fi

#############################
##       Update check      ##
#############################
if [[ "${updateCheck,,}" =~ ^(yes|true)$ ]]; then
    printOutput "4" "Checking for updates"
    callCurlGet "${updateURL}"
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
    done <<<"${curlOutput}"
    if ! [[ "${newVer}" == "${scriptVer}" ]]; then
        printOutput "0" "A newer version [${newVer}] is available"
    else
        printOutput "4" "No new updates available"
    fi
fi

#############################
##         Payload         ##
#############################
# If we're being invoked by cron, sleep for up to ${cronSleep}
if [[ -t 1 ]]; then
    printOutput "5" "Script spawned by interactive terminal"
else    
    printOutput "4" "Script spawned by cron with PID [${$}]"
    if [[ "${cronSleep}" =~ ^[0-9]+$ ]]; then
        sleepTime="$(( RANDOM % cronSleep ))"
        printOutput "3" "Sleeping for [${sleepTime}] seconds before continuing"
        sleep "${sleepTime}"
    fi
fi

# If no database exists, create one
if ! [[ -e "${sqliteDb}" ]]; then
    printOutput "3" "############### Initializing database #################"
    sqlite3 "${sqliteDb}" "CREATE TABLE source_videos(ID TEXT PRIMARY KEY, TITLE TEXT, TITLE_CLEAN TEXT, CHANNEL_ID TEXT, TIMESTAMP INTEGER, THUMBNAIL TEXT, YEAR INTEGER, EP_INDEX INTEGER, DESC TEXT, TYPE TEXT, FORMAT TEXT, SHORTS TEXT, LIVE TEXT, WATCHED TEXT, STATUS TEXT, ERROR TEXT, SB_ENABLE TEXT, SB_REQUIRE TEXT, SB_AVAILABLE TEXT, UPDATED INTEGER);"
    sqlite3 "${sqliteDb}" "CREATE TABLE source_channels(ID TEXT PRIMARY KEY, NAME TEXT, NAME_CLEAN TEXT, TIMESTAMP INTEGER, SUB_COUNT INTEGER, COUNTRY TEXT, URL TEXT, VID_COUNT INTEGER, VIEW_COUNT INTEGER, DESC TEXT, PATH TEXT, IMAGE TEXT, BANNER TEXT, UPDATED INTEGER);"
    sqlite3 "${sqliteDb}" "CREATE TABLE source_playlists(ID TEXT PRIMARY KEY, VISIBILITY TEXT, TITLE TEXT, DESC TEXT, IMAGE TEXT, UPDATED INTEGER);"

    sqlite3 "${sqliteDb}" "CREATE TABLE playlist_order(SQID INTEGER PRIMARY KEY AUTOINCREMENT, ID TEXT, PLAYLIST_INDEX INTEGER, PLAYLIST_KEY TEXT, UPDATED INTEGER);"

    sqlite3 "${sqliteDb}" "CREATE TABLE rating_key(CHANNEL_ID TEXT PRIMARY KEY, RATING_KEY INTEGER, UPDATED INTEGER);"
    
    sqlite3 "${sqliteDb}" "CREATE TABLE subtitle_versions(SQID INTEGER PRIMARY KEY AUTOINCREMENT, ID TEXT, LANG_CODE TEXT, UPDATED TEXT);"
    
    sqlite3 "${sqliteDb}" "CREATE TABLE db_log(ID INTEGER PRIMARY KEY AUTOINCREMENT, TIME TEXT, RESULT TEXT, COMMAND TEXT, OUTPUT TEXT);"
fi

# Preform database maintenance, if needed
if [[ "${dbVacuum}" -eq "1" ]]; then
    startTime="$(($(date +%s%N)/1000000))"
    printOutput "3" "############## Performing database vacuum #############"
    sqDb "VACUUM;"
    printOutput "3" "Database health check and optimization completed [Took $(timeDiff "${startTime}")]"
    cleanExit
fi

# Verify that we can connect to Plex
printOutput "3" "############# Verifying Plex connectivity #############"
getContainerIp "${plexIp}"

# Build our full address
plexAdd="${plexScheme}://${containerIp}:${plexPort}"
if ! callCurlGet "${plexAdd}/servers?X-Plex-Token=${plexToken}"; then
    badExit "68" "Unable to intiate connection to the Plex Media Server"
fi
# Make sure we can reach the server
numServers="$(yq -p xml ".MediaContainer.+@size" <<<"${curlOutput}")"
if [[ "${numServers}" -gt "1" ]]; then
    serverVersion="$(yq -p xml ".MediaContainer.Server[] | select(.+@host == \"${containerIp}\") | .+@version" <<<"${curlOutput}")"
    serverMachineId="$(yq -p xml ".MediaContainer.Server[] | select(.+@host == \"${containerIp}\") | .+@machineIdentifier" <<<"${curlOutput}")"
    serverName="$(yq -p xml ".MediaContainer.Server[] | select(.+@host == \"${containerIp}\") | .+@name" <<<"${curlOutput}")"
elif [[ "${numServers}" -eq "1" ]]; then
    serverVersion="$(yq -p xml ".MediaContainer.Server.+@version" <<<"${curlOutput}")"
    serverMachineId="$(yq -p xml ".MediaContainer.Server.+@machineIdentifier" <<<"${curlOutput}")"
    serverName="$(yq -p xml ".MediaContainer.Server.+@name" <<<"${curlOutput}")"
else
    badExit "69" "No Plex Media Servers found."
fi
if [[ -z "${serverName}" || -z "${serverVersion}" || -z "${serverMachineId}" ]]; then
    badExit "70" "Unable to validate Plex Media Server"
fi
# Get the library ID for our video output directory
# Count how many libraries we have
callCurlGet "${plexAdd}/library/sections/?X-Plex-Token=${plexToken}"
numLibraries="$(yq -p xml ".MediaContainer.Directory | length" <<<"${curlOutput}")"
if [[ "${numLibraries}" -eq "0" ]]; then
    badExit "71" "No libraries detected in the Plex Media Server"
fi
z="0"
while [[ "${z}" -lt "${numLibraries}" ]]; do
    # Get the path for our library ID
    plexPath="$(yq -p xml ".MediaContainer.Directory[${z}].Location.\"+@path\"" <<<"${curlOutput}")"
    # Match based on the top level directory
    if [[ "${outputDir##*/}" == "${plexPath##*/}" ]]; then
        # Get the library name
        libraryName="$(yq -p xml ".MediaContainer.Directory[${z}].\"+@title\"" <<<"${curlOutput}")"
        # Get the library ID
        libraryId="$(yq -p xml ".MediaContainer.Directory[${z}].\"+@key\"" <<<"${curlOutput}")"
        # Get the library type
        libraryType="$(yq -p xml ".MediaContainer.Directory[${z}].\"+@type\"" <<<"${curlOutput}")"
        # Get the library Scanner
        libraryScanner="$(yq -p xml ".MediaContainer.Directory[${z}].\"+@scanner\"" <<<"${curlOutput}")"

        printOutput "4" "Matched Plex video library [${libraryName}] to library ID [${libraryId}]"
        break
    fi
    (( z++ ))
done
if [[ -z "${libraryId}" ]]; then
    badExit "72" "Unable to identify [${outputDir}] from existing Plex libraries"
fi
if ! [[ "${libraryType}" == "show" ]]; then
    badExit "73" "Plex Library not detected as 'TV Show' type library [Found: ${libraryType}] -- Unable to proceed"
fi
if ! [[ "${libraryScanner}" == "Plex Series Scanner" ]]; then
    badExit "74" "Plex Library Scanner not detected as 'Plex Series Scanner' [Found: ${libraryScanner}] -- Unable to proceed"
fi

printOutput "3" "Validated Plex Media Server: ${serverName} [Version: ${serverVersion}] [Machine ID: ${serverMachineId}]"

if [[ "${verifyMedia}" -eq "1" ]]; then
    printOutput "3" "############### Verifying media library ###############"
    verifySuccessCount="0"
    verifyFailCount="0"
    # Get a list of known media files from the FS in an array
    declare -A knownFiles
    while read -r i; do
        ytId="${i%\]\.mp4}"
        ytId="${ytId##*\[}"
        knownFiles["_${ytId}"]="found"
    done < <(find "${outputDir}" -type f -regextype egrep -regex "^.*\[([A-Za-z0-9_-]{11})\]\.mp4")
    # Get a list of shows
    callCurlGet "${plexAdd}/library/sections/${libraryId}/all?X-Plex-Token=${plexToken}"
    readarray -t knownRatingKeys < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
    # For every show in Plex
    for ratingKey in "${knownRatingKeys[@]}"; do
        ## Get a list of seasons for that show
        callCurlGet "${plexAdd}/library/metadata/${ratingKey}/children?X-Plex-Token=${plexToken}"
        ## Get the show name, for printing
        seriesTitle="$(yq -p xml ".MediaContainer.\"+@parentTitle\"" <<<"${curlOutput}")"
        printOutput "4" "Verifying series [${seriesTitle}] with rating key [${ratingKey}]"
        readarray -t knownSeasonRatingKeys < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
        ## For every season of that show
        for seasonRatingKey in "${knownSeasonRatingKeys[@]}"; do
            ### Get a list of episodes for that season
            callCurlGet "${plexAdd}/library/metadata/${seasonRatingKey}/children?X-Plex-Token=${plexToken}"
            ### Get the season number, for printing
            seasonYear="$(yq -p xml ".MediaContainer.\"+@parentIndex\"" <<<"${curlOutput}")"
            printOutput "4" "Verifying season year [${seasonYear}] with rating key [${seasonRatingKey}]"
            ### For every episode of that season
            while read -r knownFileId; do
                #### Isolate the video ID
                ytId="${knownFileId%\]\.mp4}"
                ytId="${ytId##* \[}"
                #### Remove the video ID from the array
                if [[ -n "${knownFiles[_${ytId}]}" ]]; then
                    unset knownFiles["_${ytId}"]
                    printOutput "5" "Verified [${knownFileId##*/}]"
                    (( verifySuccessCount++ ))
                else
                    #### If the video ID is not in the array, log it in an error array (Exists in Plex, not on FS)
                    orphanFiles+=("${knownFileId}")
                    printOutput "5" "Failed to verify [${knownFileId##*/}]"
                    (( verifyFailCount++ ))
                fi
            done < <(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .Media | ([] + .) | .[] | .Part.\"+@file\"" <<<"${curlOutput}")
        done
    done
    printOutput "3" "Verified ${verifySuccessCount} files | Failed to verify ${verifyFailCount} files"
    # Print any remaining FS video ID's which were not matched in plex (Exist on FS, not in Plex) -- Print error array, if not empty
    if [[ "${#orphanFiles[@]}" -ne "0" ]]; then
        printOutput "1" "Found [${#orphanFiles[@]}] orphaned files in Plex:"
        for i in "${orphanFiles[@]}"; do
            printOutput "1" "${i}"
        done
    fi
    if [[ "${#knownFiles[@]}" -ne "0" ]]; then
        printOutput "1" "Failed to locate [${#knownFiles[@]}] files on filesystem but not in Plex"
        for i in "${!knownFiles[@]}"; do
            i="${i#_}"
            printOutput "1" "${i}"
        done
    fi
fi

if [[ "${updateRatingKeys}" -eq "1" ]]; then
    printOutput "3" "################ Verifying rating keys ################"
    # Update all rating keys for all channels in Plex
    # Get a list of shows from the database
    callCurlGet "${plexAdd}/library/sections/${libraryId}/all?X-Plex-Token=${plexToken}"
    while read -r ratingKey; do
        ## Get a list of seasons for that show
        callCurlGet "${plexAdd}/library/metadata/${ratingKey}/children?X-Plex-Token=${plexToken}"
        ## Get the show name, for printing
        seriesTitle="$(yq -p xml ".MediaContainer.\"+@parentTitle\"" <<<"${curlOutput}")"
        ## Get the first season
        firstYear="$(yq -p xml ".MediaContainer.Directory  | ([] + .) | .[0].\"+@index\"" <<<"${curlOutput}")"
        ## Get the first season rating key
        firstYearKey="$(yq -p xml ".MediaContainer.Directory  | ([] + .) | .[0].\"+@ratingKey\"" <<<"${curlOutput}")"
        if [[ "${firstYear}" == "null" ]]; then
            firstYear="$(yq -p xml ".MediaContainer.Directory  | ([] + .) | .[1].\"+@index\"" <<<"${curlOutput}")"
            firstYearKey="$(yq -p xml ".MediaContainer.Directory  | ([] + .) | .[1].\"+@ratingKey\"" <<<"${curlOutput}")"
        fi
        printOutput "4" "Looking up series [${seriesTitle}] via rating key [${ratingKey}] with season year [${firstYear}] via rating key [${firstYearKey}]"
        ## Get the first file of the first season
        callCurlGet "${plexAdd}/library/metadata/${firstYearKey}/children?X-Plex-Token=${plexToken}"
        firstFileId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[0].Media.Part.\"+@file\"" <<<"${curlOutput}")"
        firstFileId="${firstFileId%\]\.mp4}"
        firstFileId="${firstFileId##*\[}"
        ## Now look up that video ID in the database for its CHANNEL_ID
        firstFileChannelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${firstFileId//\'/\'\'}';")"
        ## Now get the rating key for that channel ID in the database
        readarray -t foundRatingKey < <(sqDb "SELECT RATING_KEY FROM rating_key WHERE CHANNEL_ID = '${firstFileChannelId//\'/\'\'}';")
        if [[ "${#foundRatingKey[@]}" -eq "0" ]]; then
            ### Doesn't exist in the database
            printOutput "5" "No rating keys found in database for series [${seriesTitle}]"
            if sqDb "INSERT INTO rating_key (CHANNEL_ID, RATING_KEY, UPDATED) VALUES ('${firstFileChannelId//\'/\'\'}', ${ratingKey}, $(date +%s));"; then
                printOutput "3" "Added rating key [${ratingKey}] for series [${seriesTitle}] to database"
            else
                printOutput "1" "Failed to add rating key [${ratingKey}] for series [${seriesTitle}] to database"
            fi
        elif [[ "${#foundRatingKey[@]}" -eq "1" ]]; then
            ### Something exists. Compare.
            if [[ "${foundRatingKey[0]}" -eq "${ratingKey}" ]]; then
                #### Matches
                printOutput "3" "Verified existing rating key [${ratingKey}] for series [${seriesTitle}]"
            else
                #### Mismatch. Update.
                if sqDb "UPDATE rating_key SET RATING_KEY = ${ratingKey}, UPDATED = '$(date +%s)' WHERE ID = '${firstFileChannelId//\'/\'\'}';"; then
                    printOutput "5" "Updated stale rating key for series [${seriesTitle}] from [${foundRatingKey[0]}] to [${ratingKey}]"
                else
                    printOutput "1" "Failed to update stale rating key for series [${seriesTitle}] from [${foundRatingKey[0]}] to [${ratingKey}]"
                fi
            fi
        else
            printOutput "1" "Unexpected count [${#foundRatingKey[@]}] when looking up rating key for channel ID [${firstFileChannelId}] - [${foundRatingKey[*]}]"
        fi
    done < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
fi

if [[ "${#updateMetadataChannel[@]}" -ne "0" ]]; then
    printOutput "3" "############## Updating channel metadata ##############"
    if [[ "${updateMetadataChannel[0]}" == "all" ]]; then
        callCurlGet "${plexAdd}/library/sections/${libraryId}/all?X-Plex-Token=${plexToken}"
        declare -A dblChk
        while read -r i title; do
            dblChk["${i}"]="${title}"
        done < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | ( .\"+@ratingKey\" + \" \" + .\"+@title\" )" <<<"${curlOutput}")
        # Update all channel information in database
        printOutput "3" "Processing channels in database"
        while read -r channelId; do
            chanName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
            printOutput "4" "Updating database information for channel ID [${channelId}] [${chanName}]"
            if channelToDb "${channelId}"; then
                channelRatingKey="$(sqDb "SELECT RATING_KEY FROM rating_key WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
                if [[ -z "${channelRatingKey}" ]]; then
                    if ! setSeriesRatingKey "${channelId}"; then
                        printOutput "1" "Failed to set series rating key for channel ID [${channelId}]"
                        return 1
                    else
                        channelRatingKey="$(sqDb "SELECT RATING_KEY FROM rating_key WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
                    fi
                fi
                
                if [[ -z "${channelRatingKey}" ]]; then
                    printOutput "1" "Unable to locate rating key for channel ID [${channelId}] -- Skipping"
                    continue
                else
                    unset dblChk["${channelRatingKey}"]
                fi
            else
                printOutput "1" "Failed to update database for channel ID [${channelId}] [${chanName}]"
            fi
        done < <(sqDb "SELECT ID FROM source_channels;")
        # Update all channel images, banner images, season images
        printOutput "3" "Updating series media images"
        while read -r channelId; do
            chanName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
            printOutput "4" "Updating series images for channel ID [${channelId}] [${chanName}]"
            # Create the series image (This will only create new images if there's been an updated image)
            makeShowImage "${channelId}"
        done < <(sqDb "SELECT ID FROM source_channels;")
    
        # Update all series metadata in Plex
        printOutput "3" "Setting series metadata in PMS"
        while read -r channelId; do
            printOutput "4" "Updating metadata for channel ID [${channelId}]"
            # Get the series rating key
            channelRatingKey="$(sqDb "SELECT RATING_KEY FROM rating_key WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            if [[ -n "${channelRatingKey}" ]]; then
                setSeriesMetadata "${channelRatingKey}"
            else
                printOutput "1" "Unable to retrieve rating key for channel ID [${channelId}]"
            fi
        done < <(sqDb "SELECT ID FROM source_channels;")

        if [[ "${#dblChk[@]}" -ne "0" ]]; then
            printOutput "1" "Failed to update the following Plex series:"
            for title in "${dblChk[@]}"; do
                printOutput "1" "${title}"
            done
        else
            printOutput "3" "Successfully updated all series in Plex"
        fi

    else
        printOutput "3" "Processing [${#updateMetadataChannel[@]}] channels"
        for channelId in "${!updateMetadataChannel[@]}"; do
            # Update the database entries for the channel ID
            chanName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
            printOutput "4" "Updating database information for channel ID [${channelId}] [${chanName}]"
            if channelToDb "${channelId}"; then
                channelRatingKey="$(sqDb "SELECT RATING_KEY FROM rating_key WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
                if [[ -z "${channelRatingKey}" ]]; then
                    if ! setSeriesRatingKey "${channelId}"; then
                        printOutput "1" "Failed to set series rating key for channel ID [${channelId}]"
                        return 1
                    else
                        channelRatingKey="$(sqDb "SELECT RATING_KEY FROM rating_key WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
                    fi
                fi
                
                if [[ -z "${channelRatingKey}" ]]; then
                    printOutput "1" "Unable to locate rating key for channel ID [${channelId}] -- Skipping"
                    continue
                else
                    unset dblChk["${channelRatingKey}"]
                fi
            else
                printOutput "1" "Failed to update database for channel ID [${channelId}] [${chanName}]"
            fi
            
            # Update the image(s) if necessary
            printOutput "4" "Updating series images for channel ID [${channelId}] [${chanName}]"
            makeShowImage "${channelId}"
            
            # Update the metadata
            printOutput "4" "Updating metadata for channel ID [${channelId}]"
            # Get the series rating key
            channelRatingKey="$(sqDb "SELECT RATING_KEY FROM rating_key WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            if [[ -n "${channelRatingKey}" ]]; then
                setSeriesMetadata "${channelRatingKey}"
            else
                printOutput "1" "Unable to retrieve rating key for channel ID [${channelId}]"
            fi
        done
    fi
fi

# If we're updating all playlists, go ahead and read them all into the array
# We don't actually need to update them now, as that happens at the end of the script
if [[ "${updatePlaylist[0]}" == "all" ]]; then
    unset updatePlaylist
    declare -A updatePlaylist
    while read -r plId; do
        printOutput "5" "Forcing update for playlist ID [${plId}]"
        updatePlaylist["_${plId}"]="true"
    done < <(sqDb "SELECT ID FROM source_playlists;")
fi

if [[ "${#updateMetadataVideo[@]}" -ne "0" ]]; then
    printOutput "3" "############### Updating video metadata ###############"
    
    # If our parameter is "all", then replace the array wtih an array of video ID's
    if [[ "${updateMetadataVideo[0]}" == "all" ]]; then
        unset updateMetadataVideo
        declare -A updateMetadataVideo
        while read -r ytId; do
            updateMetadataVideo["_${ytId}"]="true"
        done < <(sqDb "SELECT ID FROM source_videos;")
    fi
    
    loopNum="0"
    for ytId in "${!updateMetadataVideo[@]}"; do
        (( loopNum++ ))
        ytId="${ytId#_}"
        printOutput "3" "Updating metadata for video ID [${ytId}] [Item ${loopNum} of ${#updateMetadataVideo[@]}]"
        # Get its current downloaded path
        readarray -t verifyPath < <(find "${outputDir}" -type f -name "*\[${ytId}\].mp4")
        if [[ "${#verifyPath[@]}" -eq "0" ]]; then
            # It's not downloaded yet?
            vidStatus="$(sqDb "SELECT STATUS FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
            if [[ "${vidStatus}" == "downloaded" ]]; then
                # We think it's downloaded, so that's a problem
                printOutput "1" "Video ID [${ytId}] is marked as downloaded, but cannot be located in [${outputDir}]"
            fi
        elif [[ "${#verifyPath[@]}" -eq "1" ]]; then
            # We only found one, that's good
            printOutput "5" "Verified video ID [${ytId}] at path [${verifyPath[0]}]"
        elif [[ "${#verifyPath[@]}" -ge "2" ]]; then
            # We found multiple matches, that's not good
            printOutput "1" "Found [${#verifyPath[@]}] matches for video ID [${ytId}] in [${outputDir}]"
            for path in "${verifyPath[@]}"; do
                printOutput "1" "${path}"
            done
            printOutput "1" "Skipping metadata update for video ID [${ytId}]"
            continue
        fi
        
        # We need the existing global variables for this video
        # We have the video format option
        outputResolution="$(sqDb "SELECT FORMAT FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # We have the include shorts option
        includeShorts="$(sqDb "SELECT SHORTS FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # We have the include live option
        includeLiveBroadcasts="$(sqDb "SELECT LIVE FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # We have the mark watched option
        markWatched="$(sqDb "SELECT WATCHED FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # We have the sponsor block enable option
        sponsorblockEnable="$(sqDb "SELECT SB_ENABLE FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # We have the sponsor block require option
        sponsorblockRequire="$(sqDb "SELECT SB_REQUIRE FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        
        # Go ahead and update the database entry
        ytIdToDb "${ytId}"
        
        # We only need to keep going if the file exists on the file system
        if [[ "${#verifyPath[@]}" -eq "0" ]]; then
            continue
        fi
        
        # Get the path that it _should_ be at
        channelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${channelId}" ]]; then
            badExit "75" "Unable to determine channel ID for video ID [${ytId}] -- Possible database corruption"
        fi
        channelPath="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
        if [[ -z "${channelPath}" ]]; then
            badExit "76" "Unable to determine channel path for video ID [${ytId}] -- Possible database corruption"
        fi
        channelName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
        if [[ -z "${channelName}" ]]; then
            badExit "77" "Unable to determine channel name for video ID [${ytId}] -- Possible database corruption"
        fi
        channelNameClean="$(sqDb "SELECT NAME_CLEAN FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
        if [[ -z "${channelNameClean}" ]]; then
            badExit "78" "Unable to determine clean channel name for video ID [${ytId}] -- Possible database corruption"
        fi
        vidYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidYear}" ]]; then
            badExit "79" "Unable to determine video year for video ID [${ytId}] -- Possible database corruption"
        fi
        vidIndex="$(sqDb "SELECT EP_INDEX FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidIndex}" ]]; then
            badExit "80" "Unable to determine video index for video ID [${ytId}] -- Possible database corruption"
        fi
        vidTitle="$(sqDb "SELECT TITLE FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidTitle}" ]]; then
            badExit "81" "Unable to determine video title for video ID [${ytId}] -- Possible database corruption"
        fi
        vidTitleClean="$(sqDb "SELECT TITLE_CLEAN FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidTitleClean}" ]]; then
            badExit "82" "Unable to determine clean video title for video ID [${ytId}] -- Possible database corruption"
        fi
        # String it together
        verifyPathCorrect="${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4"
        
        # Verify that the two match
        if [[ "${verifyPath[0]}" == "${verifyPathCorrect}" ]]; then
            # We're good
            printOutput "5" "Verified video ID [${ytId}] to be correctly named on file system"
        else
            # We're not good. Let's go ahead and move the file to where it _should_ be.
            printOutput "4" "Video ID [${ytId}] not correctly named on file system -- Fixing"
            # Make sure our destination exists
            if ! [[ -d "${verifyPathCorrect%/*}" ]]; then
                badExit "83" "Unexpected condition - Destination path [${verifyPathCorrect%/*}] for video ID [${verifyPath[0]}] does not exist"
            fi
            if mv "${verifyPath[0]}" "${verifyPathCorrect}"; then
                printOutput "3" "Corrected video ID [${ytId}] name on file system"
                # Move any applicable thumbnail
                while read -r thumbPath; do
                    if ! mv "${thumbPath}" "${verifyPathCorrect%mp4}jpg"; then
                        printOutput "1" "Failed to move thumbnail [${thumbPath}] to destination [${verifyPathCorrect%mp4}jpg]"
                    fi
                done < <(find "${outputDir}" -type f -name "*\[${ytId}\].jpg")
            else
                printOutput "1" "Failed to move file [${verifyPath[0]}] to destination [${verifyPathCorrect}]"
            fi
        fi
        
        # Grab the latest thumbnail, if the video type isn't private
        printOutput "4" "Checking for updated thumbnail for video ID [${ytId}]"
        vidVisibility="$(sqDb "SELECT TYPE FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        if [[ "${vidVisibility}" =~ ^.*_private$ ]]; then
            printOutput "2" "Unable to update thumbnail for video ID [${ytId}] due to no longer being public"
        else
            # Get the thumbnail URL
            thumbUrl="$(sqDb "SELECT THUMBNAIL FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
            if [[ -n "${thumbUrl}" ]]; then
                callCurlDownload "${thumbUrl}" "${tmpDir}/${ytId}.jpg"
            else
                printOutput "1" "Failed to retrieve thumbnail URL for video ID [${ytId}]"
                continue
            fi
        
            # Compare them
            if cmp -s "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg" "${tmpDir}/${ytId}.jpg"; then
                printOutput "5" "No changes detected for video ID [${ytId}], removing newly downloaded file thumbnail"
                if ! rm -f "${tmpDir}/${ytId}.jpg"; then
                    printOutput "1" "Failed to remove newly downloaded file thumbmail for video ID [${ytId}]"
                fi
            else
                printOutput "4" "New file thumbnail detected for video ID [${ytId}], backing up old image and replacing with new one"
                if ! mv "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg" "${outputDir}/${channelPath}/Season ${vidYear}/.${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].bak-$(date +%s).jpg"; then
                    printOutput "1" "Failed to back up previously downloaded file thumbnail for video ID [${ytId}]"
                fi
                if ! mv "${tmpDir}/${ytId}.jpg" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"; then
                    printOutput "1" "Failed to move newly downloaded show image file for channel ID [${1}]"
                else
                    printOutput "3" "Updated thumbnail for video ID [${ytId}]"
                fi
            fi
            
            if ! [[ -e "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg" ]]; then
                printOutput "1" "Failed to get thumbnail for video ID [${tmpId}]"
            fi
        fi
    done
fi

if [[ "${#updateSubtitles[@]}" -ne "0" ]]; then
    printOutput "3" "################## Updating subtitles #################"
    if [[ "${updateSubtitles[0]}" == "all" ]]; then
        unset updateSubtitles
        declare -A updateSubtitles
        # Do a random order, as we'll likely exhaust our API calls with this, so randomizing it means future runs won't get stuck on the same data over and over
        while read -r ytId; do
            updateSubtitles["_${ytId}"]="true"
        done < <(sqDb "SELECT ID FROM source_videos WHERE STATUS = 'downloaded' ORDER BY RANDOM();")
    elif [[ "${updateSubtitles[0]}" == "missing" ]]; then
        unset updateSubtitles
        declare -A updateSubtitles
        # Do a random order, as we'll likely exhaust our API calls with this, so randomizing it means future runs won't get stuck on the same data over and over
        while read -r ytId; do
            updateSubtitles["_${ytId}"]="true"
        done < <(sqDb "SELECT ID FROM source_videos WHERE STATUS = 'downloaded' ORDER BY RANDOM();")
        # Remove file ID's which already have subtitles
        while read -r ytId; do
            unset updateSubtitles["_${ytId}"]
        done < <(sqDb "SELECT ID FROM subtitle_versions;")
    fi
    subsLoopNum="0"
    for ytId in "${!updateSubtitles[@]}"; do
        (( subsLoopNum++ ))
        printOutput "4" "Checking subtitles for video ID [${ytId#_}] [Item ${subsLoopNum} of ${#updateSubtitles[@]}]"
        if ! downloadSubs "${ytId#_}"; then
            printOutput "1" "Failed to download subtitles for video ID [${ytId#_}]"
        fi
    done
fi

if [[ "${#ignoreId[@]}" -ne "0" ]]; then
    printOutput "3" "############### Processing ID's to ignore #############"
    ignoreLoopNum="0"
    for ytId in "${ignoreId[@]}"; do
        (( ignoreLoopNum++ ))
        printOutput "3" "Processing video ID [${ytId}][Item ${ignoreLoopNum} of ${#ignoreId[@]}]"
        # Make sure it's not already in the database
        dbCount="$(sqDb "SELECT COUNT(1) FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        if [[ "${dbCount}" -eq "0" ]]; then
            # It's not in the database, add it as an IGNORE entry
            if sqDb "INSERT INTO source_videos (ID, STATUS, UPDATED) VALUES ('${ytId//\'/\'\'}', 'ignore', $(date +%s));"; then
                printOutput "4" "Successfully marked video ID [${ytId}] to be ignored"
            else
                printOutput "1" "Failed to mark video ID [${ytId}] to be ignored"
            fi
        elif [[ "${dbCount}" -eq "1" ]]; then
            printOutput "2" "Skipping video ID [${ytId}] as it is already present in database"
        else
            printOutput "1" "Unexpected dbCount returned [${dbCount}] for video ID [${ytId}] -- Possible database corruption"
        fi
    done
fi

if [[ "${#importDir[@]}" -ne "0" ]]; then
    printOutput "3" "############# Checking for files to import ############"
    for dir in "${importDir[@]}"; do
        # Start by searching the import directory for files to import
        printOutput "5" "Found import dir: ${dir}"
        # Make sure the import dir actually exists
        if ! [[ -d "${dir}" ]]; then
            printOutput "1" "Import directory [${dir}] does not appear to actually exist -- Skipping"
        else
            # Find the files to import
            readarray -t importArr < <(find "${dir}" -type f -regextype egrep -regex "^.*\[([A-Za-z0-9_-]{11})\]\.mp4")
            printOutput "3" "Found [${#importArr[@]}] files to import"
            # Set some global variables for these imported files
            markWatched="false"
            includeShorts="true"
            includeLiveBroadcasts="true"
            sponsorblockEnable="disable"
            sponsorblockRequire="false"
            n="1"
            for f in "${importArr[@]}"; do
                ytId="${f%\]\.mp4}"
                ytId="${ytId##*\[}"
                printOutput "4" "Processing video ID [${ytId}] [Item ${n} of ${#importArr[@]}]"
                (( n++ ))
                
                # If it's already in the database, we can skip it
                dbCount="$(sqDb "SELECT COUNT(1) FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
                if [[ "${dbCount}" -eq "0" ]]; then
                    # Safety check
                    true
                elif [[ "${dbCount}" -eq "1" ]]; then
                    printOutput "3" "Video ID already present in database -- Skipping import"
                else
                    badExit "84" "Unexpected count returned [${dbCount}] for video ID [${ytId}] -- Possible database corruption"
                fi
                
                # Set its resolution
                outputResolution="import"
                
                # Now add the file to our database
                ytIdToDb "${ytId}" "import" "${f}"
            done
        fi
    done
fi

if [[ "${skipSource}" -eq "0" ]]; then
    printOutput "3" "############### Processing media sources ##############"
    while read -r source; do
        # Unset some variables we need to be able to be blank
        unset videoArr itemType channelId plId ytId
        # Unset some variables from the previous source
        unset sourceUrl outputResolution markWatched includeShorts includeLiveBroadcasts sponsorblockEnable sponsorblockEnable
        printOutput "3" "Processing source: ${source##*/}"
        source "${source}"
        
        if [[ -z "${sourceUrl}" ]]; then
            printOutput "1" "No source URL provided in input file [${source##*/}]"
            continue
        fi

        printOutput "4" "Validating source config"
        # Verify source config options
        if [[ -z "${sourceUrl}" ]]; then
            printOutput "1" "No source URL provided in source file [${source}] -- Skipping"
        fi
        
        # Start with video output resolution
        if [[ "${outputResolution,,}" == "none" ]]; then
            outputResolution="none"
        elif [[ "${outputResolution,,}" == "144p" ]]; then
            outputResolution="144"
        elif [[ "${outputResolution,,}" == "240p" ]]; then
            outputResolution="240"
        elif [[ "${outputResolution,,}" == "360p" ]]; then
            outputResolution="360"
        elif [[ "${outputResolution,,}" == "480p" ]]; then
            outputResolution="480"
        elif [[ "${outputResolution,,}" == "720p" ]]; then
            outputResolution="720"
        elif [[ "${outputResolution,,}" == "1080p" ]]; then
            outputResolution="1080"
        elif [[ "${outputResolution,,}" == "1440p" || "${outputResolution,,}" == "2k" ]]; then
            outputResolution="1440"
        elif [[ "${outputResolution,,}" == "2160p" || "${outputResolution,,}" == "4k" ]]; then
            outputResolution="2160"
        elif [[ "${outputResolution,,}" == "4320p" || "${outputResolution,,}" == "8k" ]]; then
            outputResolution="4320"
        elif [[ "${outputResolution,,}" == "original" ]]; then
            outputResolution="original"
        else
            outputResolution="original"
        fi
        printOutput "5" "Video output [${outputResolution}]"
        
        # Mark as watched on import?
        if ! [[ "${markWatched,,}" == "true" ]]; then
            markWatched="false"
        else
            markWatched="${markWatched,,}"
        fi
        printOutput "5" "Mark as watched on import [${markWatched}]"
        
        # Include shorts?
        if ! [[ "${includeShorts,,}" == "true" ]]; then
            includeShorts="false"
        else
            includeShorts="${includeShorts,,}"
        fi
        printOutput "5" "Include shorts [${includeShorts}]"
        
        # Include live broadcasts?
        if ! [[ "${includeLiveBroadcasts,,}" == "true" ]]; then
            includeLiveBroadcasts="false"
        else
            includeLiveBroadcasts="${includeLiveBroadcasts,,}"
        fi
        printOutput "5" "Include live broadcasts [${includeLiveBroadcasts}]"
        
        # Enable sponsorblock?
        if ! [[ "${sponsorblockEnable,,}" =~ ^(mark|remove)$ ]]; then
            sponsorblockEnable="disable"
        else
            sponsorblockEnable="${sponsorblockEnable,,}"
        fi
        printOutput "5" "Enable sponsorblock [${sponsorblockEnable}]"
        
        # If enabled, require sponsorblock?
        if [[ "${sponsorblockRequire,,}" =~ ^(mark|remove)$ ]]; then
            if ! [[ "${sponsorblockRequire,,}" == "true" ]]; then
                sponsorblockRequire="false"
            else
                sponsorblockRequire="${sponsorblockRequire,,}"
            fi
        fi
        printOutput "5" "Require sponsorblock [${sponsorblockRequire}]"        

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
            printOutput "4" "Found video ID [${ytId}]"
        elif [[ "${id:12:6}" == "shorts" ]]; then
            # This is a video ID for a short
            itemType="video"
            ytId="${id:19:11}"
            printOutput "4" "Found short video ID [${ytId}]"
        elif [[ "${id:0:8}" == "youtube." ]]; then
            # This can be a video ID (normal, live, or short), a channel ID, a channel name, or a playlist
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
                
                channelId="$(yq -p json ".channel_id" <<<"${channelId}")"
                if ! [[ "${channelId}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
                    # We don't, let's try the official API
                    printOutput "3" "Calling API to obtain channel ID from channel handle [@${ytId}]"
                    ytApiCall "channels?forHandle=@${ytId}&part=snippet"
                    apiResults="$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")"
                    
                    # Validate it
                    if [[ -z "${apiResults}" ]]; then
                        printOutput "1" "API lookup for channel ID of handle [${ytId}] returned blank results output (Bad API call?) -- Skipping source"
                        continue
                    elif [[ "${apiResults}" =~ ^[0-9]+$ ]]; then
                        # Expected outcome
                        true
                    elif ! [[ "${apiResults}" =~ ^[0-9]+$ ]]; then
                        printOutput "1" "API lookup for channel ID of handle [${ytId}] returned non-integer results [${apiResults}] -- Skipping source"
                        continue
                    else
                        badExit "85" "Impossible condition"
                    fi
                    
                    if [[ "${apiResults}" -eq "0" ]]; then
                        printOutput "1" "API lookup for source parsing returned zero results -- Skipping source"
                        continue
                    fi
                    if [[ "$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")" -eq "1" ]]; then
                        channelId="$(yq -p json ".items[0].id" <<<"${curlOutput}")"
                        # Validate it
                        if ! [[ "${channelId}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
                            printOutput "1" "Unable to validate channel ID for [@${ytId}] -- Skipping source"
                            continue
                        fi
                    else
                        printOutput "1" "Unable to isolate channel ID for [${sourceUrl}] -- Skipping source"
                        continue
                    fi
                fi
                printAngryWarning
                printOutput "1" "Refusing to index source with a non-constant URL"
                printOutput "1" "Channel usernames are less reliable than channel ID's, as usernames can be changed, but ID's can not."
                printOutput "1" "To have this source indexed, please replace your source URL:"
                printOutput "1" "  ${sourceUrl}"
                printOutput "1" "with its channel ID URL:"
                printOutput "1" "  https://www.youtube.com/channel/${channelId}"
                printOutput "2" " "
                printOutput "3" "Found channel ID [${channelId}] for handle [@${ytId}]"
                itemType="channel"
                # Skip this source
                continue
            elif [[ "${id:12:8}" == "watch?v=" ]]; then
                # It's a video ID
                itemType="video"
                ytId="${id:20:11}"
                printOutput "4" "Found video ID [${ytId}]"
            elif [[ "${id:12:7}" == "channel" ]]; then
                # It's a channel ID
                itemType="channel"
                channelId="${id:20:24}"
                printOutput "4" "Found channel ID [${channelId}]"
            elif [[ "${id:12:8}" == "playlist" ]]; then
                # It's a playlist
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
                printOutput "4" "Found playlist [${plId}]"
            fi
        else
            printOutput "1" "Unable to parse input [${id}] -- skipping"
            continue
        fi

        if [[ "${itemType}" == "video" ]]; then
            # Add it to our array of videos to index
            # Using the keys of an associative array prevents any element from being added multiple times
            # The array element must be padded with an underscore, or it can be misinterpreted as an integer
            # Only process the video if it's not accounted for
            dbReply="$(sqDb "SELECT COUNT(1) FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
            if [[ "${dbReply}" -eq "0" ]]; then
                printOutput "4" "Queueing video ID [${ytId}] for database addition"
                videoArr+=("${ytId}")
            elif [[ "${dbReply}" -eq "1" ]]; then
                # Do we need to replace it based on sponsorblock availability?
                if ! [[ "${sponsorblockEnable}" == "disable" ]]; then
                    # SponsorBlock is enabled, see if we should upgrade
                    if [[ "${sponsorblockRequire}" == "false" ]]; then
                        # Yes, we may need to upgrade
                        # See if we've already pulled the data for the video
                        sponsorblockAvailable="$(sqDb "SELECT SB_AVAILABLE FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
                        if [[ "${sponsorblockAvailable%% \[*}" == "Found" ]]; then
                            # We can skip it
                            printOutput "5" "Skipping video ID [${i}] as SponsorBlock criteria already met"
                            continue
                        else
                            # It's not found, add the video to the queue
                            printOutput "4" "Queueing video ID [${ytId}] to check for SponsorBlock availability"
                            videoArr+=("${ytId}")
                        fi
                    fi
                fi
            else
                badExit "86" "Counted [${dbReply}] rows with video ID [${ytId}] -- Possible database corruption"
            fi
        elif [[ "${itemType}" == "channel" ]]; then
            # We should use ${channelId} for the channel ID rather than ${ytId} which could be the handle        
            # Get a list of the videos for the channel
            printOutput "3" "Getting video list for channel ID [${channelId}]"
            if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
                readarray -t chanVidList < <(yt-dlp --flat-playlist --playlist-reverse --no-warnings --cookies "${cookieFile}" --print "%(id)s" "https://www.youtube.com/channel/${channelId}")
            else
                readarray -t chanVidList < <(yt-dlp --flat-playlist --playlist-reverse --no-warnings --print "%(id)s" "https://www.youtube.com/channel/${channelId}")
            fi
            
            printOutput "4" "Pulled list of [${#chanVidList[@]}] videos from channel"
            
            for i in "${chanVidList[@]}"; do
                # Only process the video if it's not accounted for
                dbReply="$(sqDb "SELECT COUNT(1) FROM source_videos WHERE ID = '${i//\'/\'\'}';")"
                if [[ "${dbReply}" -eq "0" ]]; then
                    printOutput "4" "Queueing video ID [${i}] for database addition"
                    videoArr+=("${i}")
                elif [[ "${dbReply}" -eq "1" ]]; then
                    # Do we need to replace it based on sponsorblock availability?
                    if ! [[ "${sponsorblockEnable}" == "disable" ]]; then
                        # SponsorBlock is enabled, see if we should upgrade
                        if [[ "${sponsorblockRequire}" == "false" ]]; then
                            # Yes, we may need to upgrade
                            # See if we've already pulled the data for the video
                            sponsorblockAvailable="$(sqDb "SELECT SB_AVAILABLE FROM source_videos WHERE ID = '${i//\'/\'\'}';")"
                            if [[ "${sponsorblockAvailable%% \[*}" == "Found" ]]; then
                                # We can skip it
                                printOutput "5" "Skipping video ID [${i}] as SponsorBlock criteria already met"
                                continue
                            else
                                # It's not found, add the video to the queue
                                printOutput "4" "Queueing video ID [${i}] to check for SponsorBlock availability"
                                videoArr+=("${i}")
                            fi
                        fi
                    fi
                else
                    badExit "87" "Counted [${dbReply}] rows with video ID [${i}] -- Possible database corruption"
                fi
            done
        elif [[ "${itemType}" == "playlist" ]]; then
            printOutput "3" "Processing playlist ID [${plId}]"

            # Get a list of videos in the playlist -- Easier/faster to do this via yt-dlp than API
            unset plVidList
            if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
                while read -r ytId; do
                    for idChk in "${plVidList[@]}"; do
                        if [[ "${ytId}" == "${idChk}" ]]; then
                            # We've already grabbed this video ID
                            printOutput "5" "Video ID [${ytId}] already appears in playlist ID [${plId}] -- Skipping duplicate entry"
                            continue 2
                        fi
                    done
                    plVidList+=("${ytId}")
                done < <(yt-dlp --cookies "${cookieFile}" --flat-playlist --no-warnings --print "%(id)s" "https://www.youtube.com/playlist?list=${plId}")
            else
                while read -r ytId; do
                    for idChk in "${plVidList[@]}"; do
                        if [[ "${ytId}" == "${idChk}" ]]; then
                            # We've already grabbed this video ID
                            printOutput "5" "Video ID [${ytId}] already appears in playlist ID [${plId}] -- Skipping duplicate entry"
                            continue 2
                        fi
                    done
                    plVidList+=("${ytId}")
                done < <(yt-dlp --flat-playlist --no-warnings --print "%(id)s" "https://www.youtube.com/playlist?list=${plId}")
            fi
            
            if [[ "${#plVidList[@]}" -eq "0" ]]; then
                printOutput "1" "Pulled [0] videos from playlist [https://www.youtube.com/playlist?list=${plId}] -- Is the URL valid and does the playlist contain videos? If so, is any necessary cookie file valid and not expired?"
                continue
            fi
            
            printOutput "4" "Pulled list of [${#plVidList[@]}] videos from playlist"
            
            # Is the playlist already in our database?
            dbReply="$(sqDb "SELECT COUNT(1) FROM source_playlists WHERE ID = '${plId}';")"
            if [[ "${dbReply}" -eq "0" ]]; then
                # It is not, add it
                printOutput "4" "Initializing playlist in database"
                # Make a note that this is a new playlist, so we can initialize it in Plex
                updatePlaylist["_${plId}"]="true"
                
                playlistToDb "${plId}"
                
                # Add the order of items in the playlist_order table
                plPos="0"
                for ytId in "${plVidList[@]}"; do
                    # Make sure we haven't already added this item for this playlist
                    # This is a safety double check, and collections can't handle a single item repeating multiple times in a playlist
                    dbCount="$(sqDb "SELECT COUNT(1) FROM playlist_order WHERE ID = '${ytId//\'/\'\'}' AND PLAYLIST_KEY = '${plId//\'/\'\'}';")"
                    if [[ "${dbCount}" -ne "0" ]]; then
                        printOutput "5" "Video ID [${ytId}] already appears in playlist ID [${plId}] -- Skipping duplicate entry"
                        continue
                    fi
                    (( plPos++ ))
                    # Add it to the database
                    # Insert what we have
                    if sqDb "INSERT INTO playlist_order (ID, PLAYLIST_KEY, PLAYLIST_INDEX, UPDATED) VALUES ('${ytId//\'/\'\'}', '${plId//\'/\'\'}', ${plPos}, $(date +%s));"; then
                        printOutput "3" "Added video ID [${ytId}] in position [${plPos}] for playlist ID [${plId}] to database"
                    else
                        badExit "88" "Failed to add video ID [${ytId}] in position [${plPos}] for playlist ID [${plId}] to database"
                    fi
                done
            elif [[ "${dbReply}" -eq "1" ]]; then
                # It already exists in the database
                # Get a list of videos in the database for this playlist (in order)
                readarray -t dbVidList < <(sqDb "SELECT ID FROM playlist_order WHERE PLAYLIST_KEY = '${plId//\'/\'\'}' ORDER BY PLAYLIST_INDEX ASC;")
                
                # Start by comparing the number of items in each array
                if [[ "${#plVidList[@]}" -ne "${#dbVidList[@]}" ]]; then
                    # Item count mismatch.
                    # Make a note that we need to update this playlist in Plex
                    updatePlaylist["_${plId}"]="true"
                    # Dump the DB playlist info and re-add it.
                    printOutput "5" "Playlist item count [${#plVidList[@]}] does not match database item count [${#dbVidList[@]}]"
                    if sqDb "DELETE FROM playlist_order WHERE PLAYLIST_KEY = '${plId//\'/\'\'}';"; then
                        printOutput "5" "Removed playlist order due to item count mismatch for playlist ID [${plId}] from database"
                    else
                        badExit "89" "Failed to remove playlist order for playlist ID [${plId}] from database"
                    fi
                    # Add the order of items in the playlist_order table
                    plPos="0"
                    for ytId in "${plVidList[@]}"; do
                        (( plPos++ ))
                        # Add it to the database
                        # Insert what we have
                        if sqDb "INSERT INTO playlist_order (ID, PLAYLIST_KEY, PLAYLIST_INDEX, UPDATED) VALUES ('${ytId}', '${plId//\'/\'\'}', ${plPos}, $(date +%s));"; then
                            printOutput "5" "Added video ID [${ytId}] in position [${plPos}] for playlist ID [${plId}] to database"
                        else
                            badExit "90" "Failed to add video ID [${ytId}] in position [${plPos}] for playlist ID [${plId}] to database"
                        fi
                    done
                else
                    # Item count matches, verify that positions are correct
                    for key in "${!plVidList[@]}"; do
                        printOutput "5" "Verifying position of [${plVidList[${key}]}] against [${dbVidList[${key}]}]"
                        if ! [[ "${plVidList[${key}]}" == "${dbVidList[${key}]}" ]]; then
                            # Does not match.
                            printOutput "4" "Playlist order mismatch found - Reorganizing playlist order"
                            # Make a note that we need to update this playlist in Plex
                            updatePlaylist["_${plId}"]="true"
                            # Dump the DB playlist info and re-add it.
                            printOutput "5" "Playlist key [${key}] with video ID [${plVidList[${key}]}] does not match database video ID [${dbVidList[${key}]}]"
                            if sqDb "DELETE FROM playlist_order WHERE PLAYLIST_KEY = '${plId//\'/\'\'}';"; then
                                printOutput "5" "Removed playlist order due to order mismatch for playlist ID [${plId}] from database"
                            else
                                badExit "91" "Failed to remove playlist order for playlist ID [${plId}] from database"
                            fi
                            # Add the order of items in the playlist_order table
                            plPos="0"
                            for ytId in "${plVidList[@]}"; do
                                (( plPos++ ))
                                # Add it to the database
                                # Insert what we have
                                if sqDb "INSERT INTO playlist_order (ID, PLAYLIST_KEY, PLAYLIST_INDEX, UPDATED) VALUES ('${ytId}', '${plId//\'/\'\'}', ${plPos}, $(date +%s));"; then
                                    printOutput "3" "Updated video ID [${ytId}] in position [${plPos}] for playlist ID [${plId}] to database"
                                else
                                    badExit "92" "Failed to add video ID [${ytId}] in position [${plPos}] for playlist ID [${plId}] to database"
                                fi
                            done
                            # We can break the loop, as we've just re-done the whole entry
                            break
                        fi
                    done    
                fi
            elif [[ "${dbReply}" -ge "2" ]]; then
                badExit "93" "Database query returned [${dbReply}] results -- Possible database corruption"
            else
                badExit "94" "Impossible condition"
            fi
            
            for i in "${plVidList[@]}"; do
                # Only process the video if it's not accounted for
                dbReply="$(sqDb "SELECT COUNT(1) FROM source_videos WHERE ID = '${i//\'/\'\'}';")"
                if [[ "${dbReply}" -eq "0" ]]; then
                    printOutput "4" "Queueing video ID [${i}] for database addition"
                    videoArr+=("${i}")
                elif [[ "${dbReply}" -eq "1" ]]; then
                    # Do we need to replace it based on sponsorblock availability?
                    if ! [[ "${sponsorblockEnable}" == "disable" ]]; then
                        # SponsorBlock is enabled, see if we should upgrade
                        if [[ "${sponsorblockRequire}" == "false" ]]; then
                            # Yes, we may need to upgrade
                            # See if we've already pulled the data for the video
                            sponsorblockAvailable="$(sqDb "SELECT SB_AVAILABLE FROM source_videos WHERE ID = '${i//\'/\'\'}';")"
                            if [[ "${sponsorblockAvailable%% \[*}" == "Found" ]]; then
                                # We can skip it
                                printOutput "5" "Skipping video ID [${i}] as SponsorBlock criteria already met"
                                continue
                            else
                                # It's not found, add the video to the queue
                                printOutput "4" "Queueing video ID [${i}] to check for SponsorBlock availability"
                                videoArr+=("${i}")
                            fi
                        fi
                    fi
                else
                    badExit "95" "Counted [${dbReply}] rows with video ID [${i}] -- Possible database corruption"
                fi
            done
        fi
        
        if [[ "${#videoArr[@]}" -ne "0" ]]; then
            printOutput "3" "Processing videos"
            # Iterate through our video list
            printOutput "3" "Found [${#videoArr[@]}] video ID's to be processed into database"
            n="1"
            for ytId in "${videoArr[@]}"; do
                printOutput "4" "Adding video ID [${ytId}] to database [Item ${n} of ${#videoArr[@]}]"
                if ! ytIdToDb "${ytId}"; then
                    printOutput "1" "Failed to add video ID [${ytId}] from source [${source##*/}] to database"
                fi
                if [[ "${markWatched}" == "true" && -z "${watchedArr[_${ytId}]}" ]]; then
                    printOutput "4" "Noting video ID [${ytId}] to be marked as 'Watched'"
                    watchedArr["_${ytId}"]="watched"
                fi
                (( n++ ))
            done
        fi
        
    done < <(find "${realPath%/*}/${scriptName%.bash}.sources/" -type f -name "*.env" | sort -n -k1,1)
fi

if [[ "${#reindexArr[@]}" -ne "0" ]]; then
    printOutput "3" "############## Updating re-indexed files ##############"
    for ytId in "${!reindexArr[@]}"; do
        ytId="${ytId#_}"
        channelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        channelPath="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
        channelNameClean="$(sqDb "SELECT NAME_CLEAN FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
        vidYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        vidIndex="$(sqDb "SELECT EP_INDEX FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        vidTitleClean="$(sqDb "SELECT TITLE_CLEAN FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # Move the old file to the new destination
        if ! mv "${reindexArr[_${ytId}]}" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4"; then
            printOutput "1" "Failed to move video ID [${ytId}] from [${reindexArr[_${ytId}]}] to [${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4]"
        fi
        if [[ -e "${reindexArr[_${ytId}]%mp4}jpg" ]]; then
            if ! mv "${reindexArr[_${ytId}]%mp4}jpg" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"; then
                printOutput "1" "Failed to move thumbnail for video ID [${ytId}] from [${reindexArr[_${ytId}]%mp4}jpg] to [${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg]"
            fi
        fi
        printOutput "3" "Successfully re-indexed video ID [${ytId}]"
    done
fi

readarray -t importArr < <(sqDb "SELECT ID FROM source_videos WHERE STATUS = 'import';")
if [[ "${#importArr[@]}" -ne "0" ]]; then
    printOutput "3" "################### Importing files ###################"
    n="1"
    for ytId in "${importArr[@]}"; do
        printOutput "3" "Processing video ID [${ytId}] [Item ${n} of ${#importArr[@]}]"
        (( n++ ))
        # Get the file origin location
        moveFrom="$(sqDb "SELECT ERROR FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # Make sure the file origin actually exists
        if ! [[ -e "${moveFrom}" ]]; then
            printOutput "1" "Import file [${moveFrom}] does not appear to exist -- Skipping"
            continue
        fi
        
        # Build our move-to path
        channelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${channelId}" ]]; then
            badExit "96" "Unable to determine channel ID for video ID [${ytId}] -- Possible database corruption"
        fi
        channelPath="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
        if [[ -z "${channelPath}" ]]; then
            badExit "97" "Unable to determine channel path for video ID [${ytId}] -- Possible database corruption"
        fi
        channelName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
        if [[ -z "${channelName}" ]]; then
            badExit "98" "Unable to determine channel name for video ID [${ytId}] -- Possible database corruption"
        fi
        channelNameClean="$(sqDb "SELECT NAME_CLEAN FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
        if [[ -z "${channelNameClean}" ]]; then
            badExit "99" "Unable to determine clean channel name for video ID [${ytId}] -- Possible database corruption"
        fi
        vidYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidYear}" ]]; then
            badExit "100" "Unable to determine video year for video ID [${ytId}] -- Possible database corruption"
        fi
        vidIndex="$(sqDb "SELECT EP_INDEX FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidIndex}" ]]; then
            badExit "101" "Unable to determine video index for video ID [${ytId}] -- Possible database corruption"
        fi
        vidTitle="$(sqDb "SELECT TITLE FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidTitle}" ]]; then
            badExit "102" "Unable to determine video title for video ID [${ytId}] -- Possible database corruption"
        fi
        vidTitleClean="$(sqDb "SELECT TITLE_CLEAN FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidTitleClean}" ]]; then
            badExit "103" "Unable to determine clean video title for video ID [${ytId}] -- Possible database corruption"
        fi
        
        # We've got all the things we need, now make sure the destination folder(s) we need exist.
        # Check if the base channel directory exists
        if ! [[ -d "${outputDir}/${channelPath}" ]]; then
            # Create it
            if ! mkdir -p "${outputDir}/${channelPath}"; then
                badExit "104" "Unable to create directory [${outputDir}/${channelPath}]"
            fi
            newVideoDir+=("${channelId}")
            
            # Create the series image
            makeShowImage "${channelId}"
        fi
        
        if ! [[ -d "${outputDir}/${channelPath}/Season ${vidYear}" ]]; then
            # Create the season directory
            if ! mkdir -p "${outputDir}/${channelPath}/Season ${vidYear}"; then
                badExit "105" "Unable to create season directory [${outputDir}/${channelPath}/Season ${vidYear}"
            fi
            
            # Create the season image
            makeShowImage "${channelId}" "${vidYear}"
        fi
        
        # Move our imported file
        if ! mv "${moveFrom}" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4"; then
            printOutput "1" "Failed to move video ID [${ytId}] from tmp dir [${tmpDir}] to destination [${channelPath}/Season ${vidYear}]"
            vidStatus="import_failed"
        else
            vidStatus="downloaded"
        fi
        
        # If we have a thumbnail
        if [[ -e "${moveFrom%mp4}jpg" ]]; then
            # Move it
            if ! mv "${moveFrom%mp4}jpg" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"; then
                printOutput "1" "Failed to move thumbnail for video ID [${ytId}] from tmp dir [${tmpDir}] to destination [${channelPath}/Season ${vidYear}]"
            fi
        fi
        if ! [[ -e "${moveFrom%mp4}jpg" ]]; then
            # Still don't have one, so get it from web
            printOutput "5" "Pulling thumbail from web"
            thumbUrl="$(sqDb "SELECT THUMBNAIL FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
            callCurlDownload "${thumbUrl}" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"
            if ! [[ -e "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg" ]]; then
                printOutput "1" "Failed to get thumbnail for video ID [${ytId}]"
            fi
        fi

        if [[ -e "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4" ]]; then
            printOutput "3" "Imported video [${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}]"
            if ! sqDb "UPDATE source_videos SET STATUS = '${vidStatus}', ERROR = NULL, UPDATED = '$(date +%s)' WHERE ID = '${ytId//\'/\'\'}';"; then
                badExit "106" "Unable to update status to [${vidStatus}] for video ID [${ytId}]"
            fi
        else
            printOutput "1" "Failed to import [${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}]"
            if ! sqDb "UPDATE source_videos SET STATUS = '${vidStatus}', UPDATED = '$(date +%s)' WHERE ID = '${ytId//\'/\'\'}';"; then
                badExit "107" "Unable to update status to [${vidStatus}] for video ID [${ytId}]"
            fi
        fi
    done
fi

# Deal with skipped videos
readarray -t skippedVids < <(sqDb "SELECT ID FROM source_videos WHERE STATUS = 'waiting';")
if [[ "${#skippedVids[@]}" -ne "0" ]]; then
    printOutput "3" "########### Checking previously live videos ###########"
    # Update their status in the database
    loopNum="0"
    for ytId in "${skippedVids[@]}"; do
        (( loopNum++ ))
        printOutput "3" "Updating metadata for video ID [${ytId}] [Item ${loopNum} of ${#skippedVids[@]}]"
        
        # We need the existing global variables for this video
        # We have the video format option
        outputResolution="$(sqDb "SELECT FORMAT FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # We have the include shorts option
        includeShorts="$(sqDb "SELECT SHORTS FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # We have the include live option
        includeLiveBroadcasts="$(sqDb "SELECT LIVE FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # We have the mark watched option
        markWatched="$(sqDb "SELECT WATCHED FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # We have the sponsor block enable option
        sponsorblockEnable="$(sqDb "SELECT SB_ENABLE FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # We have the sponsor block require option
        sponsorblockRequire="$(sqDb "SELECT SB_REQUIRE FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        
        # Go ahead and update the database entry
        ytIdToDb "${ytId}"
    done
fi

# Make sure we actually have downloads to process
readarray -t downloadQueue < <(sqDb "SELECT ID FROM source_videos WHERE STATUS = 'queued';")
if [[ "${#downloadQueue[@]}" -ne "0"  && "${skipDownload}" -eq "0" ]]; then
    n="1"
    printOutput "3" "############# Processing queued downloads #############"
    for ytId in "${downloadQueue[@]}"; do
        printOutput "4" "Downloading video ID [${ytId}] [Item ${n} of ${#downloadQueue[@]}]"
        (( n++ ))
        
        # Clean out our tmp dir, as if we previously failed due to out of space, we don't want everything else after to fail
        rm -rf "${tmpDir:?}/"*
        
        # Get the video title
        vidTitle="$(sqDb "SELECT TITLE FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${vidTitle}" ]]; then
            badExit "108" "Retrieved blank title for video ID [${ytId}]"
        fi
        
        # Get the sanitized video title
        vidTitleClean="$(sqDb "SELECT TITLE_CLEAN FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${vidTitleClean}" ]]; then
            badExit "109" "Retrieved blank clean title for video ID [${ytId}]"
        fi
        
        # Get the channel ID
        channelId="$(sqDb "SELECT CHANNEL_ID FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${channelId}" ]]; then
            badExit "110" "Retrieved blank channel ID for video ID [${ytId}]"
        fi
        
        # Get the channel name
        channelName="$(sqDb "SELECT NAME FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${channelName}" ]]; then
            badExit "111" "Retrieved blank channel name for channel ID [${channelId}]"
        fi
        
        # Get the clean channel name
        channelNameClean="$(sqDb "SELECT NAME_CLEAN FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${channelNameClean}" ]]; then
            badExit "112" "Retrieved blank clean channel name for channel ID [${channelId}]"
        fi
        
        # Get the channel path
        channelPath="$(sqDb "SELECT PATH FROM source_channels WHERE ID = '${channelId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${channelPath}" ]]; then
            badExit "113" "Retrieved blank channel path for channel ID [${channelId}]"
        fi
        
        # Get the season year
        vidYear="$(sqDb "SELECT YEAR FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${vidYear}" ]]; then
            badExit "114" "Retrieved blank year for video ID [${ytId}]"
        fi
        
        # Get the episode index
        vidIndex="$(sqDb "SELECT EP_INDEX FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${vidIndex}" ]]; then
            badExit "115" "Retrieved blank index for video ID [${ytId}]"
        fi
        
        # Get the desired resolution
        videoOutput="$(sqDb "SELECT FORMAT FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${videoOutput}" ]]; then
            badExit "116" "Retrieved blank video format for video ID [${ytId}]"
        fi
        
        # Get the sponsor block status
        sponsorblockOpts="$(sqDb "SELECT SB_ENABLE FROM source_videos WHERE ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${sponsorblockOpts}" ]]; then
            badExit "117" "Retrieved blank sponsor block setting for video ID [${ytId}]"
        fi
        
        # Check if the base channel directory exists
        if ! [[ -d "${outputDir}/${channelPath}" ]]; then
            # Create it
            if ! mkdir -p "${outputDir}/${channelPath}"; then
                badExit "118" "Unable to create directory [${outputDir}/${channelPath}]"
            fi
            newVideoDir+=("${channelId}")
            
            # Create the series image
            makeShowImage "${channelId}"
        fi
        
        # Check if the season directory exists
        if ! [[ -d "${outputDir}/${channelPath}/Season ${vidYear}" ]]; then
            # Create it
            if ! mkdir -p "${outputDir}/${channelPath}/Season ${vidYear}"; then
                badExit "118" "Unable to create directory [${outputDir}/${channelPath}/Season ${vidYear}]"
            fi
            
            # Create the season image
            makeShowImage "${channelId}" "${vidYear}"
        fi
        
        # Download the video
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
        dlpOpts+=("--no-progress" "--retry-sleep 10" "--merge-output-format mp4" "--convert-thumbnails jpg" "--embed-subs" "--embed-metadata" "--embed-chapters" "--sleep-requests 1.25")
        if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
            startTime="$(($(date +%s%N)/1000000))"
            while read -r z; do
                dlpOutput+=("${z}")
                if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                    dlpError="${z}"
                fi
            done < <(yt-dlp -vU ${dlpOpts[*]} --cookies "${cookieFile}" --sleep-requests 1.25 -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                              # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
            endTime="$(($(date +%s%N)/1000000))"
        else
            startTime="$(($(date +%s%N)/1000000))"
            while read -r z; do
                dlpOutput+=("${z}")
                if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                    dlpError="${z}"
                fi
            done < <(yt-dlp -vU ${dlpOpts[*]} --sleep-requests 1.25 -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
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
                done < <(yt-dlp -vU ${dlpOpts[*]} --cookies "${cookieFile}" --sleep-requests 1.25 -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                  # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                endTime="$(($(date +%s%N)/1000000))"
            else
                while read -r z; do
                startTime="$(($(date +%s%N)/1000000))"
                    dlpOutput+=("${z}")
                    if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                        dlpError="${z}"
                    fi
                done < <(yt-dlp -vU ${dlpOpts[*]} --sleep-requests 1.25 -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
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
                done < <(yt-dlp -vU ${dlpOpts[*]} --cookies "${cookieFile}" --sleep-requests 1.25 -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                  # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                endTime="$(($(date +%s%N)/1000000))"
            else
                startTime="$(($(date +%s%N)/1000000))"
                while read -r z; do
                    dlpOutput+=("${z}")
                    if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
                        dlpError="${z}"
                    fi
                done < <(yt-dlp -vU ${dlpOpts[*]} --sleep-requests 1.25 -o "${tmpDir}/${ytId}.mp4" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
                                  # ^^^^^^^^^^^^^-Must be unquoted, or it'll break yt-dlp
                endTime="$(($(date +%s%N)/1000000))"
            fi
        fi
        # Make sure the video downloaded
        if ! [[ -e "${tmpDir}/${ytId}.mp4" ]]; then
            printOutput "1" "Download of video video ID [${ytId}] failed"
            if [[ -n "${dlpError}" ]]; then
                printOutput "1" "Found yt-dlp error message [${dlpError}]"
            fi
            printOutput "1" "=========== Begin yt-dlp log ==========="
            for z in "${dlpOutput[@]}"; do
                printOutput "1" "${z}"
            done
            printOutput "1" "============ End yt-dlp log ============"
            printOutput "1" "Skipping video ID [${ytId}]"
            if ! sqDb "UPDATE source_videos SET STATUS = 'failed', UPDATED = '$(date +%s)' WHERE ID = '${ytId//\'/\'\'}';"; then
                badExit "119" "Unable to update status to [failed] for video ID [${ytId}]"
            fi
            if [[ "${dlpError}" == "ERROR: [youtube] ${ytId}: Join this channel from your computer or Android app to get access to members-only content like this video." ]]; then
                # It's a members-only video. Mark it as 'skipped' rather than 'failed'.                        
                if ! sqDb "UPDATE source_videos SET TYPE = 'members_only', STATUS = 'skipped', ERROR = 'Video is members only', UPDATED = '$(date +%s)' WHERE ID = '${ytId//\'/\'\'}';"; then
                    badExit "120" "Unable to update status to [skipped] due to being a members only video for video ID [${ytId}]"
                fi
            elif [[ "${dlpError}" == "ERROR: [youtube] ${ytId}: This live stream recording is not available." ]]; then
                # It's a previous live broadcast whose recording is not (and won't) be available
                if ! sqDb "UPDATE source_videos SET TYPE = 'hidden_broadcast', STATUS = 'skipped', ERROR = 'Video is a previous live broadcast with unavailable stream', UPDATED = '$(date +%s)' WHERE ID = '${ytId//\'/\'\'}';"; then
                    badExit "121" "Unable to update status to [skipped] due to being a live broadcast with unavailable stream video for video ID [${ytId}]"
                fi
            else
                # Failed for some other reason                       
                if ! sqDb "UPDATE source_videos SET STATUS = 'failed', ERROR = '${dlpOutput[*]//\'/\'\'}', UPDATED = '$(date +%s)' WHERE ID = '${ytId//\'/\'\'}';"; then
                    badExit "122" "Unable to update status to [failed] for video ID [${ytId}]"
                fi
            fi
            # Throttle if it's not the last item
            if [[ "${n}" -lt "${#downloadQueue[@]}" ]]; then
                throttleDlp
            fi
            continue
        else
            printOutput "4" "File downloaded [$(timeDiff "${startTime}" "${endTime}")]"
        fi
        
        # Get the thumbnail
        callCurlDownload "https://img.youtube.com/vi/${ytId}/maxresdefault.jpg" "${tmpDir}/${ytId}.jpg"
        
        if ! [[ -e "${tmpDir}/${ytId}.jpg" ]]; then
            printOutput "1" "Download of thumbnail for video video ID [${ytId}] failed"
        fi

        # Make sure we can move the video from tmp to destination
        if ! mv "${tmpDir}/${ytId}.mp4" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4"; then
            printOutput "1" "Failed to move video ID [${ytId}] from tmp dir [${tmpDir}] to destination [${channelPath}/Season ${vidYear}] -- Skipping"
            continue
        else
            # Make sure we can move the thumbnail from tmp to destination
            if ! mv "${tmpDir}/${ytId}.jpg" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"; then
                printOutput "1" "Failed to move thumbnail for video ID [${ytId}] from tmp dir [${tmpDir}] to destination [${channelPath}/Season ${vidYear}] -- Skipping"
                continue
            fi
        fi

        # Safety check on the move
        if [[ -e "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4" ]]; then
            printOutput "3" "Successfully imported video [${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}]"
            if ! sqDb "UPDATE source_videos SET STATUS = 'downloaded', UPDATED = '$(date +%s)' WHERE ID = '${ytId//\'/\'\'}';"; then
                badExit "123" "Unable to update status to [downloaded] for video ID [${ytId}]"
            fi
        else
            printOutput "1" "Failed to download [${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}]"
            if ! sqDb "UPDATE source_videos SET STATUS = 'failed', UPDATED = '$(date +%s)' WHERE ID = '${ytId//\'/\'\'}';"; then
                badExit "124" "Unable to update status to [failed] for video ID [${ytId}]"
            fi
        fi
        
        # Grab the subtitles
        downloadSubs "${ytId}"

        # If we should mark a video as watched, add it to an array to deal with later
        if [[ "${markWatched}" == "true" ]]; then
            if [[ -z "${watchedArr["_${ytId}"]}" ]]; then
                watchedArr["_${ytId}"]="watched"
            else
                if [[ "${watchedArr["_${ytId}"]}" == "watched" ]]; then
                    printOutput "5" "Video ID [${ytId}] already marked as [watched]"
                else
                    printAngryWarning
                    printOutput "2" "Attempted to overwrite video ID [${ytId}] watch status of [${watchedArr["_${ytId}"]}] with [watched]"
                fi
            fi
        fi
        
        # Send a telegram message, if allowed
        if [[ -n "${telegramBotId}" && -n "${telegramChannelId}" ]]; then
            printOutput "4" "Sending Telegram message"
            if [[ -e "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg" ]]; then
                printOutput "5" "Sending Telegram image message"
                sendTelegramImage "<b>YouTube Video Downloaded</b>${lineBreak}${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"
            else
                printOutput "5" "Sending Telegram text message"
                sendTelegramMessage "<b>YouTube Video Downloaded</b>${lineBreak}${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}"
            fi
        fi
        
        # Throttle if it's not the last item
        if [[ "${n}" -lt "${#downloadQueue[@]}" ]]; then
            throttleDlp
        fi
    done
fi

vidTotal="$(( ${#reindexArr[@]} + ${#importArr[@]} + ${#downloadQueue[@]} ))"
if [[ "${vidTotal}" -ne "0" ]]; then
    refreshSleep="$(( vidTotal * 3 ))"
    if [[ "${refreshSleep}" -lt "30" ]]; then
        refreshSleep="30"
    elif [[ "${refreshSleep}" -gt "300" ]]; then
        refreshSleep="300"
    fi
    refreshLibrary "${libraryId}"
    printOutput "3" "Sleeping for [${refreshSleep}] seconds to give the Plex Scanner time to work"
    sleep "${refreshSleep}"
fi

if [[ "${#newVideoDir[@]}" -ne "0" ]]; then
    printOutput "3" "############ Initializing channel metadata ############"
    printOutput "3" "Found [${#newVideoDir[@]}] new series to set metadata for"
    for channelId in "${newVideoDir[@]}"; do
        printOutput "3" "Updating metadata for channel ID [${channelId}]"
        
        # Search the PMS library for the rating key of the series
        # This will also save the rating key to the database (Set series rating key)
        setSeriesRatingKey "${channelId}"
        # We now have ${showRatingKey} set
        
        # Update the series metadata
        setSeriesMetadata "${showRatingKey}"
    done
fi

if [[ "${#watchedArr[@]}" -ne "0" ]]; then
    printOutput "3" "############### Correting watch status ################"
    for ytId in "${!watchedArr[@]}"; do
        printOutput "4" "Setting watched status [${watchedArr[${ytId}]}] for video ID [${ytId#_}]"
        if ! setWatchStatus "${ytId#_}"; then
            printOutput "1" "Failed to set watch status for video ID [${ytId#_}]"
        fi
    done
fi

if [[ "${#updatePlaylist[@]}" -ne "0" ]]; then
    # For each playlist ID
    for plId in "${!updatePlaylist[@]}"; do
        plId="${plId#_}"
        
        # Get the title of the playlist
        plTitle="$(sqDb "SELECT TITLE FROM source_playlists WHERE ID = '${plId//\'/\'\'}';")"
        
        printOutput "3" "Processing playlist ID [${plId}] [${plTitle}]"
        # Get a list of the videos in the playlist, in order
        # We're going to start it from 1, because that makes debugging positioning easier on my brain
        unset plVidList
        plVidList[0]="null"
        while read -r ytId; do
            # We only care about it if it's downloaded
            dbVidStatus="$(sqDb "SELECT STATUS FROM source_videos WHERE ID = '${ytId}';")"
            if [[ "${dbVidStatus}" == "downloaded" ]]; then
                # Define titles
                defineTitle "${ytId}"
                plVidList+=("${ytId}")
            fi
        done < <(sqDb "SELECT ID FROM playlist_order WHERE PLAYLIST_KEY = '${plId}' ORDER BY PLAYLIST_INDEX ASC;")
        unset plVidList[0]
        for ii in "${!plVidList[@]}"; do
            printOutput "5" "           plVidList | ${ii} => ${plVidList[${ii}]} [${titleArr[_${plVidList[${ii}]}]}]"
        done
        
        # Get the visibility of the playlist
        plVis="$(sqDb "SELECT VISIBILITY FROM source_playlists WHERE ID = '${plId//\'/\'\'}';")"
        if [[ "${plVis}" == "public" ]]; then
            # Treat is as a collection
            # Check to see if the collection exists or not
            callCurlGet "${plexAdd}/library/sections/${libraryId}/collections?X-Plex-Token=${plexToken}"
            collectionRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@title\" == \"${plTitle}\" ) .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -n "${collectionRatingKey}" ]]; then
                printOutput "5" "Playlist ID [${plId}] appears to already exist under rating key [${collectionRatingKey}] -- Skipping creation"

                # Update the description
                collectionUpdate "${plId}" "${collectionRatingKey}"
                
                # Check for any items that need removing
                collectionDelete "${collectionRatingKey}"
                
                # Check for any items that need adding
                collectionAdd "${collectionRatingKey}"
                
                # Sort the collection
                collectionSort "${collectionRatingKey}"
            else
                printOutput "3" "Creating collection [${plTitle}]"
                # Encode our collection title
                plTitleEncoded="$(rawUrlEncode "${plTitle}")"
                
                # Get our first item's rating key to seed the collection
                getFileRatingKey "${plVidList[1]}"
            
                # Create the collection
                callCurlPost "${plexAdd}/library/collections?type=4&title=${plTitleEncoded}&smart=0&uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${ratingKey}&sectionId=${libraryId}&X-Plex-Token=${plexToken}"
                
                # Retrieve the rating key
                collectionRatingKey="$(yq -p xml ".MediaContainer.Directory.\"+@ratingKey\"" <<<"${curlOutput}")"
                
                # Verify it
                if [[ -z "${collectionRatingKey}" ]]; then
                    printOutput "1" "Received no output for video collection rating key for playlist ID [${plId}] on creation -- Skipping"
                    continue
                elif ! [[ "${collectionRatingKey}" =~ ^[0-9]+$ ]]; then
                    printOutput "1" "Received non-interger [${collectionRatingKey}] for video collection rating key for playlist ID [${plId}] on creation -- Skipping"
                else
                    printOutput "3" "Created collection [${plTitle}] successfully"
                    printOutput "5" "Seeded collection rating key [${collectionRatingKey}] for playlist ID [${plId}] with video ID [${plVidList[1]}] via rating key [${ratingKey}]"
                fi
            
                # Set the order to 'Custom'
                if callCurlPut "${plexAdd}/library/metadata/${collectionRatingKey}/prefs?collectionSort=2&X-Plex-Token=${plexToken}"; then
                    printOutput "4" "Video collection [${collectionRatingKey}] order set to 'Custom'"
                else
                    printOutput "1" "Unable to change video collection [${collectionRatingKey}] order to 'Custom' -- Skipping"
                    continue
                fi

                # Update the description
                collectionUpdate "${plId}" "${collectionRatingKey}"
            
                # Add the rest of the videos
                # Start from element 2, as we already added element 1
                for ytId in "${plVidList[@]:2}"; do
                    getFileRatingKey "${ytId}"
                    if callCurlPut "${plexAdd}/library/collections/${collectionRatingKey}/items?uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${ratingKey}&X-Plex-Token=${plexToken}"; then
                        printOutput "4" "Added video ID [${ytId}] to collection [${collectionRatingKey}]"
                    else
                        printOutput "1" "Failed to add [${ytId}] to collection [${collectionRatingKey}]"
                    fi
                done
            
                # Verify the order, which seems to get mixed up on creation
                collectionSort "${collectionRatingKey}"
            fi
        elif [[ "${plVis}" == "private" ]]; then
            # Treat it as a playlist
            # Check to see if the playlist exists or not
            callCurlGet "${plexAdd}/playlists?X-Plex-Token=${plexToken}"
            playlistRatingKey="$(yq -p xml ".MediaContainer.Playlist | ([] + .) | .[] | select ( .\"+@title\" == \"${plTitle}\" ) .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -n "${playlistRatingKey}" ]]; then
                # Already exists
                printOutput "5" "Playlist ID [${plId}] appears to already exist under rating key [${playlistRatingKey}] -- Skipping creation"

                # Update the description
                playlistUpdate "${plId}" "${playlistRatingKey}"
                
                # Check for any items that need removing
                playlistDelete "${playlistRatingKey}"
                
                # Check for any items that need adding
                playlistAdd "${playlistRatingKey}"
                
                # Sort the collection
                playlistSort "${playlistRatingKey}"
            else
                # Does not exist
                printOutput "3" "Creating video playlist [${plTitle}]"
            
                # Encode our playlist title
                playlistTitleEncoded="$(rawUrlEncode "${plTitle}")"
                
                # Get our first item's rating key to seed the playlist
                getFileRatingKey "${plVidList[1]}"
                
                # Create the playlist
                callCurlPost "${plexAdd}/playlists?type=video&title=${playlistTitleEncoded}&smart=0&uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${ratingKey}&X-Plex-Token=${plexToken}"
                
                # Retrieve the rating key
                playlistRatingKey="$(yq -p xml ".MediaContainer.Playlist.\"+@ratingKey\"" <<<"${curlOutput}")"
                # Verify it
                if [[ -z "${playlistRatingKey}" ]]; then
                    printOutput "1" "Received no output for playlist rating key for playlist ID [${plId}] on creation -- Skipping"
                    continue
                elif ! [[ "${playlistRatingKey}" =~ ^[0-9]+$ ]]; then
                    badExit "125" "Received non-interger [${playlistRatingKey}] for playlist rating key for playlist ID [${plId}] on creation -- Skipping"
                else
                    printOutput "3" "Created playlist [${plTitle}] successfully"
                    printOutput "4" "Added file ID [${plVidList[1]}] via rating key [${ratingKey}] to playlist [${playlistRatingKey}]"
                fi
                
                # Update the playlist info
                playlistUpdate "${plId}" "${playlistRatingKey}"
                
                # Add the rest of the videos
                # Start from element 1, as we already added element 0
                for ytId in "${plVidList[@]:2}"; do
                    getFileRatingKey "${ytId}"
                    if callCurlPut "${plexAdd}/playlists/${playlistRatingKey}/items?uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${ratingKey}&X-Plex-Token=${plexToken}"; then
                        printOutput "4" "Added file ID [${ytId}] to playlist [${playlistRatingKey}]"
                    else
                        printOutput "1" "Failed to add [${ytId}] to playlist [${playlistRatingKey}]"
                    fi
                done
                
                # Fix the order
                playlistSort "${playlistRatingKey}"
            fi
        else
            printOutput "1" "Received unexpected visibility [${plVis}] for playlist ID [${plId}] -- Skipping"
            continue
        fi
    done
fi

cleanExit
