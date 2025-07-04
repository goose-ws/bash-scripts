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
# 2025-01-05
# Removed YT key rotations, as that breaks their TOS
# Added Discord notifications
# Added private Playlist functionality, but still need to fix sorting
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
if [[ -z "${BASH_VERSINFO[0]}" || "${BASH_VERSINFO[0]}" -lt "4" ]]; then
    echo "This script requires Bash version 4 or greater"
    exit 255
fi

# Dependency check
depsArr=("awk" "basename" "chmod" "cmp" "convert" "curl" "date" "docker" "ffmpeg" "find" "grep" "identify" "mkdir" "mktemp" "mv" "printf" "realpath" "shuf" "sort" "sqlite3" "xxd" "yq" "yt-dlp")
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
colorRed="\033[1;31m"
colorGreen="\033[1;32m"
colorYellow="\033[1;33m"
colorBlue="\033[1;34m"
colorPurple="\033[1;35m"
colorCyan="\033[1;36m"
colorReset="\033[0m"
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

echo -e "
${colorRed}
                      ███╗   ███╗ █████╗ ██████╗ ███╗   ██╗███████╗███████╗███████╗
                      ████╗ ████║██╔══██╗██╔══██╗████╗  ██║██╔════╝██╔════╝██╔════╝
                      ██╔████╔██║███████║██║  ██║██╔██╗ ██║█████╗  ███████╗███████╗
                      ██║╚██╔╝██║██╔══██║██║  ██║██║╚██╗██║██╔══╝  ╚════██║╚════██║
                      ██║ ╚═╝ ██║██║  ██║██████╔╝██║ ╚████║███████╗███████║███████║
                      ╚═╝     ╚═╝╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═══╝╚══════╝╚══════╝╚══════╝
${colorReset}
                    Media Archival & Download, Nightmarishly Engineered Shell Script
"

#############################
##    Standard Functions   ##
#############################
function printOutput {
if ! [[ "${1}" =~ ^[0-9]+$ ]]; then
    echo -e "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   [${colorRed}error${colorReset}] Invalid message level [${1}] passed to printOutput function" >&2
    return 1
fi
if [[ -z "${2}" ]]; then
    echo -e "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   [${colorRed}error${colorReset}] No message to print passed to printOutput function" >&2
    return 1
fi

case "${1}" in
    0) logLevel="[${colorRed}reqrd${colorReset}]";; # Required
    1) logLevel="[${colorRed}error${colorReset}]";; # Errors
    2) logLevel="[${colorYellow}warn${colorReset}] ";; # Warnings
    3) logLevel="[${colorGreen}info${colorReset}] ";; # Informational
    4) logLevel="[${colorCyan}verb${colorReset}] ";; # Verbose
    5) logLevel="[${colorPurple}DEBUG${colorReset}]";; # Super Secret Very Excessive Debug Mode
esac
if [[ "${1}" -le "${outputVerbosity}" ]]; then
    if [[ "${1}" -eq "1" ]]; then
        echo -e "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   ${logLevel} ${2}" >&2
        errorArr+=("${2}")
    else
        echo -e "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   ${logLevel} ${2}"
    fi
fi
}

function progressBar {
if [[ -t 1 ]]; then
    progTotal=" $(( ${1} * 100 / ${2} ))"
    progDone="$(( ( progTotal * 4 ) / 10 ))"
    progLeft="$(( 40 - progDone ))"
    progFill="$(printf "%${progDone}s")"
    progEmpty="$(printf "%${progLeft}s")"
    printf "\r${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   [${colorPurple}prog${colorReset}]  [${progFill// /#}${progEmpty// /-}] ${progTotal}%% [${1}/${2}]  "
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
retryCount=0
retryDelay=5
while [[ "${curlExitCode}" -eq "28" ]] && [[ "${retryDelay}" -le 30 ]]; do
    printOutput "2" "Curl timed out, waiting ${retryDelay} seconds then trying again (attempt ${retryCount})"
    sleep "${retryDelay}"
    if [[ -z "${2}" ]]; then
        curlOutput="$(curl -skL "${1}" 2>&1)"
    else
        curlOutput="$(curl -skL -A "${2}" "${1}" 2>&1)"
    fi
    curlExitCode="${?}"
    retryDelay="$(( retryDelay + 5 ))"
    retryCount="$(( retryCount + 1 ))"
done

if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    printOutput "1" "Curl output:"
    while read -r i; do
        printOutput "1" "${i}"
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
if [[ -z "${1}" ]]; then
    return 1
fi
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
if [[ -z "${1}" ]]; then
    printOutput "1" "No destination passed to send Telegram message to"
else
    local chanId="${1}"
fi
if [[ -z "${2}" ]]; then
    printOutput "1" "No message passed to send to Telegram"
    return 1
fi
# Message to send should be passed as function positional parameter #1
# We can pass an "Admin channel" as positional parameter #2 for the case of sending error messages
callCurlGet "https://api.telegram.org/bot${telegramBotId}/getMe"
if ! [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
    printOutput "1" "Telegram bot API check failed"
else
    printOutput "4" "Telegram bot API key authenticated [$(yq -p json ".result.username" <<<"${curlOutput}")]"
    callCurlGet "https://api.telegram.org/bot${telegramBotId}/getChat?chat_id=${chanId}"
    if [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
        printOutput "4" "Telegram channel authenticated [$(yq -p json ".result.title" <<<"${curlOutput}")]"
        msgEncoded="$(rawUrlEncode "${2}")"
        callCurlGet "https://api.telegram.org/bot${telegramBotId}/sendMessage?chat_id=${chanId}&parse_mode=html&text=${msgEncoded}"
        # Check to make sure Telegram returned a true value for ok
        if ! [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
            printOutput "1" "Failed to send Telegram message, API response:"
            printOutput "1" "-"
            while read -r i; do
                printOutput "1" "${i}"
            done < <(yq -p json "." <<<"${curlOutput}")
            printOutput "1" "-"
        else
            printOutput "4" "Telegram message sent successfully"
        fi
    else
        printOutput "1" "Telegram channel check failed"
    fi
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
# Destination should be passed as function positional parameter #1
# Message to send should be passed as function positional parameter #2
# Image path should be passed as funcion positonal parameter #3
if [[ -z "${1}" ]]; then
    printOutput "1" "No destination passed to send Telegram message to"
else
    local chanId="${1}"
fi
if [[ -z "${2}" ]]; then
    printOutput "1" "No message passed to send to Telegram"
    return 1
fi
if ! [[ -e "${3}" ]]; then
    printOutput "1" "Invalid image [${3}] passed to send to Telegram"
    return 1
else
    local image="${3}"
fi
if callCurlGet "https://api.telegram.org/bot${telegramBotId}/getMe"; then
    printOutput "5" "callCurlGet successfully called"
else
    printOutput "5" "callCurlGet failed"
fi
if ! [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
    printOutput "1" "Telegram bot API check failed"
else
    printOutput "4" "Telegram bot API key authenticated [$(yq -p json ".result.username" <<<"${curlOutput}")]"
    callCurlGet "https://api.telegram.org/bot${telegramBotId}/getChat?chat_id=${chanId}"
    if [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
        printOutput "4" "Telegram channel authenticated [$(yq -p json ".result.title" <<<"${curlOutput}")]"
        msgEncoded="$(rawUrlEncode "${2}")"
        callCurlPost "tgimage" "https://api.telegram.org/bot${telegramBotId}/sendPhoto" "${chanId}" "${msgEncoded}" "${image}"
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
fi
}

function sendDiscordImage {
# Webhook should be passed as functional positional parameter #1
# Message to send should be passed as functional positional parameter #2
# Image path should be passed as functional positional parameter #3
if [[ -z "${1}" ]]; then
    printOutput "5" "No Discord Webhook URL provided, unable to send Discord message"
    return 0
fi

# Make sure our message is not blank
if [[ -z "${2}" ]]; then
    printOutput "1" "No message passed to send to Discord"
    return 1
fi
# Make sure our image exists
if ! [[ -e "${3}" ]]; then
    printOutput "1" "Image file [${2}] does not appear to exist"
    return 1
fi

# Send it
# For callCurlPost:
# Positional parameter 2 is the URL
# Positional parameter 3 is the text
# Positional parameter 4 is the image
if callCurlPost "discordimage" "${1}" "${2}" "${3}"; then
    printOutput "5" "callCurlPost called successfully"
else
    printOutput "5" "callCurlPost failed"
fi
}

function apiCount {
# Notify of how many API calls were made
if [[ "${apiCallsYouTube}" -ne "0" ]]; then
    printOutput "4" "Made [${apiCallsYouTube}] API calls to YouTube"
    printOutput "4" "Costed [${totalUnits}] units in total | [${totalVideoUnits}] video | [${totalCaptionsUnits}] captions | [${totalChannelsUnits}] channels | [${totalPlaylistsUnits}] playlists"
fi
if [[ "${apiCallsSponsor}" -ne "0" ]]; then
    printOutput "4" "Made [${apiCallsSponsor}] API calls to SponsorBlock"
fi
}

function rawUrlEncode {
if [[ -z "${1}" ]]; then
    return 1
fi
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
if [[ -z "${1}" ]]; then
    return 1
fi
# Log the command we're executing to the database, for development purposes
# Execute the command
if sqOutput="$(sqlite3 "${sqliteDb}" "${1}" 2>&1)"; then
    if [[ -n "${sqOutput}" ]]; then
        echo "${sqOutput}"
    fi
else
    sqlite3 "${sqliteDb}" "INSERT INTO db_log (TIME, COMMAND, OUTPUT) VALUES ('$(date)', '${1//\'/\'\'}', '${sqOutput//\'/\'\'}');"
    if [[ -n "${sqOutput}" ]]; then
        echo "${sqOutput}"
    fi
    return 1
fi
}

function randomSleep {
# ${1} is minumum seconds, ${2} is maximum
# If no min/max set, min=5 max=30
if [[ -z "${1}" || -z "${2}" ]]; then
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

function downloadAudio {
# Make sure we were passed a file ID
if ! [[ "${1}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
    printOutput "1" "Invalid file ID [${1}] provided to download audio"
    return 1
fi
if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
    cookieArg="--cookies ${cookieFile}"
else
    cookieArg=""
fi

if [[ "${audioEnableSB}" == "remove" ]]; then
    # Get our flags
    audioCategorySB="$(sqDb "SELECT SPONSORBLOCK_FLAGS_AUDIO FROM config WHERE FILE_ID = '${1//\'/\'\'}';")"
    sponsorArg="--sponsorblock-remove ${audioCategorySB}"
else
    unset sponsorArg
fi

startTime="$(($(date +%s%N)/1000000))"

while read -r z; do
    dlpOutput+=("${z}")
    if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
        dlpError="${z}"
    fi
done < <(yt-dlp -vU ${cookieArg} ${sponsorArg} --sleep-requests 1.25 -f "bestaudio" -x --audio-format "${outputAudio}" -o "${tmpDir}/${1}.${outputAudio}" "https://www.youtube.com/watch?v=${1}" 2>&1)

endTime="$(($(date +%s%N)/1000000))"

# Retry #1 if throttled
if [[ "${dlpError}" == "ERROR: unable to download video data: HTTP Error 403: Forbidden" ]]; then
    printOutput "2" "IP throttling detected, taking a 2 minute break and then trying again [Retry 1]"
    sleep 120
    unset dlpOutput dlpError
    startTime="$(($(date +%s%N)/1000000))"

    while read -r z; do
        dlpOutput+=("${z}")
        if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
            dlpError="${z}"
        fi
    done < <(yt-dlp -vU ${cookieArg} ${sponsorArg} --sleep-requests 1.25 -f "bestaudio" -x --audio-format "${outputAudio}" -o "${tmpDir}/${1}.${outputAudio}" "https://www.youtube.com/watch?v=${1}" 2>&1)

    endTime="$(($(date +%s%N)/1000000))"
fi
# Retry #2 if throttled
if [[ "${dlpError}" == "ERROR: unable to download video data: HTTP Error 403: Forbidden" ]]; then
    printOutput "2" "IP throttling detected, taking a 2 minute break and then trying again [Retry 2]"
    sleep 120
    unset dlpOutput dlpError
    startTime="$(($(date +%s%N)/1000000))"

    while read -r z; do
        dlpOutput+=("${z}")
        if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
            dlpError="${z}"
        fi
    done < <(yt-dlp -vU ${cookieArg} ${sponsorArg} --sleep-requests 1.25 -f "bestaudio" -x --audio-format "${outputAudio}" -o "${tmpDir}/${1}.${outputAudio}" "https://www.youtube.com/watch?v=${1}" 2>&1)

    endTime="$(($(date +%s%N)/1000000))"

fi
# Make sure the audio downloaded
if ! [[ -e "${tmpDir}/${1}.${outputAudio}" ]]; then
    printOutput "1" "Download of audio file ID [${1}] failed"
    if [[ -n "${dlpError}" ]]; then
        printOutput "1" "Found yt-dlp error message [${dlpError}]"
    fi
    printOutput "1" "=========== Begin yt-dlp log ==========="
    for z in "${dlpOutput[@]}"; do
        printOutput "1" "${z}"
    done
    printOutput "1" "============ End yt-dlp log ============"
    printOutput "1" "Skipping file ID [${1}]"
    if ! sqDb "UPDATE media SET AUDIO_STATUS = 'failed', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        badExit "5" "Unable to update audio status to [failed] for file ID [${1}]"
    fi
    if [[ "${dlpError}" == "ERROR: [youtube] ${1}: Join this channel from your computer or Android app to get access to members-only content like this video." ]]; then
        # It's a members-only video. Mark it as 'skipped' rather than 'failed'.
        if ! sqDb "UPDATE media SET TYPE = 'members_only', AUDIO_STATUS = 'skipped', AUDIO_ERROR = 'Video is members only', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            badExit "6" "Unable to update audio status to [skipped] due to being a members only video for file ID [${1}]"
        fi
    elif [[ "${dlpError}" =~ ^"ERROR: [youtube] ${ytId}: This video is available to this channel's members on level".*$ ]]; then
        # It's a members-only video. Mark it as 'skipped' rather than 'failed'.
        if ! sqDb "UPDATE media SET TYPE = 'members_only', AUDIO_STATUS = 'skipped', AUDIO_ERROR = 'Video is members only', UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
            badExit "7" "Unable to update audio status to [skipped] due to being a members only video for file ID [${1}]"
        fi
    elif [[ "${dlpError}" == "ERROR: [youtube] ${1}: This live stream recording is not available." ]]; then
        # It's a previous live broadcast whose recording is not (and won't) be available
        if ! sqDb "UPDATE media SET TYPE = 'hidden_broadcast', AUDIO_STATUS = 'skipped', AUDIO_ERROR = 'Video is a previous live broadcast with unavailable stream', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            badExit "8" "Unable to update audio status to [skipped] due to being a live broadcast with unavailable stream video for file ID [${1}]"
        fi
    else
        # Failed for some other reason
        errorFormatted="$(printf "%s\n" "${dlpOutput[@]}")"
        if ! sqDb "UPDATE media SET AUDIO_STATUS = 'failed', AUDIO_ERROR = '${errorFormatted//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            badExit "9" "Unable to update audio status to [failed] for file ID [${1}]"
        fi
    fi
    # Throttle if it's not the last item
    if [[ "${n}" -lt "${#downloadQueue[@]}" ]]; then
        throttleDlp
    fi
    return 1
else
    printOutput "4" "File downloaded [$(timeDiff "${startTime}" "${endTime}")]"
    (( albumsDownloaded++ ))
fi
}

function updateConfig {
if ! [[ "${1}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
    printOutput "1" "Invalid file ID [${1}] passed to updateConfig function"
    return 1
fi

# See if it's already in our DB or not
local dbCount
dbCount="$(sqDb "SELECT COUNT(1) FROM config WHERE FILE_ID = '${1//\'/\'\'}';")"
if [[ "${dbCount}" -eq "0" ]]; then
    # We know it's a new record so we can just insert everything without checking previous values
    printOutput "5" "Initializing file ID [${1}] in database"
    if ! sqDb "INSERT INTO config (FILE_ID, CREATED, UPDATED) VALUES ('${1//\'/\'\'}', '$(date)', '$(date)');"; then
        printOutput "1" "Failed to initialize file ID [${1}] in database"
        return 1
    fi
    if ! sqDb "UPDATE config SET VIDEO_RESOLUTION = '${outputResolution//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "1" "Failed to set VIDEO_RESOLUTION for file ID [${1}] in database"
        return 1
    fi
    if ! sqDb "UPDATE config SET MARK_WATCHED = '${markWatched//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "1" "Failed to set MARK_WATCHED for file ID [${1}] in database"
        return 1
    fi
    if ! sqDb "UPDATE config SET ALLOW_SHORTS = '${includeShorts//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "1" "Failed to set ALLOW_SHORTS for file ID [${1}] in database"
        return 1
    fi
    if ! sqDb "UPDATE config SET ALLOW_LIVE = '${includeLiveBroadcasts//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "1" "Failed to set ALLOW_LIVE for file ID [${1}] in database"
        return 1
    fi
    if ! sqDb "UPDATE config SET SUBTITLE_LANGUAGES = '${subLanguages[*]//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "1" "Failed to set SUBTITLE_LANGUAGES for file ID [${1}] in database"
        return 1
    fi
    if ! sqDb "UPDATE config SET SPONSORBLOCK_ENABLED_VIDEO = '${videoEnableSB//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "1" "Failed to set SPONSORBLOCK_ENABLED_VIDEO for file ID [${1}] in database"
        return 1
    fi
    if [[ "${videoEnableSB}" =~ ^(mark|remove)$ ]]; then
        if ! sqDb "UPDATE config SET SPONSORBLOCK_REQUIRED_VIDEO = '${videoRequireSB//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "1" "Failed to set SPONSORBLOCK_REQUIRED_VIDEO for file ID [${1}] in database"
            return 1
        fi
        if ! sqDb "UPDATE config SET SPONSORBLOCK_FLAGS_VIDEO = '${videoCategorySB//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "1" "Failed to set SPONSORBLOCK_FLAGS_VIDEO for file ID [${1}] in database"
            return 1
        fi
    fi
    if [[ -n "${outputAudio}" ]]; then
        if ! sqDb "UPDATE config SET AUDIO_FORMAT = '${outputAudio//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "1" "Failed to set AUDIO_FORMAT for file ID [${1}] in database"
            return 1
        fi
        if ! sqDb "UPDATE config SET SPONSORBLOCK_ENABLED_AUDIO = '${audioEnableSB//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "1" "Failed to set SPONSORBLOCK_ENABLED_AUDIO for file ID [${1}] in database"
            return 1
        fi
        if [[ "${audioEnableSB}" == "remove" ]]; then
            if ! sqDb "UPDATE config SET SPONSORBLOCK_REQUIRED_AUDIO = '${audioRequireSB//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "1" "Failed to set SPONSORBLOCK_REQUIRED_AUDIO for file ID [${1}] in database"
                return 1
            fi
            if ! sqDb "UPDATE config SET SPONSORBLOCK_FLAGS_AUDIO = '${audioCategorySB//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "1" "Failed to set SPONSORBLOCK_FLAGS_AUDIO for file ID [${1}] in database"
                return 1
            fi
        fi
    fi

    if ! sqDb "UPDATE config SET SOURCE = '${source//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "1" "Failed to set SOURCE for file ID [${1}] in database"
        return 1
    fi
    printOutput "5" "Successfully initialized configuration for file ID [${1}]"
    return 0
fi

# If we're here, the entry is already initialized, so check and update config options as needed
# Update VIDEO_RESOLUTION
current_VIDEO_RESOLUTION=$(sqDb "SELECT VIDEO_RESOLUTION FROM config WHERE FILE_ID = '${1//\'/\'\'}'")
if ! [[ "${current_VIDEO_RESOLUTION}" == "${outputResolution}" ]]; then
    if ! sqDb "UPDATE config SET VIDEO_RESOLUTION = '${outputResolution//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "1" "Failed to update VIDEO_RESOLUTION for file ID [$1] in database"
        return 1
    fi
fi

# Update MARK_WATCHED
current_MARK_WATCHED=$(sqDb "SELECT MARK_WATCHED FROM config WHERE FILE_ID = '${1//\'/\'\'}'")
if ! [[ "${current_MARK_WATCHED}" == "${markWatched}" ]]; then
    if ! sqDb "UPDATE config SET MARK_WATCHED = '${markWatched//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "1" "Failed to update MARK_WATCHED for file ID [$1] in database"
        return 1
    fi
fi

# Update ALLOW_SHORTS
current_ALLOW_SHORTS=$(sqDb "SELECT ALLOW_SHORTS FROM config WHERE FILE_ID = '${1//\'/\'\'}'")
if ! [[ "${current_ALLOW_SHORTS}" == "${includeShorts}" ]]; then
    if ! sqDb "UPDATE config SET ALLOW_SHORTS = '${includeShorts//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "1" "Failed to update ALLOW_SHORTS for file ID [$1] in database"
        return 1
    fi
fi

# Update ALLOW_LIVE
current_ALLOW_LIVE=$(sqDb "SELECT ALLOW_LIVE FROM config WHERE FILE_ID = '${1//\'/\'\'}'")
if ! [[ "${current_ALLOW_LIVE}" == "${includeLiveBroadcasts}" ]]; then
    if ! sqDb "UPDATE config SET ALLOW_LIVE = '${includeLiveBroadcasts//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "1" "Failed to update ALLOW_LIVE for file ID [$1] in database"
        return 1
    fi
fi

# Update SUBTITLE_LANGUAGES
current_SUBTITLE_LANGUAGES=$(sqDb "SELECT SUBTITLE_LANGUAGES FROM config WHERE FILE_ID = '${1//\'/\'\'}'")
if ! [[ "${current_SUBTITLE_LANGUAGES}" == "${subLanguages[*]}" ]]; then
    if ! sqDb "UPDATE config SET SUBTITLE_LANGUAGES = '${subLanguages[*]//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "1" "Failed to update SUBTITLE_LANGUAGES for file ID [$1] in database"
        return 1
    fi
fi

# Update SPONSORBLOCK_ENABLED_VIDEO
current_SPONSORBLOCK_ENABLED_VIDEO=$(sqDb "SELECT SPONSORBLOCK_ENABLED_VIDEO FROM config WHERE FILE_ID = '${1//\'/\'\'}'")
if ! [[ "${current_SPONSORBLOCK_ENABLED_VIDEO}" == "${videoEnableSB}" ]]; then
    if ! sqDb "UPDATE config SET SPONSORBLOCK_ENABLED_VIDEO = '${videoEnableSB//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "1" "Failed to update SPONSORBLOCK_ENABLED_VIDEO for file ID [$1] in database"
        return 1
    fi
fi

if [[ "${videoEnableSB}" =~ ^(mark|remove)$ ]]; then
    # Update SPONSORBLOCK_REQUIRED_VIDEO
    current_SPONSORBLOCK_REQUIRED_VIDEO=$(sqDb "SELECT SPONSORBLOCK_REQUIRED_VIDEO FROM config WHERE FILE_ID = '${1//\'/\'\'}'")
    if ! [[ "${current_SPONSORBLOCK_REQUIRED_VIDEO}" == "${videoRequireSB}" ]]; then
        if ! sqDb "UPDATE config SET SPONSORBLOCK_REQUIRED_VIDEO = '${videoRequireSB//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "1" "Failed to update SPONSORBLOCK_REQUIRED_VIDEO for file ID [$1] in database"
            return 1
        fi
    fi

    # Update SPONSORBLOCK_FLAGS_VIDEO
    current_SPONSORBLOCK_FLAGS_VIDEO=$(sqDb "SELECT SPONSORBLOCK_FLAGS_VIDEO FROM config WHERE FILE_ID = '${1//\'/\'\'}'")
    if ! [[ "${current_SPONSORBLOCK_FLAGS_VIDEO}" == "${videoCategorySB}" ]]; then
        if ! sqDb "UPDATE config SET SPONSORBLOCK_FLAGS_VIDEO = '${videoCategorySB//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "1" "Failed to update SPONSORBLOCK_FLAGS_VIDEO for file ID [$1] in database"
            return 1
        fi
    fi
fi

if [[ -n "${outputAudio}" ]]; then
    # Update AUDIO_FORMAT
    current_AUDIO_FORMAT=$(sqDb "SELECT AUDIO_FORMAT FROM config WHERE FILE_ID = '${1//\'/\'\'}'")
    if ! [[ "${current_AUDIO_FORMAT}" == "${outputAudio}" ]]; then
        if ! sqDb "UPDATE config SET AUDIO_FORMAT = '${outputAudio//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "1" "Failed to update AUDIO_FORMAT for file ID [$1] in database"
            return 1
        fi
    fi

    # Update SPONSORBLOCK_ENABLED_AUDIO
    current_SPONSORBLOCK_ENABLED_AUDIO=$(sqDb "SELECT SPONSORBLOCK_ENABLED_AUDIO FROM config WHERE FILE_ID = '${1//\'/\'\'}'")
    if ! [[ "${current_SPONSORBLOCK_ENABLED_AUDIO}" == "${audioEnableSB}" ]]; then
        if ! sqDb "UPDATE config SET SPONSORBLOCK_ENABLED_AUDIO = '${audioEnableSB//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "1" "Failed to update SPONSORBLOCK_ENABLED_AUDIO for file ID [$1] in database"
            return 1
        fi
    fi

    if [[ "${audioEnableSB}" == "remove" ]]; then
        # Update SPONSORBLOCK_REQUIRED_AUDIO
        current_SPONSORBLOCK_REQUIRED_AUDIO=$(sqDb "SELECT SPONSORBLOCK_REQUIRED_AUDIO FROM config WHERE FILE_ID = '${1//\'/\'\'}'")
        if ! [[ "${current_SPONSORBLOCK_REQUIRED_AUDIO}" == "${audioRequireSB}" ]]; then
            if ! sqDb "UPDATE config SET SPONSORBLOCK_REQUIRED_AUDIO = '${audioRequireSB//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "1" "Failed to update SPONSORBLOCK_REQUIRED_AUDIO for file ID [$1] in database"
                return 1
        fi
    fi

        # Update SPONSORBLOCK_FLAGS_AUDIO
        current_SPONSORBLOCK_FLAGS_AUDIO=$(sqDb "SELECT SPONSORBLOCK_FLAGS_AUDIO FROM config WHERE FILE_ID = '${1//\'/\'\'}'")
        if ! [[ "${current_SPONSORBLOCK_FLAGS_AUDIO}" == "${audioCategorySB}" ]]; then
            if ! sqDb "UPDATE config SET SPONSORBLOCK_FLAGS_AUDIO = '${audioCategorySB//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "1" "Failed to update SPONSORBLOCK_FLAGS_AUDIO for file ID [$1] in database"
                return 1
            fi
        fi
    fi
fi

# Update SOURCE
current_SOURCE=$(sqDb "SELECT SOURCE FROM config WHERE FILE_ID = '${1//\'/\'\'}'")
if ! [[ "${current_SOURCE}" == "${source}" ]]; then
    if ! sqDb "UPDATE config SET SOURCE = '${source//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "1" "Failed to update SOURCE for file ID [$1] in database"
        return 1
    fi
fi

printOutput "5" "Successfully updated configuration for file ID [$1]"
return 0
}

function initDb {
if [[ -z "${1}" ]]; then
    echo "No filename provided to initialize DB"
    return 1
fi

sqlite3 "${1}" "CREATE TABLE config(
    FILE_ID TEXT PRIMARY KEY, /* Primary key, validated by regex: ^[A-Za-z0-9_-]{11}$ */
    VIDEO_RESOLUTION TEXT, /* Required, valid options: 144 240 360 480 720 1080 1440 2160 4320 import none original */
    MARK_WATCHED INTEGER, /* Required, integer boolean (0 for false, 1 for true) */
    ALLOW_SHORTS INTEGER, /* Required, integer boolean (0 for false, 1 for true) */
    ALLOW_LIVE INTEGER, /* Required, integer boolean (0 for false, 1 for true) */
    SUBTITLE_LANGUAGES TEXT, /* Optional, NULL if unset, space separated list of two letter language codes if true */
    SPONSORBLOCK_ENABLED_VIDEO TEXT, /* Required, valid options: disable mark remove */
    SPONSORBLOCK_REQUIRED_VIDEO INTEGER,  /* Required, integer boolean (0 for false, 1 for true) */
    SPONSORBLOCK_FLAGS_VIDEO TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    AUDIO_FORMAT TEXT, /* Optional, NULL if unset, valid options: opus mp3 */
    SPONSORBLOCK_ENABLED_AUDIO TEXT,  /* Optional, NULL if unset, valid options: disable remove */
    SPONSORBLOCK_REQUIRED_AUDIO INTEGER, /* Optional, NULL if unset, integer boolean (0 for false, 1 for true) */
    SPONSORBLOCK_FLAGS_AUDIO TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    SOURCE TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    CREATED TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    UPDATED TEXT /* Can be set to: $(date) */
    );"

sqlite3 "${1}" "CREATE TABLE hash(
    INT_ID INTEGER PRIMARY KEY AUTOINCREMENT, /* Primary key, autoincrement integer, therefore does not need to be imported on DB recreation, we can just create a new primary key */
    FILE TEXT, /* Required, text string of file path ending in '.env' */
    HASH TEXT, /* Required, md5sum hash */
    CREATED TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    UPDATED TEXT /* Can be set to: $(date) */
    );"

sqlite3 "${1}" "CREATE TABLE channel(
    CHANNEL_ID TEXT PRIMARY KEY, /* Primary key, validated by regex: ^[0-9A-Za-z_-]{23}[AQgw]$ */
    NAME TEXT, /* Required, text string (not blob) */
    NAME_SAFE TEXT, /* Required, text string (not blob) */
    TIMESTAMP INTEGER, /* Required, integer */
    SUB_COUNT INTEGER, /* Required, integer */
    COUNTRY TEXT, /* Required, text string (not blob) */
    URL TEXT, /* Required, text string of a URL (not blob) */
    VID_COUNT INTEGER,  /* Required, integer */
    VIEW_COUNT INTEGER, /* Required, integer */
    DESC TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    PATH TEXT, /* Required, text string (not blob) */
    IMAGE TEXT, /* Required, text string of a URL (not blob) */
    BANNER TEXT, /* Optional, NULL if unset, text string a URL if set (not blob) */
    CREATED TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    UPDATED TEXT /* Can be set to: $(date) */
    );"

sqlite3 "${1}" "CREATE TABLE media(
    FILE_ID TEXT PRIMARY KEY, /* Primary key, validated by regex: ^[A-Za-z0-9_-]{11}$ */
    TITLE TEXT, /* Required, text string (not blob) */
    TITLE_SAFE TEXT, /* Required, text string (not blob) */
    CHANNEL_ID TEXT, /* Required, validated by regex: ^[0-9A-Za-z_-]{23}[AQgw]$ */
    TIMESTAMP INTEGER, /* Required, integer */
    THUMBNAIL_URL TEXT, /* Required, text string of a URL (not blob) */
    UPLOAD_YEAR INTEGER, /* Required, integer */
    YEAR_INDEX INTEGER, /* Required, integer */
    DESC TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    TYPE TEXT, /* Required, valid options: video members_only short waslive normal_private live short_private */
    SPONSORBLOCK_AVAILABLE TEXT, /* Optional, NULL If unset, text string if set (not blob) */
    VIDEO_STATUS TEXT, /* Required, valid options: downloaded queued failed skipped ignore waiting */
    VIDEO_ERROR TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    AUDIO_STATUS TEXT, /* Optional, NULL if unset, valid options if set: downloaded queued failed skipped ignore waiting */
    AUDIO_ERROR TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    CREATED TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    UPDATED TEXT /* Can be set to: $(date) */
    );"

sqlite3 "${1}" "CREATE TABLE playlist(
    PLAYLIST_ID TEXT PRIMARY KEY, /* Primary key, validated by regex: ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$|^(LL|WL)$ */
    VISIBILITY TEXT, /* Required, valid options: private public */
    TITLE TEXT, /* Required, text string (not blob) */
    DESC TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    IMAGE TEXT, /* Required, text string of a URL (not blob) */
    AUDIO INTEGER, /* Required, integer boolean (0 for false, 1 for true) */
    CREATED TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    UPDATED TEXT /* Can be set to: $(date) */
    );"

sqlite3 "${1}" "CREATE TABLE playlist_order(
    INT_ID INTEGER PRIMARY KEY AUTOINCREMENT, /* Primary key, autoincrement integer, therefore does not need to be imported on DB recreation, we can just create a new primary key */
    FILE_ID TEXT, /* Required, validated by regex: ^[A-Za-z0-9_-]{11}$ */
    PLAYLIST_ID TEXT, /* Required, validated by regex: ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$|^(LL|WL)$ */
    PLAYLIST_INDEX INTEGER, /* Required, integer */
    CREATED TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    UPDATED TEXT /* Can be set to: $(date) */
    );"

sqlite3 "${1}" "CREATE TABLE rating_key_channel(
    CHANNEL_ID TEXT PRIMARY KEY, /* Primary key, validated by regex: ^[0-9A-Za-z_-]{23}[AQgw]$ */
    VIDEO_RATING_KEY INTEGER, /* Optional, NULL if unset, integer if set */
    AUDIO_RATING_KEY INTEGER, /* Optional, NULL if unset, integer if set */
    CREATED TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    UPDATED TEXT /* Can be set to: $(date) */
    );"

sqlite3 "${1}" "CREATE TABLE rating_key_album(
    FILE_ID TEXT PRIMARY KEY,  /* Primary key, validated by regex: ^[A-Za-z0-9_-]{11}$ */
    RATING_KEY INTEGER, /* Required, integer */
    CREATED TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    UPDATED TEXT /* Can be set to: $(date) */
    );"

sqlite3 "${1}" "CREATE TABLE subtitle(
    INT_ID INTEGER PRIMARY KEY AUTOINCREMENT, /* Primary key, autoincrement integer, therefore does not need to be imported on DB recreation, we can just create a new primary key */
    FILE_ID TEXT, /* Required, validated by regex: ^[A-Za-z0-9_-]{11}$ */
    LANG_CODE TEXT, /* Required, valid options: a single two letter language code (en, es), or 'No subs available' */
    CREATED TEXT, /* Optional, NULL if unset, text string if set (not blob) */
    UPDATED TEXT /* Can be set to: $(date) */
    );"

sqlite3 "${1}" "CREATE TABLE api_log(
    INT_ID INTEGER PRIMARY KEY AUTOINCREMENT, /* Primary key, autoincrement integer, therefore does not need to be imported on DB recreation, we can just create a new primary key */
    CALL TEXT, /* Required, text string of a URL (not blob) */
    COST INTEGER, /* Required, integer */
    RESPONSE TEXT, /* Required, integer string or text string (not blob) */
    EPOCH INTEGER, /* Required, integer */
    TIME TEXT /* Optional, NULL if unset, text string if set (not blob) */
    );"

sqlite3 "${1}" "CREATE TABLE db_log(
    INT_ID INTEGER PRIMARY KEY AUTOINCREMENT, /* Primary key, autoincrement integer, therefore does not need to be imported on DB recreation, we can just create a new primary key */
    COMMAND TEXT, /* Required, text string (not blob) */
    OUTPUT TEXT, /* Required, text string (not blob) */
    TIME TEXT /* Optional, NULL if unset, text string if set (not blob) */
    );"
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
    # Positional parameter 4 is the encoded caption
    # Positional parameter 5 is the image
    printOutput "5" "Issuing curl command [curl -skL -X POST \"${2}?chat_id=${3}&parse_mode=html&caption=${4}\" -F \"photo=@\"${5}\"\"]"
    curlOutput="$(curl -skL -X POST "${2}?chat_id=${3}&parse_mode=html&caption=${4}" -F "photo=@\"${5}\"" 2>&1)"
elif [[ "${1}" == "discordimage" ]]; then
    # We're sending an image to discord
    # Positional parameter 2 is the URL
    # Positional parameter 3 is the text
    # Positional parameter 4 is the image
    printOutput "5" "Issuing curl command [curl -skL -H \"Accept: application/json\" -H \"Content-Type: multipart/form-data\" -F \"file=@\\\"${4}\\\"\" -F \"payload_json={\\\"content\\\": \\\"${3//$'\n'/\\n}\\\"}\" -X POST \"${2}\"]"
    curlOutput="$(curl -skL -H "Accept: application/json" -H "Content-Type: multipart/form-data" -F "file=@\"${4}\"" -F "payload_json={\"content\": \"${3//$'\n'/\\n}\"}" -X POST "${2}")"
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
    badExit "10" "No input URL provided for download"
elif [[ -z "${2}" ]]; then
    badExit "11" "No output path provided for download"
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
    badExit "12" "Bad curl output"
fi
}

function callCurlPut {
# URL to call should be $1
if [[ -z "${1}" ]]; then
    badExit "13" "No input URL provided for PUT"
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
    badExit "14" "No input URL provided for DELETE"
fi
printOutput "5" "Issuing curl command [curl -skL -X DELETE \"${1}\"]"
curlOutput="$(curl -skL -X DELETE "${1}" 2>&1)"
curlExitCode="${?}"
if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    while read -r i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    badExit "15" "Bad curl output"
fi
}

## Indexing functions
function cleanTrackName {
if [[ -z "${1}" ]]; then
    return 1
fi
local trackNameClean
# Trim any URL's
trackNameClean="${1%%http*}"
# Trim any leading spaces and/or periods
while [[ "${trackNameClean:0:1}" =~ ^( |\.)$ ]]; do
    trackNameClean="${trackNameClean# }"
    trackNameClean="${trackNameClean#\.}"
done
# Remove any leading track identifiers
if [[ "${trackNameClean}" =~ ^[0-9]+\.?\ ?\)\ ?.*$ ]]; then
    trackNameClean="${trackNameClean#*\)}"
    trackNameClean="${trackNameClean# }"
fi
# Trim any trailing spaces and/or periods
while [[ "${trackNameClean:$(( ${#trackNameClean} - 1 )):1}" =~ ^( |\.)$ ]]; do
    trackNameClean="${trackNameClean% }"
    trackNameClean="${trackNameClean%\.}"
done
# Trim any trailing dashes or colons
trackNameClean="${trackNameClean%:}"
trackNameClean="${trackNameClean%-}"
trackNameClean="${trackNameClean% }"
# Replace any forward or back slashes \ /
trackNameClean="${trackNameClean//\//_}"
# Replace any colons :
trackNameClean="${trackNameClean//\\/_}"
trackNameClean="${trackNameClean//:/}"
# Replace any stars *
trackNameClean="${trackNameClean//\*/}"
# Replace any question marks ?
trackNameClean="${trackNameClean//\?/}"
# Replace any quotation marks "
trackNameClean="${trackNameClean//\"/}"
# Replace any brackets < >
trackNameClean="${trackNameClean//</}"
trackNameClean="${trackNameClean//>/}"
# Replace any vertical bars |
trackNameClean="${trackNameClean//\|/}"
# Condense any instances of '_-_'
while [[ "${trackNameClean}" =~ .*"_-_".* ]]; do
    trackNameClean="${trackNameClean//_-_/ - }"
done
# Consense any excessive hyphens
while [[ "${trackNameClean}" =~ .*"- –".* ]]; do
    trackNameClean="${trackNameClean//- -/-}"
done
# Trim any leading instances of " –" or " -"
trackNameClean="${trackNameClean# –}"
trackNameClean="${trackNameClean# -}"
# Condense any multiple spaces
while [[ "${trackNameClean}" =~ .*"  ".* ]]; do
    trackNameClean="${trackNameClean//  / }"
done
echo "${trackNameClean}"
}

function updateSponsorBlock {
if ! [[ "${1}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
    printOutput "1" "Invalid file ID [${1}] passed to updateSponsorBlock function"
    return 1
fi

# Checking for SB data on a SB required video
if [[ "${vidStatus}" == "sb_wait" ]]; then
    # Get the SponsorBlock status of the video
    sponsorApiCall "searchSegments?videoID=${1}"
    sponsorCurl="${curlOutput}"
    # If it is not found
    if [[ "${sponsorCurl}" == "Not Found" ]]; then
        printOutput "5" "No SponsorBlock data available for file ID [${1}]"
        sponsorblockAvailable="Not found [$(date)]"
        vidError="SponsorBlock data required, but not available"
        # Update the SB_AVAILABLE
        if sqDb "UPDATE media SET SPONSORBLOCK_AVAILABLE = '${sponsorblockAvailable//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "5" "Updated SponsorBlock availability for file ID [${1}]"
        else
            badExit "16" "Failed to update SponsorBlock availability for file ID [${1}]"
        fi
        # Update the ERROR
        if sqDb "UPDATE media SET VIDEO_ERROR = '${vidError//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "5" "Updated error for file ID [${1}]"
        else
            badExit "17" "Failed to update error for file ID [${1}]"
        fi
    else
        # It was found
        printOutput "4" "SponsorBlock data found for file ID [${1}]"
        sponsorblockAvailable="Found [$(date)]"
        # Update the SB_AVAILABLE
        if sqDb "UPDATE media SET SPONSORBLOCK_AVAILABLE = '${sponsorblockAvailable//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "5" "Updated SponsorBlock availability for file ID [${1}]"
        else
            badExit "18" "Failed to update SponsorBlock availability for file ID [${1}]"
        fi
        # Update the ERROR
        if sqDb "UPDATE media SET VIDEO_ERROR = NULL, UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "5" "Updated error for file ID [${1}]"
        else
            badExit "19" "Failed to update error for file ID [${1}]"
        fi
        # Update the STATUS
        if sqDb "UPDATE media SET VIDEO_STATUS = 'queued', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "5" "Updated status for file ID [${1}]"
        else
            badExit "20" "Failed to update status for file ID [${1}]"
        fi
    fi
fi

# Check for SB data on a SB required audio
if [[ -n "${outputAudio}" ]]; then
    if [[ "${audStatus}" == "sb_wait" ]]; then
        if [[ -z "${sponsorCurl}" ]]; then
            # Get the SponsorBlock status of the video
            sponsorApiCall "searchSegments?videoID=${1}"
            sponsorCurl="${curlOutput}"
        fi
        # If it is not found
        if [[ "${sponsorCurl}" == "Not Found" ]]; then
            printOutput "5" "No SponsorBlock data available for file ID [${1}]"
            sponsorblockAvailable="Not found [$(date)]"
            audError="SponsorBlock data required, but not available"
            # Update the SB_AVAILABLE
            if sqDb "UPDATE media SET SPONSORBLOCK_AVAILABLE = '${sponsorblockAvailable//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "5" "Updated SponsorBlock availability for file ID [${1}]"
            else
                badExit "21" "Failed to update SponsorBlock availability for file ID [${1}]"
            fi
            # Update the ERROR
            if sqDb "UPDATE media SET AUDIO_ERROR = '${audError//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "5" "Updated error for file ID [${1}]"
            else
                badExit "22" "Failed to update error for file ID [${1}]"
            fi
        else
            # It was found
            printOutput "4" "SponsorBlock data found for file ID [${1}]"
            sponsorblockAvailable="Found [$(date)]"
            # Update the SB_AVAILABLE
            if sqDb "UPDATE media SET SPONSORBLOCK_AVAILABLE = '${sponsorblockAvailable//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "5" "Updated SponsorBlock availability for file ID [${1}]"
            else
                badExit "23" "Failed to update SponsorBlock availability for file ID [${1}]"
            fi
            # Update the ERROR
            if sqDb "UPDATE media SET AUDIO_ERROR = NULL, UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "5" "Updated error for file ID [${1}]"
            else
                badExit "24" "Failed to update error for file ID [${1}]"
            fi
            # Update the STATUS
            if sqDb "UPDATE media SET AUDIO_STATUS = 'queued', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "5" "Updated status for file ID [${1}]"
            else
                badExit "25" "Failed to update status for file ID [${1}]"
            fi
        fi
    fi
fi

# Checking for SB data on a SB upgrade video
if [[ "${vidStatus}" == "downloaded" ]]; then
    if [[ "${sponsorblockRequire}" == "0" ]]; then
        sponsorblockAvailable="${sponsorblockAvailable%% \[*}"
        if [[ "${sponsorblockAvailable}" == "Not Found" ]]; then
            # Get the SponsorBlock status of the video
            sponsorApiCall "searchSegments?videoID=${1}"
            sponsorCurl="${curlOutput}"
            # If it is not found
            if [[ "${sponsorCurl}" == "Not Found" ]]; then
                printOutput "5" "No SponsorBlock data available for file ID [${1}]"
                sponsorblockAvailable="Not found [$(date)]"
                # Update the SB_AVAILABLE
                if sqDb "UPDATE media SET SPONSORBLOCK_AVAILABLE = '${sponsorblockAvailable//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                    printOutput "5" "Updated SponsorBlock availability for file ID [${1}]"
                else
                    badExit "26" "Failed to update SponsorBlock availability for file ID [${1}]"
                fi
            else
                # It was found
                printOutput "4" "SponsorBlock data found for file ID [${1}]"
                sponsorblockAvailable="Found [$(date)]"
                # Update the SB_AVAILABLE
                if sqDb "UPDATE media SET SPONSORBLOCK_AVAILABLE = '${sponsorblockAvailable//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                    printOutput "5" "Updated SponsorBlock availability for file ID [${1}]"
                else
                    badExit "27" "Failed to update SponsorBlock availability for file ID [${1}]"
                fi
                # Update the STATUS
                if sqDb "UPDATE media SET VIDEO_STATUS = 'queued', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                    printOutput "5" "Updated status for file ID [${1}]"
                else
                    badExit "28" "Failed to update status for file ID [${1}]"
                fi
            fi
        fi
    fi
fi

# Check for SB data on for SB upgrade audio
if [[ -n "${outputAudio}" ]]; then
    if [[ "${audStatus}" == "downloaded" ]]; then
        if [[ "${sponsorblockRequire}" == "0" ]]; then
            sponsorblockAvailable="${sponsorblockAvailable%% \[*}"
            if [[ "${sponsorblockAvailable}" == "Not Found" ]]; then
                if [[ -z "${sponsorCurl}" ]]; then
                    # Get the SponsorBlock status of the video
                    sponsorApiCall "searchSegments?videoID=${1}"
                    sponsorCurl="${curlOutput}"
                fi
                # If it is not found
                if [[ "${sponsorCurl}" == "Not Found" ]]; then
                    printOutput "5" "No SponsorBlock data available for file ID [${1}]"
                    sponsorblockAvailable="Not found [$(date)]"
                    # Update the SB_AVAILABLE
                    if sqDb "UPDATE media SET SPONSORBLOCK_AVAILABLE = '${sponsorblockAvailable//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                        printOutput "5" "Updated SponsorBlock availability for file ID [${1}]"
                    else
                        badExit "29" "Failed to update SponsorBlock availability for file ID [${1}]"
                    fi
                else
                    # It was found
                    printOutput "4" "SponsorBlock data found for file ID [${1}]"
                    sponsorblockAvailable="Found [$(date)]"
                    # Update the SB_AVAILABLE
                    if sqDb "UPDATE media SET SPONSORBLOCK_AVAILABLE = '${sponsorblockAvailable//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                        printOutput "5" "Updated SponsorBlock availability for file ID [${1}]"
                    else
                        badExit "30" "Failed to update SponsorBlock availability for file ID [${1}]"
                    fi
                    # Update the STATUS
                    if sqDb "UPDATE media SET AUDIO_STATUS = 'queued', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                        printOutput "5" "Updated status for file ID [${1}]"
                    else
                        badExit "31" "Failed to update status for file ID [${1}]"
                    fi
                fi
            fi
        fi
    fi
fi
}

function ytIdToDb {

if ! [[ "${1}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
    printOutput "1" "Invalid file ID [${1}] passed to ytIdToDb function"
    return 1
fi

unset dbCount vidTitle vidTitleClean channelId uploadDate epochDate uploadYear vidDesc vidType vidStatus audStatus vidError audError sponsorCurl vidProcessed
# Because we can't get the time string through yt-dlp, there's no point in trying to use it as our fake API here, we *have* to API query YouTube

# Have we previously logged this file ID?
dbCount="$(sqDb "SELECT COUNT(1) FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
newRow="1"
if [[ "${dbCount}" -eq "1" ]]; then
    newRow="0"
    printOutput "5" "File ID [${1}] already present in DB"
    # Yes. Go ahead and pull the relevant information on the entry.
    vidStatus="$(sqDb "SELECT VIDEO_STATUS FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
    vidType="$(sqDb "SELECT TYPE FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
    sponsorblockEnable="$(sqDb "SELECT SPONSORBLOCK_ENABLED_VIDEO FROM config WHERE FILE_ID = '${1//\'/\'\'}';")"
    sponsorblockRequire="$(sqDb "SELECT SPONSORBLOCK_ENABLED_VIDEO FROM config WHERE FILE_ID = '${1//\'/\'\'}';")"
    sponsorblockAvailable="$(sqDb "SELECT SPONSORBLOCK_AVAILABLE FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
    # If the video is ignored, leave the function
    if [[ "${vidStatus}" == "ignore" ]]; then
        printOutput "5" "File ID [${1}] marked to be ignored, skipping DB update"
        return 0
    fi
    # If we want the audio, what is its status?
    if [[ -n "${outputAudio}" ]]; then
        audStatus="$(sqDb "SELECT AUDIO_STATUS FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
    fi

    # 1. New audio for an existing video
    if [[ "${vidStatus}" == "downloaded" ]]; then
        if ! [[ "${audStatus}" =~ ^(downloaded|queued)$ ]]; then
            if [[ -n "${outputAudio}" ]]; then
                # Update the FORMAT_AUDIO
                if sqDb "UPDATE config SET AUDIO_FORMAT = '${outputAudio//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                    printOutput "5" "Updated audio output format for file ID [${1}]"
                else
                    badExit "32" "Failed to update audio output format for file ID [${1}]"
                fi
                if [[ "${vidType}" == "video" ]]; then
                    # Set the STATUS_AUDIO to 'queued'
                    if sqDb "UPDATE media SET AUDIO_STATUS = 'queued', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                        printOutput "5" "Updated audio status to queued for file ID [${1}]"
                    else
                        badExit "33" "Failed to update audio status to queued for file ID [${1}]"
                    fi
                else
                    # Set the STATUS_AUDIO to 'skipped'
                    if sqDb "UPDATE media SET AUDIO_STATUS = 'skipped', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                        printOutput "5" "Updated audio status to skipped for file ID [${1}]"
                    else
                        badExit "34" "Failed to update audio status to skipped for file ID [${1}]"
                    fi
                    audError="Unwanted video type [${vidType}]"
                    # Set the AUDIO_ERROR
                    if sqDb "UPDATE media SET AUDIO_ERROR = '${audError//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                        printOutput "5" "Updated audio error for file ID [${1}]"
                    else
                        badExit "35" "Failed to update audio error for file ID [${1}]"
                    fi
                fi
            fi
        fi
    fi

    # Are we just doing an import?
    if [[ "${2}" == "import" || "${2}" == "importaudio" ]]; then
        # We already have it, just update the import fields
        if [[ "${2}" == "import" ]]; then
            # Update the item's status
            if sqDb "UPDATE media SET VIDEO_STATUS = 'import', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "5" "Updated video import status for file ID [${1}]"
            else
                printOutput "1" "Failed to update video import status for file ID [${1}]"
            fi
            if sqDb "UPDATE media SET VIDEO_ERROR = '${3//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "5" "Updated video import path for file ID [${1}]"
            else
                printOutput "1" "Failed to update video import path for file ID [${1}]"
            fi
        elif [[ "${2}" == "importaudio" ]]; then
            # Update the item's status
            if sqDb "UPDATE media SET AUDIO_STATUS = 'import', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "5" "Updated audio import status for file ID [${1}]"
            else
                printOutput "1" "Failed to update audio import status for file ID [${1}]"
            fi
            if sqDb "UPDATE media SET AUDIO_ERROR = '${3//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "5" "Updated audio import path for file ID [${1}]"
            else
                printOutput "1" "Failed to update audio import path for file ID [${1}]"
            fi
        fi
    fi

    if [[ "${vidStatus}" == "waiting" ]]; then
        # We're waiting to update a previously live broadcast, so we need to do an API call
        printOutput "5" "Continuing with API call for existing file ID [${1}] due to need to udpate previously live status"
    else
        # If we're not forcing a metadata update, leave the function
        if ! [[ "${2}" == "force" ]]; then
            return 0
        else
            printOutput "4" "Forcing DB update for file ID [${1}]"
        fi
    fi
fi

printOutput "5" "Calling API for file ID [${1}] info [${1}]"
ytApiCall "videos?id=${1}&part=snippet,liveStreamingDetails,status"
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
    badExit "36" "Impossible condition"
fi
if [[ "${apiResults}" -eq "0" ]]; then
    printOutput "2" "API lookup for file ID [${1}] zero results (Is the video private?)"
    if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
        printOutput "3" "Re-attempting file ID [${1}] lookup via yt-dlp + cookie"
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
            # We don't have a reliable way to determine if processing is done, so just hope that it is
            vidProcessed="processed"
        else
            printOutput "2" "Unable to preform lookup on file ID [${1}] via yt-dlp -- Skipping"
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
    vidType="$(yq -p json ".items[0].snippet.liveBroadcastContent" <<<"${curlOutput}")"
    # Get the broadcast start time (Will only return value if it's a live broadcast)
    broadcastStart="$(yq -p json ".items[0].liveStreamingDetails.actualStartTime" <<<"${curlOutput}")"
    # Get the maxres thumbnail URL
    thumbUrl="$(yq -p json ".items[0].snippet.thumbnails | to_entries | .[-1].value.url" <<<"${curlOutput}")"
    # Get the video processing status
    vidProcessed="$(yq -p json ".items[0].status.uploadStatus" <<<"${curlOutput}")"
else
    badExit "37" "Impossible condition"
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
if ! vidTitleClean="$(makeSafe "${vidTitle}")"; then
    printOutput "1" "Failed to create filesystem safe version of [${vidTitle}] for file ID [${1}]"
    return 1
fi
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
    printOutput "1" "Upload date lookup failed for file ID [${1}] [${1}]"
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
            vidType="video"
        elif [[ "${httpCode}" == "404" ]]; then
            # No such video exists
            printOutput "1" "Curl lookup returned HTTP code 404 for file ID [${1}] -- Skipping"
            return 1
        else
            printOutput "1" "Curl lookup to determine file ID [${1}] type returned unexpected result [${httpCode}] -- Skipping"
            return 1
        fi
    elif [[ "${broadcastStart}" =~ ^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$ || "${vidType}" == "was_live" ]]; then
        printOutput "4" "File ID [${1}] detected to be a past live broadcast"
        vidType="waslive"
    else
        printOutput "Broadcast start time lookup returned unexpected result [${broadcastStart}] -- Skipping"
        return 1
    fi
elif [[ "${vidType}" == "live" || "${vidType}" == "is_live" || "${vidType}" == "upcoming" ]]; then
    # Currently live
    liveType="${vidType}"
    printOutput "2" "File ID [${1}] detected to be a live broadcast"
    vidType="live"
else
    printOutput "1" "File ID [${1}] lookup video type returned invalid result [${vidType}] -- Skipping"
    return 1
fi
printOutput "5" "Video type [${vidType}]"

# Determine our status (queued/skipped)
# In case we're doing this as an update, check and see if it's already logged
if [[ "${newRow}" -eq "1" ]]; then
    if [[ "${2}" == "import" ]]; then
        vidStatus="import"
        # Using the error field as a cheap place to store where we need to move the file from
        vidError="${3}"
    elif [[ "${2}" == "importaudio" ]]; then
        audStatus="import"
        # Using the error field as a cheap place to store where we need to move the file from
        vidError="${3}"
    else
        vidStatus="queued"
        if ! [[ "${vidProcessed}" == "processed" ]]; then
            vidStatus="processing"
            vidError="Video has a status [${vidProcessed}] at time of indexing"
            printOutput "5" "Video has a status of [${vidProcessed}]"
        elif [[ "${vidType}" == "live" ]]; then
            # Can't download a currently live video
            vidStatus="waiting"
            vidError="Video has live status [${liveType}] at time of indexing"
            printOutput "5" "Video has currently live status"
        elif [[ "${vidType}" == "short" && "${includeShorts}" == "0" ]]; then
            # Shorts aren't allowed
            vidStatus="skipped"
            vidError="Video type [${vidType}] not allowed"
            printOutput "5" "Video type [${vidType}] not allowed"
        elif [[ "${vidType}" == "waslive" ]]; then
            if [[ "${includeLiveBroadcasts}" == "0" ]]; then
                # Past live broadcasts aren't allowed
                vidStatus="skipped"
                vidError="Video type [past live broadcast] not allowed"
                printOutput "5" "Video type [past live broadcast] not allowed"
            elif [[ "${includeLiveBroadcasts}" == "1" ]]; then
                # Past live broadcasts are allowed
                vidError="null"
            fi
        fi
    fi
else
    vidStatus="$(sqDb "SELECT VIDEO_STATUS FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
    if [[ "${vidStatus}" == "waiting" ]]; then
        # We're waiting to update a previously live broadcast
        if [[ "${vidType}" == "waslive" ]]; then
            if [[ "${includeLiveBroadcasts}" == "0" ]]; then
                # Past live broadcasts aren't allowed
                vidStatus="skipped"
                vidError="Video type [past live broadcast] not allowed"
                printOutput "5" "Video type [past live broadcast] not allowed"
            elif [[ "${includeLiveBroadcasts}" == "1" ]]; then
                # Past live broadcasts are allowed
                vidStatus="queued"
                vidError="null"
                printOutput "5" "Marking previously live broadcast as queued"
            fi
        elif [[ "${vidType}" == "live" ]]; then
            printOutput "5" "Live broadcast is still ongoing"
        else
            printOutput "5" "Found vidType [${vidType}] with status [${vidStatus}]"
        fi
    elif [[ "${vidStatus}" == "processing" ]]; then
        # Check and see if it's done processing
        if [[ "${vidProcessed}" == "processed" ]]; then
            # Yes, it's done. Apply our queued logic:
            vidStatus="queued"
            if [[ "${vidType}" == "short" && "${includeShorts}" == "0" ]]; then
                # Shorts aren't allowed
                vidStatus="skipped"
                vidError="Video type [${vidType}] not allowed"
                printOutput "5" "Video type [${vidType}] not allowed"
            elif [[ "${vidType}" == "waslive" ]]; then
                if [[ "${includeLiveBroadcasts}" == "0" ]]; then
                    # Past live broadcasts aren't allowed
                    vidStatus="skipped"
                    vidError="Video type [past live broadcast] not allowed"
                    printOutput "5" "Video type [past live broadcast] not allowed"
                elif [[ "${includeLiveBroadcasts}" == "1" ]]; then
                    # Past live broadcasts are allowed
                    vidError="null"
                fi
            fi
        else
            vidStatus="processing"
            vidError="Video has a status [${vidProcessed}] at time of indexing"
            printOutput "5" "Video has a status of [${vidProcessed}]"
        fi
    fi
fi

# If we're not skipping the video
if ! [[ "${vidStatus}" == "skipped" ]]; then
    # If SponsorBlock is enabled
    if [[ "${sponsorblockEnable}" -eq "1" ]]; then
        # Check if it's available, if we haven't already
        if [[ -z "${sponsorCurl}" ]]; then
            sponsorApiCall "searchSegments?videoID=${1}"
            sponsorCurl="${curlOutput}"
        fi
        if [[ "${sponsorCurl}" == "Not Found" ]]; then
            printOutput "5" "No SponsorBlock data available for file ID [${1}]"
            sponsorblockAvailable="Not found [$(date)]"
            if [[ "${sponsorblockRequire}" == "1" ]]; then
                vidStatus="sb_wait"
                vidError="SponsorBlock data required, but not available"
            fi
        else
            printOutput "5" "SponsorBlock data found for file ID [${1}]"
            sponsorblockAvailable="Found [$(date)]"
        fi
        # Update the SponsorBlock availability
        if sqDb "UPDATE media SET SPONSORBLOCK_AVAILABLE = '${sponsorblockAvailable//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "5" "Updated SponsorBlock availability for file ID [${1}]"
        else
            printOutput "1" "Failed to update SponsorBlock availability for file ID [${1}]"
        fi
    fi
fi

# Create the database channel entry if needed
chanDbCount="$(sqDb "SELECT COUNT(1) FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
if [[ "${chanDbCount}" -eq "0" ]]; then
    if ! channelToDb "${channelId}"; then
        printOutput "1" "Failed to add channel ID [${channelId}] to database -- Skipping"
        return 1
    fi
elif [[ "${chanDbCount}" -eq "1" ]]; then
    # Safety check
    true
else
    badExit "38" "Counted [${chanDbCount}] occurances of channel ID [${channelId}] -- Possible database corruption"
fi

if [[ "${newRow}" -eq "1" ]]; then
    # Insert what we have
    if sqDb "INSERT INTO media (FILE_ID, CREATED, UPDATED) VALUES ('${1//\'/\'\'}', '$(date)', '$(date)');"; then
        printOutput "3" "Added file ID [${1}] to database"
    else
        badExit "39" "Failed to add file ID [${1}] to database"
    fi
else
    printOutput "5" "Row already exists -- Skipping initialization"
fi

# Update the title
if sqDb "UPDATE media SET TITLE = '${vidTitle//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated title for file ID [${1}]"
else
    printOutput "1" "Failed to update title for file ID [${1}]"
fi

# Update the clean title
if sqDb "UPDATE media SET TITLE_SAFE = '${vidTitleClean//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated clean title for file ID [${1}]"
else
    printOutput "1" "Failed to update clean title for file ID [${1}]"
fi

# Update the channel ID
if sqDb "UPDATE media SET CHANNEL_ID = '${channelId//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated channel ID for file ID [${1}]"
else
    printOutput "1" "Failed to update channel ID enable for file ID [${1}]"
fi

# Update the upload timestamp
if sqDb "UPDATE media SET TIMESTAMP = ${uploadEpoch}, UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated upload timestamp for file ID [${1}]"
else
    printOutput "1" "Failed to update upload timestamp enable for file ID [${1}]"
fi

# Update the thumbnail URL
if sqDb "UPDATE media SET THUMBNAIL_URL = '${thumbUrl//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated thumbnail URL for file ID [${1}]"
else
    printOutput "1" "Failed to update thumbnail URL enable for file ID [${1}]"
fi

# Update the upload year
if sqDb "UPDATE media SET UPLOAD_YEAR = ${uploadYear}, UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated upload year for file ID [${1}]"
else
    printOutput "1" "Failed to update upload year enable for file ID [${1}]"
fi

# Update the description, if it's not empty
if [[ -n "${vidDesc}" ]]; then
    if sqDb "UPDATE media SET DESC = '${vidDesc//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
        printOutput "5" "Updated descrption for file ID [${1}]"
    else
        printOutput "1" "Failed to update description for file ID [${1}]"
    fi
fi

# Update the video type
if sqDb "UPDATE media SET TYPE = '${vidType//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated item type for file ID [${1}]"
else
    printOutput "1" "Failed to update item type enable for file ID [${1}]"
fi

# Update the item's status
if sqDb "UPDATE media SET VIDEO_STATUS = '${vidStatus//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated video status for file ID [${1}]"
else
    printOutput "1" "Failed to update video status for file ID [${1}]"
fi

# Update the error, if needed
if [[ -n "${vidError}" ]]; then
    # If we have a "NULL", the null it
    if [[ "${vidError,,}" == "null" ]]; then
        if sqDb "UPDATE media SET VIDEO_ERROR = null, UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "5" "Removed error for file ID [${1}]"
        else
            printOutput "1" "Failed to remove error for file ID [${1}]"
        fi
    else
        if sqDb "UPDATE media SET VIDEO_ERROR = '${vidError//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "5" "Updated error for file ID [${1}]"
        else
            printOutput "1" "Failed to update error for file ID [${1}]"
        fi
    fi
fi

# If we want audio, update the desired audio format
if [[ -n "${outputAudio}" ]]; then
    # We do, check and make sure we haven't already downloaded the audio
    audStatus="$(sqDb "SELECT AUDIO_STATUS FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
    if ! [[ "${audStatus}" == "downloaded" ]]; then
        # Audio status is not downloaded, but we want it
        # Update the FORMAT_AUDIO
        if sqDb "UPDATE config SET AUDIO_FORMAT = '${outputAudio//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
            printOutput "5" "Updated audio output format for file ID [${1}]"
        else
            printOutput "1" "Failed to update audio output format for file ID [${1}]"
        fi
        # Make sure it's a normal video type
        if [[ "${vidType}" == "video" ]]; then
            # Set the STATUS_AUDIO to 'queued'
            if sqDb "UPDATE media SET AUDIO_STATUS = 'queued', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "5" "Updated audio status to queued for file ID [${1}]"
            else
                printOutput "1" "Failed to update audio status to queued for file ID [${1}]"
            fi
        else
            # Set the STATUS_AUDIO to skipped
            if sqDb "UPDATE media SET AUDIO_STATUS = 'skipped', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "5" "Updated audio status to skipped for file ID [${1}]"
            else
                printOutput "1" "Failed to update audio status to skipped for file ID [${1}]"
            fi
            if sqDb "UPDATE media SET AUDIO_ERROR = 'Video type [${vidType//\'/\'\'}] not allowed', UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
                printOutput "5" "Updated audio error for file ID [${1}]"
            else
                printOutput "1" "Failed to update audio error for file ID [${1}]"
            fi
        fi
    fi
fi

# Get the order of all items in that season
readarray -t seasonOrder < <(sqDb "SELECT FILE_ID FROM media WHERE CHANNEL_ID = '${channelId//\'/\'\'}' AND UPLOAD_YEAR = ${uploadYear} ORDER BY TIMESTAMP ASC;")

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
indexCheck="$(sqDb "SELECT COUNT(1) FROM media WHERE CHANNEL_ID = '${channelId//\'/\'\'}' AND UPLOAD_YEAR = ${uploadYear} AND YEAR_INDEX = ${vidIndex} AND FILE_ID != '${1//\'/\'\'}';")"

# Update the index number
if sqDb "UPDATE media SET YEAR_INDEX = ${vidIndex}, UPDATED = '$(date)' WHERE FILE_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated season index to position [${vidIndex}] for file ID [${1}]"
else
    printOutput "1" "Failed to update season index for file ID [${1}]"
fi

# If we had another item in our position, straighten out our indexes
if [[ "${indexCheck}" -ne "0" ]]; then
    # We're not going to find a watch status for the video we're processing in Plex, so let's assign it now as watched/unwatched based on our config
    # If it was to be marked watched, it already was. We only need to set this if we need to mark it was unwatched.
    if [[ "${markWatched}" == "1" ]]; then
        if [[ -z "${watchedArr["_${ytId}"]}" ]]; then
            watchedArr["_${ytId}"]="watched"
        else
            if [[ "${watchedArr["_${ytId}"]}" == "watched" ]]; then
                printOutput "5" "File ID [${ytId}] already marked as [watched]"
            else
                printAngryWarning
                printOutput "2" "Attempted to overwrite file ID [${ytId}] watch status of [${watchedArr["_${ytId}"]}] with [watched]"
            fi
        fi
    elif [[ "${markWatched}" == "0" ]]; then
        if [[ -z "${watchedArr["_${ytId}"]}" ]]; then
            watchedArr["_${ytId}"]="unwatched"
        else
            if [[ "${watchedArr["_${ytId}"]}" == "unwatched" ]]; then
                printOutput "5" "File ID [${ytId}] already marked as [unwatched]"
            else
                printAngryWarning
                printOutput "2" "Attempted to overwrite file ID [${ytId}] watch status of [${watchedArr["_${ytId}"]}] with [unwatched]"
            fi
        fi
    else
        badExit "40" "Impossible condition"
    fi
    # Update any misordered old index numbers
    printOutput "5" "Begining retroactive index check"
    readarray -t seasonOrder < <(sqDb "SELECT FILE_ID FROM media WHERE CHANNEL_ID = '${channelId//\'/\'\'}' AND UPLOAD_YEAR = ${uploadYear} ORDER BY TIMESTAMP ASC;")
    vidIndex="1"
    getSeasonWatched="0"
    for z in "${seasonOrder[@]}"; do
        foundIndex="$(sqDb "SELECT YEAR_INDEX FROM media WHERE FILE_ID = '${z//\'/\'\'}';")"
        printOutput "5" "Checking file ID [${z}] - Expecting position [${vidIndex}] - Current position [${foundIndex}]"
        if [[ "${foundIndex}" -ne "${vidIndex}" ]]; then
            # Doesn't match, update it
            if sqDb "UPDATE media SET YEAR_INDEX = ${vidIndex}, UPDATED = '$(date)' WHERE FILE_ID = '${z}';"; then
                printOutput "5" "Retroactively updated season index from [${foundIndex}] to [${vidIndex}] for file ID [${z}]"
                # If the file has already been downloaded, we need to re-index it
                vidStatus="$(sqDb "SELECT VIDEO_STATUS FROM media WHERE FILE_ID = '${z//\'/\'\'}';")"
                if [[ "${vidStatus}" == "downloaded" ]]; then
                    printOutput "5" "Marking file ID [${z}] for move due to re-index"
                    getSeasonWatched="1"
                    printOutput "5" "Getting watch status for file ID [${z}] prior to move"
                    # Add the affected files to our moveArr so we can move them
                    # Only do this if it's not set, as we could be re-indexing a video multiple times
                    if [[ -z "${reindexArr["_${z}"]}" ]]; then
                        tmpChannelPath="$(sqDb "SELECT PATH FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
                        tmpChannelNameClean="$(sqDb "SELECT NAME_SAFE FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
                        tmpVidYear="$(sqDb "SELECT UPLOAD_YEAR FROM media WHERE FILE_ID = '${z//\'/\'\'}';")"
                        tmpVidTitleClean="$(sqDb "SELECT TITLE_SAFE FROM media WHERE FILE_ID = '${z//\'/\'\'}';")"
                        # Log the file ID as the key, and path we can find the old file at as the value
                        reindexArr["_${z}"]="${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${foundIndex}") - ${tmpVidTitleClean} [${z}].mp4"
                    fi
                fi
            else
                printOutput "1" "Failed to retroactively update season index for file ID [${z}]"
            fi
        fi
        (( vidIndex++ ))
    done

    if [[ "${getSeasonWatched}" -eq "1" ]]; then
        # We also need to record watch status for the whole rest of the season, or Plex is gonna fuck it up when we start moving files around
        while read -r tmpId; do
            # Record their watch status
            if ! getWatchStatus "${tmpId}"; then
                printOutput "1" "Failed to get watch status for file ID [${tmpId}]"
            fi
        done < <(sqDb "SELECT FILE_ID FROM media WHERE CHANNEL_ID = '${channelId//\'/\'\'}' AND UPLOAD_YEAR = ${tmpVidYear} AND VIDEO_STATUS = 'downloaded';")
    fi
fi
}

function ytApiCall {
if [[ -z "${1}" ]]; then
    printOutput "1" "No API endpoint passed for YouTube API call"
    return 1
fi

# Define API limit constants
local apiLimit
local minRequired
apiLimit="10000"
minRequired="50"

# Get the total units used in the last 24 hours
local last24HoursUsage
last24HoursUsage="$(sqDb "SELECT COALESCE(SUM(COST), 0) FROM api_log WHERE EPOCH > strftime('%s', 'now', '-1 day');")"
last24HoursUsage="$(( last24HoursUsage ))"
printOutput "5" "24 hour API unit usage [${last24HoursUsage}]"

# Check if we are under the 50-unit threshold
while [[ "$((apiLimit - last24HoursUsage))" -lt "${minRequired}" ]]; do
    # Find the earliest API call in the last 24 hours
    local earliestEpoch
    earliestEpoch="$(sqDb "SELECT MIN(EPOCH) FROM api_log WHERE EPOCH > strftime('%s', 'now', '-1 day');")"

    if [[ -n "${earliestEpoch}" && "${earliestEpoch}" -gt 0 ]]; then
        local currentTime
        local waitUntil
        local sleepTime

        currentTime="$(date +%s)"
        waitUntil="$(( earliestEpoch + 86400 ))"  # 24 hours after the earliest logged call
        sleepTime="$(( waitUntil - currentTime ))"

        if [[ "${sleepTime}" -gt "0" ]]; then
            local waitTimeFormatted
            waitTimeFormatted="$(date -d "@${waitUntil}" '+%Y-%m-%d %H:%M:%S')"
            printOutput "2" "24 hour API usage at [${last24HoursUsage}] units -- Waiting until [${waitTimeFormatted}] for additional API units to become available."
            sleep "${sleepTime}"
        fi
    else
        printOutput "2" "API limit reached. No valid timestamp found. Waiting 5 minutes..."
        sleep 300
    fi

    # Recalculate usage after waiting
    last24HoursUsage="$(sqDb "SELECT COALESCE(SUM(COST), 0) FROM api_log WHERE EPOCH > strftime('%s', 'now', '-1 day');")"
    last24HoursUsage="$(( last24HoursUsage ))"
done

# Make the API call
callCurlGet "https://www.googleapis.com/youtube/v3/${1}&key=${ytApiKey}"

# Check for a 400 or 403 error code
local errorCode
errorCode="$(yq -p json ".error.code" <<<"${curlOutput}")"
if [[ "${errorCode}" == "403" || "${errorCode}" == "400" ]]; then
    if [[ "${errorCode}" == "403" ]]; then
        badExit "41" "API key exhausted, unable to perform API calls."
    elif [[ "${errorCode}" == "400" ]]; then
        badExit "42" "API key [${ytApiKey}] appears to be invalid"
    fi
else
    if [[ "${errorCode}" == "null" ]]; then
        errorCode="200"
    fi
    (( apiCallsYouTube++ ))

    # Determine API unit cost
    local unitCost
    unitCost="1"  # Default to 1 unit

    case "${1%%\?*}" in
        "videos")    unitCost="5"; totalVideoUnits="$((totalVideoUnits + unitCost))" ;;
        "captions")  unitCost="50"; totalCaptionsUnits="$((totalCaptionsUnits + unitCost))" ;;
        "channels")  unitCost="8"; totalChannelsUnits="$((totalChannelsUnits + unitCost))" ;;
        "playlists") unitCost="3"; totalPlaylistsUnits="$((totalPlaylistsUnits + unitCost))" ;;
    esac
    totalUnits="$((totalUnits + unitCost))"

    # Log the call in the DB
    sqDb "INSERT INTO api_log (CALL, COST, RESPONSE, EPOCH, TIME)
          VALUES ('https://www.googleapis.com/youtube/v3/${1//\'/\'\'}&key=${ytApiKey//\'/\'\'}',
                  ${unitCost},
                  '${errorCode//\'/\'\'}',
                  $(date +%s),
                  '$(date)');"
fi
}

function downloadSubs {
if ! [[ "${1}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
    printOutput "1" "Invalid file ID [${1}] provided to download audio"
    return 1
fi
# Get the desired subtitle languages
IFS=' ' read -ra subLanguages < <(sqDb "SELECT SUBTITLE_LANGUAGES FROM config WHERE FILE_ID = '${1//\'/\'\'}';")
# If we don't want any subtitles, don't bother looking them up
if [[ "${#subLanguages[@]}" -eq "0" ]]; then
    printOutput "5" "No subtitle languages wanted, skipping subtitle lookup for file ID [${1}]"
    return 0
else
    printOutput "5" "Checking for desired subtitle languages [${subLanguages[*]}] for file ID [${1}]"
fi

# Get captions data from YouTube Data API v3 using ytApiCall
if ! ytApiCall "captions?part=snippet&videoId=${1}"; then
    printOutput "1" "Unable to call API for file ID [${1}] -- Skipping"
    return 1
fi

subStatus="$(sqDb "SELECT INT_ID FROM subtitle WHERE FILE_ID = '${1//\'/\'\'}' AND LANG_CODE = 'No subs available';")"
if [[ "$(yq ".items | length" <<<"${curlOutput}")" -eq "0" ]]; then
    printOutput "3" "No subtitle tracks available for file ID [${1}]"
    # Update or insert subtitle version in the database
    if [[ -z "${subStatus}" ]]; then
        # Insert new subtitle version
        sqDb "INSERT INTO subtitle (FILE_ID, LANG_CODE, CREATED, UPDATED) VALUES ('${1//\'/\'\'}', 'No subs available', '$(date)', '${lastUpdated//\'/\'\'}');"
    else
        # Update existing subtitle version
        sqDb "UPDATE subtitle SET UPDATED = '${lastUpdated//\'/\'\'}' WHERE INT_ID = '${1//\'/\'\'}' AND LANG_CODE = 'No subs available';"
    fi
    return 0
elif [[ -n "${subStatus}" ]]; then
    if [[ "${subStatus}" =~ ^[0-9]+$ ]]; then
        # Remove the old record, we now have subs
        if sqDb "DELETE FROM playlist_order WHERE INT_ID = ${subStatus};"; then
            printOutput "5" "Removed stale record of no subtitles available for file ID [${1}]"
        else
            printOutput "1" "Failed to remove stale record with INT_ID [${subStatus}] of no subtitles available for file ID [${1}]"
        fi
    else
        badExit "43" "Bad INT_ID [${subStatus}] for file ID [${1}]"
    fi
fi

# Extract caption IDs and details using yq
readarray -t captionIds < <(yq eval '.items[].id' <<<"${curlOutput}")
readarray -t languages < <(yq eval '.items[].snippet.language' <<<"${curlOutput}")
readarray -t lastUpdates < <(yq eval '.items[].snippet.lastUpdated' <<< "${curlOutput}")

# Build our output path
# Get our video channel ID
local channelId
channelId="$(sqDb "SELECT CHANNEL_ID FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
# Get our video year
local vidYear
vidYear="$(sqDb "SELECT UPLOAD_YEAR FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
# Get our video index
local vidIndex
vidIndex="$(sqDb "SELECT YEAR_INDEX FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
# Get our video clean title
local vidTitleClean
vidTitleClean="$(sqDb "SELECT TITLE_SAFE FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
# Get our channel path
local channelPath
channelPath="$(sqDb "SELECT PATH FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
# Get our clean channel name
local channelNameClean
channelNameClean="$(sqDb "SELECT NAME_SAFE FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"

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
    subStatus="$(sqDb "SELECT UPDATED FROM subtitle WHERE FILE_ID = '${1//\'/\'\'}' AND LANG_CODE = '${langCode//\'/\'\'}';")"

    if [[ -z "${subStatus}" ]]; then
        # No existing subtitles, download them
        printOutput "4" "No existing [${langCode}] subtitles for file ID [${1}]"
    elif [[ "${subStatus}" == "${lastUpdated}" ]]; then
        # Subtitles are up-to-date, skip downloading
        printOutput "4" "Subtitles [${langCode}] for file ID [${1}] are up-to-date"
        continue
    else
        # Subtitles need updating, download them
        printOutput "3" "Subtitles [${langCode}] for file ID [${1}] have been updated"
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
            printOutput "1" "Failed to pull [${langCode}] subtitles for file ID [${1}]"
            for line in "${ffmpegOutput[@]}"; do
                printOutput "1" "  ${line}"
            done
            continue
        fi
    else
        if [[ "${dlpOutput[-1]}" == "[info] There are no subtitles for the requested languages" ]]; then
            # No subs available
            subStatus="$(sqDb "SELECT INT_ID FROM subtitle WHERE FILE_ID = '${1//\'/\'\'}' AND LANG_CODE = 'No subs available';")"
            # Update or insert subtitle version in the database
            if [[ -z "${subStatus}" ]]; then
                # Insert new subtitle version
                sqDb "INSERT INTO subtitle (FILE_ID, LANG_CODE, CREATED, UPDATED) VALUES ('${1//\'/\'\'}', 'No subs available', '$(date)', '${lastUpdated//\'/\'\'}');"
            else
                # Update existing subtitle version
                sqDb "UPDATE subtitle SET UPDATED = '${lastUpdated//\'/\'\'}' WHERE INT_ID = '${1//\'/\'\'}' AND LANG_CODE = 'No subs available';"
            fi
            return 0
        else
            printOutput "1" "Failed to download any subtitle files for file ID [${1}]"
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
        printOutput "3" "Wrote [${langCode}] subtitles for file ID [${1}]"
    else
        printOutput "1" "Failed to write [${langCode}] subtitles for file ID [${1}]"
        continue
    fi

    # Update or insert subtitle version in the database
    if [[ -z "${subStatus}" ]]; then
        # Insert new subtitle version
        sqDb "INSERT INTO subtitle (FILE_ID, LANG_CODE, CREATED, UPDATED) VALUES ('${1//\'/\'\'}', '${langCode//\'/\'\'}', '$(date)', '${lastUpdated//\'/\'\'}');"
    else
        # Update existing subtitle version
        sqDb "UPDATE subtitle SET UPDATED = '${lastUpdated//\'/\'\'}' WHERE INT_ID = '${1//\'/\'\'}' AND LANG_CODE = '${langCode//\'/\'\'}';"
    fi

    # Throttle yt-dlp, if necessary
    if [[ "${loopNum}" -ne "${#captionIds[@]}" ]]; then
        throttleDlp
    fi
done
}

function sponsorApiCall {
if ! [[ "${1}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
    printOutput "1" "Invalid file ID [${1}] passed to sponsorApiCall function"
    return 1
fi
callCurlGet "https://sponsor.ajay.app/api/${1}" "goose's bash script - contact [github <at> goose <dot> ws] for any concerns or questions"
(( apiCallsSponsor++ ))
}

function getChannelCountry {
if ! [[ "${1}" =~ ^[A-Z]{2}$ ]]; then
    printOutput "1" "Invalid country ID [${1}] passed to getChannelCountry function"
    return 1
fi
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
if ! [[ "${1}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
    printOutput "1" "Invalid channel ID [${1}] passed to FUNCTION function"
    return 1
fi

# Get the channel image
local dbReply
local channelPath
dbReply="$(sqDb "SELECT IMAGE FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
channelPath="$(sqDb "SELECT PATH FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
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
if [[ "${2}" =~ ^[0-9]{4}$ ]]; then
    year="${2}"
    # Make sure we have a base show image to work with
    if ! [[ -e "${outputDir}/${channelPath}/show.jpg" ]]; then
        printOutput "1" "No show image found for channel ID [${1}]"
        return 1
    fi
    # Add the season folder, if required
    if ! [[ -d "${outputDir}/${channelPath}/Season ${year}" ]]; then
        if ! mkdir -p "${outputDir}/${channelPath}/Season ${year}"; then
            badExit "44" "Unable to create season folder [${outputDir}/${channelPath}/Season ${year}]"
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
        readarray -t seasonYears < <(sqDb "SELECT DISTINCT UPLOAD_YEAR FROM media WHERE CHANNEL_ID = '${1//\'/\'\'}' AND VIDEO_STATUS = 'downloaded';")
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
                    badExit "45" "Unable to create season folder [${outputDir}/${channelPath}/Season ${year}]"
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
dbReply="$(sqDb "SELECT BANNER FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
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

function makeArtistImage {
# ${1} should be a channel ID
if ! [[ "${1}" =~ ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$|^(LL|WL)$ ]]; then
    printOutput "1" "Invalid playlist ID [${1}] passed to makeArtistImage function"
    return 1
fi
# Get the channel thumbnail
local channelImage
channelImage="$(sqDb "SELECT IMAGE FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
if [[ -z "${channelImage}" ]]; then
    printOutput "1" "Unable to retrieve channel image for channel ID [${1}]"
    return 1
fi
# Get the path we should be downloading it to
local channelPath
channelPath="$(sqDb "SELECT PATH FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
if [[ -z "${channelPath}" ]]; then
    printOutput "1" "Unable to retrieve channel path for channel ID [${1}]"
    return 1
fi
# Download the artist image
if callCurlDownload "${channelImage}" "${outputDirAudio}/${channelPathClean}/artist.jpg"; then
    printOutput "4" "Artist image created for channel ID [${1}]"
else
    printOutput "1" "Failed to download artist image for channel ID [${1}]"
fi
}

function channelToDb {
if ! [[ "${1}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
    printOutput "1" "Invalid channel ID [${1}] provided for API lookup"
    return 1
fi

# Get the channel info from the YouTube API
unset chanName channelNameClean chanDate chanEpochDate chanSubs chanCountry chanUrl chanVids chanViews chanDesc channelPathClean chanImage chanBanner

# API call
printOutput "5" "Calling API to retrieve channel info for channel ID [${1}]"
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
    badExit "46" "Impossible condition"
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
channelNameClean="${chanName}"
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
channelNameClean="${channelNameClean//:/}"
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
if [[ -z "${channelNameClean}" ]]; then
    printOutput "1" "Channel clean name returned blank result [${vidTitle}]"
    return 1
fi
printOutput "5" "Channel clean name [${channelNameClean}]"

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
channelPathClean="${channelNameClean} [${1}]"
printOutput "5" "Channel output path [${channelPathClean}]"

# Extract the URL for the channel image, if one exists
chanImage="$(yq -p json ".items[0].snippet.thumbnails | to_entries | sort_by(.value.height) | reverse | .0 | .value.url" <<<"${curlOutput}")"
printOutput "5" "Channel image URL [${chanImage}]"

# Extract the URL for the channel background, if one exists
chanBanner="$(yq -p json ".items[0].brandingSettings.image.bannerExternalUrl" <<<"${curlOutput}")"
# If we have a banner, crop it correctly
if [[ -n "${chanBanner}" && ! "${chanBanner}" == "null" ]]; then
    chanBanner="${chanBanner}=w2560-fcrop64=1,00005a57ffffa5a8-k-c0xffffffff-no-nd-rj"
    printOutput "5" "Channel banner found [${chanBanner}]"
else
    unset chanBanner
    printOutput "5" "No channel banner found"
fi

dbCount="$(sqDb "SELECT COUNT(1) FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
if [[ "${dbCount}" -eq "0" ]]; then
    # Insert it into the database
    if sqDb "INSERT INTO channel (CHANNEL_ID, CREATED, UPDATED) VALUES ('${1//\'/\'\'}', '$(date)', '$(date)');"; then
        printOutput "3" "Added channel ID [${1}] to database"
    else
        badExit "47" "Adding channel ID [${1}] to database failed"
    fi
elif [[ "${dbCount}" -eq "1" ]]; then
    # Exists as a safety check
    true
else
    # PANIC
    badExit "48" "Multiple matches found for channel ID [${1}] -- Possible database corruption"
fi

# Set the channel name
if sqDb "UPDATE channel SET NAME = '${chanName//\'/\'\'}', UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated channel name [${chanName}] for channel ID [${1}] in database"
else
    badExit "49" "Updating channel name [${chanName}] for channel ID [${1}] in database failed"
fi


# Set the channel clean name
if sqDb "UPDATE channel SET NAME_SAFE = '${channelNameClean//\'/\'\'}', UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated channel clean name [${channelNameClean}] for channel ID [${1}] in database"
else
    badExit "50" "Updating channel clean name [${channelNameClean}] for channel ID [${1}] in database failed"
fi

# Set the timestamp
if sqDb "UPDATE channel SET TIMESTAMP = ${chanEpochDate}, UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated timestamp [${chanEpochDate}] for channel ID [${1}] in database"
else
    badExit "51" "Updating timestamp [${chanEpochDate}] for channel ID [${1}] in database failed"
fi

# Set the subscriber count
if sqDb "UPDATE channel SET SUB_COUNT = ${chanSubs//,/}, UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated subscriber count [${chanSubs}] for channel ID [${1}] in database"
else
    badExit "52" "Updating subscriber count [${chanSubs}] for channel ID [${1}] in database failed"
fi

# Set the channel country
if sqDb "UPDATE channel SET COUNTRY = '${chanCountry//\'/\'\'}', UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated country [${chanCountry}] for channel ID [${1}] in database"
else
    badExit "53" "Updating country [${chanCountry}] for channel ID [${1}] in database failed"
fi

# Set the channel URL
if sqDb "UPDATE channel SET URL = '${chanUrl//\'/\'\'}', UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated URL [${chanUrl}] for channel ID [${1}] in database"
else
    badExit "54" "Updating URL [${chanUrl}] for channel ID [${1}] in database failed"
fi

# Set the video count
if sqDb "UPDATE channel SET VID_COUNT = ${chanVids//,/}, UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated video count [${chanVids}] for channel ID [${1}] in database"
else
    badExit "55" "Updating video count [${chanVids}] for channel ID [${1}] in database failed"
fi

# Set the view count
if sqDb "UPDATE channel SET VIEW_COUNT = ${chanViews//,/}, UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated view count [${chanViews}] for channel ID [${1}] in database"
else
    badExit "56" "Updating view count [${chanViews}] for channel ID [${1}] in database failed"
fi

# Set the channel description
if sqDb "UPDATE channel SET DESC = '${chanDesc//\'/\'\'}', UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated channel description [${#chanDesc} characters] for channel ID [${1}] in database"
else
    badExit "57" "Updating channel description [${#chanDesc} characters] for channel ID [${1}] in database failed"
fi

# Set the channel path
if sqDb "UPDATE channel SET PATH = '${channelPathClean//\'/\'\'}', UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated channel path [${channelPathClean}] for channel ID [${1}] in database"
else
    badExit "58" "Updating channel path [${channelPathClean}] for channel ID [${1}] in database failed"
fi

# Set the channel image
if sqDb "UPDATE channel SET IMAGE = '${chanImage//\'/\'\'}', UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated channel image [${chanImage}] for channel ID [${1}] in database"
else
    badExit "59" "Updating channel image [${chanImage}] for channel ID [${1}] in database failed"
fi

# If we have a channel banner, add that
if [[ -n "${chanBanner}" && ! "${chanBanner}" == "null" ]]; then
    if sqDb "UPDATE channel SET BANNER = '${chanBanner}' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
        printOutput "5" "Updated channel banner [${chanBanner}] to database entry for channel ID [${1}]"
    else
        badExit "60" "Unable to append channel banner to database entry for channel ID [${1}]"
    fi
fi
}

function getPlaylistInfo {
# Playlist ID should be passed as ${1}
if ! [[ "${1}" =~ ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$|^(LL|WL)$ ]]; then
    printOutput "1" "Invalid playlist ID [${1}] passed to getPlaylistInfo function"
    return 1
fi
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
    badExit "61" "Impossible condition"
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
    badExit "62" "Impossible condition"
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
if ! [[ "${1}" =~ ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$|^(LL|WL)$ ]]; then
    printOutput "1" "Invalid playlist ID [${1}] passed to playlistSort function"
    return 1
fi
# Get the playlist info
if ! getPlaylistInfo "${1}"; then
    printOutput "1" "Failed to retrieve playlist info for [${1}] -- Skipping source"
    return 1
fi
# Do we already know of this playlist?
dbCount="$(sqDb "SELECT COUNT(1) FROM playlist WHERE PLAYLIST_ID = '${1//\'/\'\'}';")"
if [[ "${dbCount}" -eq "0" ]]; then
    # Nope. Add it to the database.
    if sqDb "INSERT INTO playlist (PLAYLIST_ID, CREATED, UPDATED) VALUES ('${1//\'/\'\'}', '$(date)', '$(date)');"; then
        printOutput "3" "Added playlist ID [${1}] to database"
    else
        badExit "63" "Failed to add playlist ID [${1}] to database"
    fi
elif [[ "${dbCount}" -eq "1" ]]; then
    # Safety check
    true
else
    badExit "64" "Counted [${dbCount}] instances of playlist ID [${1}] in database -- Possible database corruption"
fi

# Update the visibility
if sqDb "UPDATE playlist SET VISIBILITY = '${plVis//\'/\'\'}', UPDATED = '$(date)' WHERE PLAYLIST_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated visibility for playlist ID [${1}]"
else
    printOutput "1" "Failed to update visibility for playlist ID [${1}]"
fi

# Update the title
if sqDb "UPDATE playlist SET TITLE = '${plTitle//\'/\'\'}', UPDATED = '$(date)' WHERE PLAYLIST_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated title for playlist ID [${1}]"
else
    printOutput "1" "Failed to update title for playlist ID [${1}]"
fi

# Update the title
if [[ -n "${plDesc}" ]]; then
    if sqDb "UPDATE playlist SET DESC = '${plDesc//\'/\'\'}', UPDATED = '$(date)' WHERE PLAYLIST_ID = '${1//\'/\'\'}';"; then
        printOutput "5" "Updated description for playlist ID [${1}]"
    else
        printOutput "1" "Failed to description title for playlist ID [${1}]"
    fi
fi

# Update the image
if sqDb "UPDATE playlist SET IMAGE = '${plImage//\'/\'\'}', UPDATED = '$(date)' WHERE PLAYLIST_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated image for playlist ID [${1}]"
else
    printOutput "1" "Failed to update image for playlist ID [${1}]"
fi

# Update the audio output option
if [[ -z "${outputAudio}" ]]; then
    # Don't want audio
    local wantAudio="0"
else
    # Want audio
    local wantAudio="1"
fi
if sqDb "UPDATE playlist SET AUDIO = ${wantAudio}, UPDATED = '$(date)' WHERE PLAYLIST_ID = '${1//\'/\'\'}';"; then
    printOutput "5" "Updated audio for playlist ID [${1}]"
else
    printOutput "1" "Failed to update audio for playlist ID [${1}]"
fi
}

function verifyChannelName {
# Channel ID is ${1}
if ! [[ "${1}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
    printOutput "1" "Invalid channel ID [${1}] passed to verifyChannelName function"
    return 1
fi
# Retrieved channel name is ${2}
if [[ -z "${2}" ]]; then
    printOutput "1" "No channel name passed to verifyChannelName function"
    return 1
fi
# Is it already marked as safe?
if [[ -z "${verifiedArr["${1}"]}" ]]; then
    # No we have not
    # Have we previously indexed this channel?
    dbCount="$(sqDb "SELECT COUNT(1) FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
    if [[ "${dbCount}" -eq "0" ]]; then
        # Safety check
        verifiedArr["${1}"]="true"
    elif [[ "${dbCount}" -eq "1" ]]; then
        dbChanName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
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
                    printOutput "1" "Failed to get watch status for file ID [${tmpId}]"
                fi
                # Get the existing channelPath, vidYear, channelNameClean, vidIndex, vidTitleClean
                tmpChannelPath="$(sqDb "SELECT PATH FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
                tmpChannelNameClean="$(sqDb "SELECT NAME_SAFE FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
                tmpVidYear="$(sqDb "SELECT UPLOAD_YEAR FROM media WHERE FILE_ID = '${tmpId//\'/\'\'}';")"
                tmpVidIndex="$(sqDb "SELECT YEAR_INDEX FROM media WHERE FILE_ID = '${tmpId//\'/\'\'}';")"
                tmpVidTitleClean="$(sqDb "SELECT TITLE_SAFE FROM media WHERE FILE_ID = '${tmpId//\'/\'\'}';")"
                # Add the affected files to our moveArr so we can move them
                if [[ -e "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].mp4" ]]; then
                    moveArr["_${tmpId}"]="Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].mp4"
                else
                    printOutput "1" "File ID [${tmpId}] is marked as downloaded, but does not appear to exist on file system at expected path [${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].mp4]"
                fi
            done < <(sqDb "SELECT FILE_ID FROM media WHERE CHANNEL_ID = '${1//\'/\'\'}' AND VIDEO_STATUS = 'downloaded';")

            # Now update the channel information in the database
            channelToDb "${1}"

            # We're good to move our files
            # Get our new channel path
            channelPath="$(sqDb "SELECT PATH FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
            # Move our base directory
            # Move the video and thumbail of each video in the base directory
            # Check if the base channel directory exists
            if [[ -d "${outputDir}/${channelPath}" ]]; then
                badExit "65" "Directory [${outputDir}/${channelPath}] already exists, unable to update [${outputDir}/${tmpChannelPath}]"
            else
                # Move it
                if ! mv "${outputDir}/${tmpChannelPath}" "${outputDir}/${channelPath}"; then
                    badExit "66" "Failed to move old directory [${outputDir}/${tmpChannelPath}] to new directory [${outputDir}/${channelPath}]"
                fi
                # Create the series image - This will also re-create season images if needed
                makeShowImage "${1}"
            fi

            # Move the individual videos, and their thumbnails
            for tmpId in "${!moveArr[@]}"; do
                tmpId="${tmpId#_}"
                tmpChannelPath="$(sqDb "SELECT PATH FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
                tmpChannelName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
                tmpChannelNameClean="$(sqDb "SELECT NAME_SAFE FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
                tmpVidYear="$(sqDb "SELECT UPLOAD_YEAR FROM media WHERE FILE_ID = '${tmpId//\'/\'\'}';")"
                tmpVidIndex="$(sqDb "SELECT YEAR_INDEX FROM media WHERE FILE_ID = '${tmpId//\'/\'\'}';")"
                tmpVidTitle="$(sqDb "SELECT TITLE FROM media WHERE FILE_ID = '${tmpId//\'/\'\'}';")"
                tmpVidTitleClean="$(sqDb "SELECT TITLE_SAFE FROM media WHERE FILE_ID = '${tmpId//\'/\'\'}';")"
                # Check to see if the season folder exists
                if ! [[ -d "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}" ]]; then
                    # Create it
                    if ! mkdir -p "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}"; then
                        badExit "67" "Unable to create directory [${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}]"
                    fi
                fi

                # Move our file
                if ! mv "${outputDir}/${tmpChannelPath}/${moveArr[_${tmpId}]}" "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].mp4"; then
                    printOutput "1" "Failed to move file ID [${tmpId}] to destination [${tmpChannelPath}/Season ${tmpVidYear}]"
                fi

                # If we have a thumbnail
                if [[ -e "${outputDir}/${tmpChannelPath}/${moveArr[_${tmpId}]%mp4}jpg" ]]; then
                    # Move it
                    if ! mv "${outputDir}/${tmpChannelPath}/${moveArr[_${tmpId}]%mp4}jpg" "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].jpg"; then
                        printOutput "1" "Failed to move thumbnail for file ID [${tmpId}] to destination [${tmpChannelPath}/Season ${tmpVidYear}]"
                    fi
                fi
                if ! [[ -e "${outputDir}/${tmpChannelPath}/${moveArr[_${tmpId}]%mp4}jpg" ]]; then
                    # Still don't have one, so get it from web
                    printOutput "5" "Pulling thumbail from web"
                    # Get the thumbnail URL
                    tmpThumbnail="$(sqDb "SELECT THUMBNAIL_URL FROM media WHERE FILE_ID = '${tmpId//\'/\'\'}';")"
                    callCurlDownload "${tmpThumbnail}" "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].jpg"
                    if ! [[ -e "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].jpg" ]]; then
                        printOutput "1" "Failed to get thumbnail for file ID [${tmpId}]"
                    fi
                fi

                if [[ -e "${outputDir}/${tmpChannelPath}/Season ${tmpVidYear}/${tmpChannelNameClean} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitleClean} [${tmpId}].mp4" ]]; then
                    printOutput "3" "Imported video [${tmpChannelName} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitle}]"
                else
                    printOutput "1" "Failed to import [${tmpChannelName} - S${tmpVidYear}E$(printf '%03d' "${tmpVidIndex}") - ${tmpVidTitle}]"
                fi
            done

            # Get the rating key of the old series
            seriesRatingKey="$(sqDb "SELECT VIDEO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"

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
                    printOutput "1" "Unable to update watch status for file ID [${tmpId#_}]"
                fi
            done

            # Move on with life
        fi
        verifiedArr["${1}"]="true"
    else
        badExit "68" "Counted [${dbCount}] instances of channel ID [${1}] -- Possible database corruption"
    fi
fi
}

function makeSafe {
if [[ -z "${1}" ]]; then
    printOutput "1" "No input provided to make safe"
    return 1
fi
local itemClean
itemClean="${1}"
# Trim any leading spaces and/or periods
while [[ "${itemClean:0:1}" =~ ^( |\.)$ ]]; do
    itemClean="${itemClean# }"
    itemClean="${itemClean#\.}"
done
# Trim any trailing spaces and/or periods
while [[ "${itemClean:$(( ${#itemClean} - 1 )):1}" =~ ^( |\.)$ ]]; do
    itemClean="${itemClean% }"
    itemClean="${itemClean%\.}"
done
# Replace any forward or back slashes \ /
itemClean="${itemClean//\//_}"
# Replace any colons :
itemClean="${itemClean//\\/_}"
itemClean="${itemClean//:/}"
# Replace any stars *
itemClean="${itemClean//\*/}"
# Replace any question marks ?
itemClean="${itemClean//\?/}"
# Replace any quotation marks "
itemClean="${itemClean//\"/}"
# Replace any brackets < >
itemClean="${itemClean//</}"
itemClean="${itemClean//>/}"
# Replace any vertical bars |
itemClean="${itemClean//\|/}"
# Condense any instances of '_-_'
while [[ "${itemClean}" =~ .*"_-_".* ]]; do
    itemClean="${itemClean//_-_/ - }"
done
# Condense any multiple spaces
while [[ "${itemClean}" =~ .*"  ".* ]]; do
    itemClean="${itemClean//  / }"
done
# Print the output
echo "${itemClean}"
}

function checkSubs {
if [[ -z "${1}" ]]; then
    printOutput "1" "Provide a language code to validate"
    return 1
fi
local valid_codes
valid_codes=("ar" "cs" "da" "de" "el" "en" "en-CA" "en-US" "en-GB" "en-AU" "en-NZ" "en-IN" "en-ZA" "en-IE" "en-PH" "en-SG" "en-forced" "eo" "es" "es-419" "es-ES" "es-MX" "es-US" "et" "fi" "fr" "hi" "hu" "id" "it" "iw" "ja" "ko" "ku" "la" "lv" "mk" "ml" "mr" "nb" "nl" "no" "pl" "pt" "pt-BR" "pt-PT" "ro" "ru" "sk" "sl" "sr" "sv" "th" "tr" "uk" "vi" "zh" "zh-CN" "zh-TW" "zh-HK" "zh-SG")

for code in "${valid_codes[@]}"; do
    if [[ "${1}" == "${code}" ]]; then
        return 0  # Valid language code
    fi
done
return 1  # Invalid language code
}

## Plex functions
function refreshLibrary {
# Issue a "Scan Library" command -- The desired library ID must be passed as ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "No library ID passed to be scanned"
    return 1
fi
printOutput "3" "Issuing a 'Scan Library' command to Plex for library ID [${1}]"
callCurlGet "${plexAdd}/library/sections/${1}/refresh?X-Plex-Token=${plexToken}"
}

function setSeriesRatingKey {

if ! [[ "${1}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
    printOutput "1" "Invalid channel ID [${1}] passed to setSeriesRatingKey function"
    return 1
fi

lookupTime="$(($(date +%s%N)/1000000))"
# Channel ID should be passed as ${1}
if [[ -z "${1}" ]]; then
    badExit "69" "No channel ID passed for series rating key update"
fi
chanName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
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
    dbCount="$(sqDb "SELECT COUNT(1) FROM rating_key_channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
    if [[ "${dbCount}" -eq "0" ]]; then
        # Doesn't exist, insert it
        if sqDb "INSERT INTO rating_key_channel (CHANNEL_ID, VIDEO_RATING_KEY, CREATED, UPDATED) VALUES ('${1//\'/\'\'}', ${showRatingKey}, '$(date)', '$(date)');"; then
            printOutput "5" "Added rating key [${showRatingKey}] for channel ID [${1}] to database"
        else
            badExit "70" "Added series rating key [${showRatingKey}] to database failed"
        fi
    elif [[ "${dbCount}" -eq "1" ]]; then
        # Exists, update it
        if ! sqDb "UPDATE rating_key_channel SET VIDEO_RATING_KEY = '${showRatingKey}', UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
            badExit "71" "Failed to update series rating key [${showRatingKey}] for channel ID [${channelId}]"
        fi
    else
        badExit "72" "Database count for series rating key [${showRatingKey}] in rating_key table returned unexpected output [${dbCount}] -- Possible database corruption"
    fi
    lookupMatch="1"
else
    # We could not
    # Best way would be the first episode of the first season of the channel ID in question
    firstEpisode="$(sqDb "SELECT FILE_ID FROM media WHERE CHANNEL_ID = '${1//\'/\'\'}' ORDER BY TIMESTAMP ASC LIMIT 1;")"
    # Having the year would help as we can skip series which do not have the first year season we want
    firstYear="$(sqDb "SELECT UPLOAD_YEAR FROM media WHERE FILE_ID = '${firstEpisode}';")"
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
                badExit "73" "Impossible condition"
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
                badExit "74" "Impossible condition"
            fi

            if [[ -n "${seasonRatingKey}" ]]; then
                # Get the episode list for the season
                callCurlGet "${plexAdd}/library/metadata/${seasonRatingKey}/children?X-Plex-Token=${plexToken}"
                # Get the YT ID from the file path of the first episode of the first season
                firstEpisodeId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                firstEpisodeId="${firstEpisodeId%\]\.*}"
                firstEpisodeId="${firstEpisodeId##*\[}"
                if [[ -z "${firstEpisodeId}" ]]; then
                    badExit "75" "Failed to isolate ID for first episode of [${plexTitleArr[${z}]}] season [${firstYear}] -- Incorrect file name scheme?"
                fi
                # We have now extracted the ID of the first episode of the first season. Compare it to ours, and hope for a match.
                if [[ "${firstEpisodeId}" == "${firstEpisode}" ]]; then
                    # We've matched!
                    printOutput "4" "Located series rating key [${showRatingKey}] via semi-efficient lookup method [Took $(timeDiff "${lookupTime}")]"

                    # Add the series rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM rating_key_channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Doesn't exist, insert it
                        if sqDb "INSERT INTO rating_key_channel (CHANNEL_ID, VIDEO_RATING_KEY, CREATED, UPDATED) VALUES ('${1//\'/\'\'}', ${showRatingKey}, '$(date)', '$(date)');"; then
                            printOutput "5" "Added rating key [${showRatingKey}] for channel ID [${1}] to database"
                        else
                            badExit "76" "Added series rating key [${showRatingKey}] to database failed"
                        fi
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # Exists, update it
                        if ! sqDb "UPDATE rating_key_channel SET VIDEO_RATING_KEY = '${showRatingKey}', UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
                            badExit "77" "Failed to update series rating key [${showRatingKey}] for channel ID [${channelId}]"
                        fi
                    else
                        badExit "78" "Database count for series rating key [${showRatingKey}] in rating_key table returned unexpected output [${dbCount}] -- Possible database corruption"
                    fi
                    lookupMatch="1"

                    # Break the loop
                    break
                else
                    printOutput "4" "No matching episode with file ID [${firstEpisode}] detected for series rating key [${showRatingKey}] with season rating key [${seasonRatingKey}]"
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
                    dbCount="$(sqDb "SELECT COUNT(1) FROM rating_key_channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Doesn't exist, insert it
                        if sqDb "INSERT INTO rating_key_channel (CHANNEL_ID, VIDEO_RATING_KEY, CREATED, UPDATED) VALUES ('${1//\'/\'\'}', ${showRatingKey}, '$(date)', '$(date)');"; then
                            printOutput "5" "Added rating key [${showRatingKey}] for channel ID [${1}] to database"
                        else
                            badExit "79" "Added series rating key [${showRatingKey}] to database failed"
                        fi
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # Exists, update it
                        if ! sqDb "UPDATE rating_key_channel SET VIDEO_RATING_KEY = '${showRatingKey}', UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
                            badExit "80" "Failed to update series rating key [${showRatingKey}] for channel ID [${channelId}]"
                        fi
                    else
                        badExit "81" "Database count for series rating key [${showRatingKey}] in rating_key table returned unexpected output [${dbCount}] -- Possible database corruption"
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
if ! [[ "${1}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid rating key [${1}] passed to setSeriesMetadata function"
    return 1
fi

printOutput "3" "Setting series metadata for rating key [${1}]"

# Get the channel ID from the rating key
channelId="$(sqDb "SELECT CHANNEL_ID FROM rating_key_channel WHERE VIDEO_RATING_KEY = ${1};")"

# Get the channel name
showName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
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
showDesc="$(sqDb "SELECT DESC FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
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
showCreation="$(sqDb "SELECT TIMESTAMP FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
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
    badExit "82" "Impossible condition"
fi
# Convert it to YYYY-MM-DD
showCreation="$(date --date="@${showCreation}" "+%Y-%m-%d")"

if callCurlPut "${plexAdd}/library/sections/${libraryId}/all?type=2&id=${1}&includeExternalMedia=1&title.value=${showNameEncoded}&titleSort.value=${showNameEncoded}&summary.value=${showDescEncoded}&studio.value=YouTube&originallyAvailableAt.value=${showCreation}&title.locked=1&titleSort.locked=1&originallyAvailableAt.locked=1&studio.locked=1&summary.locked=1&X-Plex-Token=${plexToken}"; then
    printOutput "4" "Metadata for series [${showName}] sucessfully updated"
else
    printOutput "1" "Metadata for series [${showName}] failed"
fi
}

function setArtistRatingKey {
if ! [[ "${1}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
    printOutput "1" "Invalid channel ID [${1}] passed to setArtistRatingKey function"
    return 1
fi

lookupTime="$(($(date +%s%N)/1000000))"
# Channel ID should be passed as ${1}
if [[ -z "${1}" ]]; then
    badExit "83" "No channel ID passed for artist rating key update"
fi
chanName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
if [[ -z "${chanName}" ]]; then
    badExit "84" "Unable to retrieve channel name for channel ID [${1}]"
fi
printOutput "3" "Retrieving rating key from Plex for artist [${chanName}] with channel ID [${1}]"
# Can we take the easy way out? Try to match the artist by name
lookupMatch="0"
# Get a list of all the artist in the video library
callCurlGet "${plexAdd}/library/sections/${audioLibraryId}/all?X-Plex-Token=${plexToken}"

# Load the rating keys into an associative array, with the show title as the key and the rating key as the value
unset ratingKeyArr
declare -A ratingKeyArr
while read -r ratingKey artistTitle; do
    printOutput "5" "Assigning value [${ratingKey}] for key [${artistTitle,,}]"
    ratingKeyArr["${artistTitle,,}"]="${ratingKey}"
done < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | (.\"+@ratingKey\" + \" \" + .\"+@title\")" <<<"${curlOutput}")

# See if we can flatly match any of these via ${chanName}
if [[ -n "${ratingKeyArr[${chanName,,}]}" ]]; then
    artistRatingKey="${ratingKeyArr[${chanName,,}]}"
    # We could!
    printOutput "4" "Located artist rating key [${artistRatingKey}] via most efficient lookup method [Took $(timeDiff "${lookupTime}")]"
    dbCount="$(sqDb "SELECT COUNT(1) FROM rating_key_channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
    if [[ "${dbCount}" -eq "0" ]]; then
        # Doesn't exist, insert it
        if sqDb "INSERT INTO rating_key_channel (CHANNEL_ID, AUDIO_RATING_KEY, CREATED, UPDATED) VALUES ('${1//\'/\'\'}', ${artistRatingKey}, '$(date)', '$(date)');"; then
            printOutput "5" "Added rating key [${artistRatingKey}] for channel ID [${1}] to database"
        else
            badExit "85" "Added artist rating key [${artistRatingKey}] to database failed"
        fi
    elif [[ "${dbCount}" -eq "1" ]]; then
        # Exists, update it
        if ! sqDb "UPDATE rating_key_channel SET AUDIO_RATING_KEY = '${artistRatingKey}', UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
            badExit "86" "Failed to update artist rating key [${artistRatingKey}] for channel ID [${channelId}]"
        fi
    else
        badExit "87" "Database count for artist rating key [${artistRatingKey}] in rating_key table returned unexpected output [${dbCount}] -- Possible database corruption"
    fi
    lookupMatch="1"
else
    # We could not
    # Best way would be the first album of the channel ID in question
    firstTrack="$(sqDb "SELECT FILE_ID FROM media WHERE CHANNEL_ID = '${1//\'/\'\'}' AND AUDIO_STATUS = 'downloaded' ORDER BY TIMESTAMP ASC LIMIT 1;")"
    if [[ -z "${firstTrack}" ]]; then
        badExit "Unable to locate first episode file ID for channel ID [${1}] with AUDIO_STATUS [downloaded]"
    fi
    # Having the year would help as we can skip artist which do not have the first year album we want
    firstYear="$(sqDb "SELECT UPLOAD_YEAR FROM media WHERE FILE_ID = '${firstTrack}';")"
    if [[ -z "${firstYear}" ]]; then
        badExit "Unable to locate first year of file ID for channel ID [${1}]"
    fi
    # To do this, we need to find a matching episode by YT ID in Plex
    # The "lazy" way to do this is to only compare items which have the same first character as our channel name

    chanNameLower="${chanName,,}"
    for artistTitle in "${!ratingKeyArr[@]}"; do
        # If the first letter matches
        printOutput "5" "Comparing [${artistTitle:0:1}] of [${artistTitle} to [${chanNameLower:0:1}] of [${chanNameLower}]"
        if [[ "${artistTitle:0:1}" == "${chanNameLower:0:1}" ]]; then
            # See if we have a matching year for that artist
            artistRatingKey="${ratingKeyArr[${artistTitle}]}"
            if [[ -z "${artistRatingKey}" ]]; then
                printOutput "1" "No data provided to validate integer"
                return 1
            elif [[ "${artistRatingKey}" =~ ^[0-9]+$ ]]; then
                # Expected outcome
                true
            elif ! [[ "${artistRatingKey}" =~ ^[0-9]+$ ]]; then
                printOutput "1" "Data [${artistRatingKey}] failed to validate as an integer"
                return 1
            else
                badExit "88" "Impossible condition"
            fi

            # Get the rating key of an album that matches our video year
            callCurlGet "${plexAdd}/library/metadata/${artistRatingKey}/children?X-Plex-Token=${plexToken}"
            albumRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@index\" == \"${firstYear}\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -z "${albumRatingKey}" ]]; then
                printOutput "4" "No matching album with year [${firstYear}] found for artist [${artistTitle}] via artist rating key [${artistRatingKey}], skipping artist"
                # We can unset this as we know it's not what we're looking for, and removing it now will make any inefficient search slightly more efficient
                unset ratingKeyArr["${artistTitle}"]
                continue
            elif [[ "${albumRatingKey}" =~ ^[0-9]+$ ]]; then
                # Expected outcome
                true
            elif ! [[ "${albumRatingKey}" =~ ^[0-9]+$ ]]; then
                printOutput "1" "Data [${albumRatingKey}] failed to validate as an integer"
                return 1
            else
                badExit "89" "Impossible condition"
            fi

            if [[ -n "${albumRatingKey}" ]]; then
                # Get the track list for the album
                callCurlGet "${plexAdd}/library/metadata/${albumRatingKey}/children?X-Plex-Token=${plexToken}"
                # Get the YT ID from the file path of the first track of the first album
                firstAlbumId="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                firstAlbumId="${firstAlbumId%/*}"
                firstAlbumId="${firstAlbumId%\]}"
                firstAlbumId="${firstAlbumId##*\[}"
                if [[ -z "${firstAlbumId}" ]]; then
                    badExit "90" "Failed to isolate ID for first track for album rating key [${albumRatingKey}] -- Incorrect file name scheme?"
                fi
                # We have now extracted the ID of the first track of the first album. Compare it to ours, and hope for a match.
                if [[ "${firstAlbumId}" == "${firstTrack}" ]]; then
                    # We've matched!
                    printOutput "4" "Located artist rating key [${artistRatingKey}] via semi-efficient lookup method [Took $(timeDiff "${lookupTime}")]"

                    # Add the artist rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM rating_key_channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Doesn't exist, insert it
                        if sqDb "INSERT INTO rating_key_channel (CHANNEL_ID, AUDIO_RATING_KEY, CREATED, UPDATED) VALUES ('${1//\'/\'\'}', ${artistRatingKey}, '$(date)', '$(date)');"; then
                            printOutput "5" "Added rating key [${artistRatingKey}] for channel ID [${1}] to database"
                        else
                            badExit "91" "Added artist rating key [${artistRatingKey}] to database failed"
                        fi
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # Exists, update it
                        if ! sqDb "UPDATE rating_key_channel SET AUDIO_RATING_KEY = '${artistRatingKey}', UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
                            badExit "92" "Failed to update artist rating key [${artistRatingKey}] for channel ID [${channelId}]"
                        fi
                    else
                        badExit "93" "Database count for artist rating key [${artistRatingKey}] in rating_key table returned unexpected output [${dbCount}] -- Possible database corruption"
                    fi
                    lookupMatch="1"

                    # Break the loop
                    break
                else
                    printOutput "4" "No matching episode with file ID [${firstEpisode}] detected for artist rating key [${artistRatingKey}] with album rating key [${albumRatingKey}]"
                    # We can unset this as we know it's not what we're looking for, and removing it now will make any inefficient search slightly more efficient
                    unset ratingKeyArr["${artistTitle}"]
                fi
            fi
        fi
    done

    # If we've gotten this far, and not matched anything, we should do an inefficient search with the leftover titles from the ratingKeyArr[@]
    if [[ "${lookupMatch}" -eq "0" ]]; then
        for artistRatingKey in "${ratingKeyArr[@]}"; do
            # Get the rating key of an album that matches our video year
            callCurlGet "${plexAdd}/library/metadata/${artistRatingKey}/children?X-Plex-Token=${plexToken}"
            albumRatingKey="$(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | select ( .\"+@index\" == \"${firstYear}\" ) | .\"+@ratingKey\"" <<<"${curlOutput}")"
            if [[ -n "${albumRatingKey}" ]]; then
                printOutput "5" "Retrieved album rating key [${albumRatingKey}]"
                callCurlGet "${plexAdd}/library/metadata/${albumRatingKey}/children?X-Plex-Token=${plexToken}"
                # Get the YT ID from the file path of the first episode of the first album
                firstAlbumId="$(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | select ( .\"+@index\" == \"1\" ) | .Media.Part.\"+@file\"" <<<"${curlOutput}")"
                firstAlbumId="${firstAlbumId%\]\.*}"
                firstAlbumId="${firstAlbumId##*\[}"
                # We have now extracted the ID of the first episode of the first album. Compare it to ours, and pray for a match.
                if [[ "${firstAlbumId}" == "${firstEpisode}" ]]; then
                    printOutput "4" "Located artist rating key [${artistRatingKey}] via least efficient lookup method [Took $(timeDiff "${lookupTime}")]"

                    # Add the artist rating key to the database
                    dbCount="$(sqDb "SELECT COUNT(1) FROM rating_key_channel WHERE CHANNEL_ID = '${1//\'/\'\'}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Doesn't exist, insert it
                        if sqDb "INSERT INTO rating_key_channel (CHANNEL_ID, AUDIO_RATING_KEY, CREATED, UPDATED) VALUES ('${1//\'/\'\'}', ${artistRatingKey}, '$(date)', '$(date)');"; then
                            printOutput "5" "Added rating key [${artistRatingKey}] for channel ID [${1}] to database"
                        else
                            badExit "94" "Added artist rating key [${artistRatingKey}] to database failed"
                        fi
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # Exists, update it
                        if ! sqDb "UPDATE rating_key_channel SET AUDIO_RATING_KEY = '${artistRatingKey}', UPDATED = '$(date)' WHERE CHANNEL_ID = '${1//\'/\'\'}';"; then
                            badExit "95" "Failed to update artist rating key [${artistRatingKey}] for channel ID [${channelId}]"
                        fi
                    else
                        badExit "96" "Database count for artist rating key [${artistRatingKey}] in rating_key table returned unexpected output [${dbCount}] -- Possible database corruption"
                    fi
                    lookupMatch="1"

                    # Break the loop
                    break
                fi
            else
                printOutput "5" "No albums matching year [${firstYear}] found for artist rating key [${artistRatingKey}] -- Skipping artist"
            fi
        done
    fi
fi

if [[ "${lookupMatch}" -eq "1" ]]; then
    printOutput "5" "Located artist rating key [${artistRatingKey}] for channel ID [${1}]"
else
    printOutput "1" "Unable to locate artist rating key for channel ID [${1}] -- Is Plex aware of the artist?"
    unset artistRatingKey
    return 1
fi
}

function setArtistMetadata {

if ! [[ "${1}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid rating key [${1}] passed to FUNCTION function"
    return 1
fi

printOutput "3" "Setting metadata for artist rating key [${1}]"

# Get the channel ID from the rating key
channelId="$(sqDb "SELECT CHANNEL_ID FROM rating_key_channel WHERE AUDIO_RATING_KEY = ${1};")"

# Get the channel name
artistName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
if [[ -z "${artistName}" ]]; then
    printOutput "1" "Unable to retrieve artist name for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi
# Encode it
artistNameEncoded="$(rawUrlEncode "${artistName}")"
if [[ -z "${artistNameEncoded}" ]]; then
    printOutput "1" "Unable to encode artist name [${artistName}] for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi

# Get and encode the channel description
artistDesc="$(sqDb "SELECT DESC FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
if [[ -z "${artistDesc}" ]]; then
    printOutput "1" "Unable to retrieve artist description for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi
# Encode it
artistDescEncoded="$(rawUrlEncode "${artistDesc}")"
if [[ -z "${artistDescEncoded}" ]]; then
    printOutput "1" "Unable to encode artist description for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi

# Get the channel creation date
artistCreation="$(sqDb "SELECT TIMESTAMP FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
# Validate it
if [[ -z "${artistCreation}" ]]; then
    printOutput "1" "No data provided to validate integer"
    return 1
elif [[ "${artistCreation}" =~ ^[0-9]+$ ]]; then
    # Expected outcome
    true
elif ! [[ "${artistCreation}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Data [${artistCreation}] failed to validate as an integer"
    return 1
else
    badExit "97" "Impossible condition"
fi
# Convert it to YYYY-MM-DD
artistCreation="$(date --date="@${artistCreation}" "+%Y-%m-%d")"

# Get the channel path
artistPath="$(sqDb "SELECT PATH FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
if [[ -z "${artistPath}" ]]; then
    printOutput "1" "Unable to retrieve artist path for channel ID [${channelId}], unable to update Plex metadata -- Skipping"
    return 1
fi

# Set the metadata
if callCurlPut "${plexAdd}/library/sections/${audioLibraryId}/all?type=8&id=${1}&includeExternalMedia=1&title.value=${artistNameEncoded}&titleSort.value=${artistNameEncoded}&summary.value=${artistDescEncoded}&studio.value=YouTube&originallyAvailableAt.value=${artistCreation}&title.locked=1&titleSort.locked=1&originallyAvailableAt.locked=1&studio.locked=1&summary.locked=1&X-Plex-Token=${plexToken}"; then
    printOutput "4" "Metadata for artist [${artistName}] sucessfully updated"
else
    printOutput "1" "Metadata for artist [${artistName}] failed"
fi

if ! [[ -e "${outputDirAudio}/${artistPath}/artist.jpg" ]]; then
    # Create the artist image
    if makeArtistImage "${channelId}"; then
        printOutput "5" "Artist image for channel ID [${channelId}] successfully generated"
    else
        printOutput "1" "Failed to generate artist image for channel ID [${channelId}]"
    fi
fi

# Update the image, as Plex won't pick up the 'artist.jpg'
if callCurlPost "${plexAdd}/library/metadata/${1}/posters?X-Plex-Token=${plexToken}" --data-binary "@${outputDirAudio}/${artistPath}/artist.jpg"; then
    printOutput "5" "Image for artist [${artistName}] sucessfully updated"
else
    printOutput "1" "Image for artist [${artistName}] failed"
fi
}

function getAlbumRatingKey {
lookupTime="$(($(date +%s%N)/1000000))"
# Channel ID should be passed as ${1}
if ! [[ "${1}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
    printOutput "1" "Invalid file ID [${1}] provided to download audio"
    return 1
fi
printOutput "3" "Retrieving album rating key from Plex for file ID [${1}]"

# See if we already have it logged
updateRatingKey="0"
albumRatingKey="$(sqDb "SELECT RATING_KEY FROM rating_key_album WHERE FILE_ID = '${1//\'/\'\'}';")"
if [[ "${albumRatingKey}" =~ ^[0-9]+$ ]]; then
    # We're good
    printOutput "5" "Retrieved stored album rating key [${albumRatingKey}] for file ID [${1}]"
    # Verify that this rating key is correct still
    callCurlGet "${plexAdd}/library/metadata/${lookupRatingKey}/children?X-Plex-Token=${plexToken}"
    # In case of multi-track albums, we only need the first one
    readarray -t foundFileIds < <(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | .Media.Part.\"+@file\"" <<<"${curlOutput}")
    foundFileId="${foundFileIds[0]%/*}"
    foundFileId="${foundFileId%\]}"
    foundFileId="${foundFileId##*\[}"
    if [[ "${foundFileId}" == "${1}" ]]; then
        # We've verified
        return 0
    else
        printOutput "2" "Found stale album rating key [${albumRatingKey}] for file ID [${1}] -- Updating"
        updateRatingKey="1"
    fi
fi

# Get the channel ID for the file ID
local channelId
channelId="$(sqDb "SELECT CHANNEL_ID FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"

# Get the audio rating key for the channel ID
local artistRatingKey
artistRatingKey="$(sqDb "SELECT AUDIO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"

# We failed to look it up, try and define it
if [[ -z "${artistRatingKey}" ]]; then
    if ! setArtistRatingKey "${channelId}"; then
        printOutput "1" "Failed to set artist rating key for channel ID [${channelId}]"
        return 1
    else
        artistRatingKey="$(sqDb "SELECT AUDIO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
    fi
fi

# Make sure we have one
if [[ -z "${artistRatingKey}" ]]; then
    printOutput "1" "Unable to retrieve artist rating key for file ID [${1}]"
    return 1
else
    printOutput "5" "Retrieved artist rating key [${artistRatingKey}] for channel ID [${channelId}] for file ID [${1}]"
fi

printOutput "5" "Looking up albums associated with artist rating key [${artistRatingKey}]"
# Get a list of albums for the artist
callCurlGet "${plexAdd}/library/metadata/${artistRatingKey}/children?X-Plex-Token=${plexToken}"

# For each rating key returned
local lookupRatingKey
local foundFileIds
local foundFileId
local foundMatch
foundMatch="0"
while read -r lookupRatingKey; do
    printOutput "5" "Looking up file ID's associated with album rating key [${lookupRatingKey}]"
    # Get the associated file ID
    callCurlGet "${plexAdd}/library/metadata/${lookupRatingKey}/children?X-Plex-Token=${plexToken}"
    # In case of multi-track albums, we only need the first one
    readarray -t foundFileIds < <(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | .Media.Part.\"+@file\"" <<<"${curlOutput}")
    foundFileId="${foundFileIds[0]%/*}"
    foundFileId="${foundFileId%\]}"
    foundFileId="${foundFileId##*\[}"
    printOutput "5" "Found file ID [${foundFileId}]"
    # We have now isolated the found file ID, compare it to ours
    if [[ "${foundFileId}" == "${1}" ]]; then
        # We have a match!
        foundMatch="1"
        albumRatingKey="${lookupRatingKey}"
        if [[ "${updateRatingKey}" -eq "0" ]]; then
            if sqDb "INSERT INTO rating_key_album (FILE_ID, RATING_KEY, CREATED, UPDATED) VALUES ('${foundFileId//\'/\'\'}', ${lookupRatingKey}, '$(date)', '$(date)');"; then
                printOutput "5" "Logged audio rating key [${lookupRatingKey}] for file ID [${foundFileId}]"
            else
                badExit "98" "Failed to log audio rating key [${lookupRatingKey}] for file ID [${foundFileId}]"
            fi
        else
            if sqDb "UPDATE rating_key_album SET RATING_KEY = ${lookupRatingKey}, UPDATED = '$(date)' WHERE FILE_ID = '${foundFileId//\'/\'\'}';"; then
                printOutput "5" "Updated audio rating key [${lookupRatingKey}] for file ID [${foundFileId}]"
            else
                badExit "99" "Failed to log audio rating key [${lookupRatingKey}] for file ID [${foundFileId}]"
            fi
        fi
        break
    else
        # No match, but log the found rating key for future ease of reference
        # Find out if the found rating key is already in the DB
        dbCount="$(sqDb "SELECT COUNT(1) FROM rating_key_album WHERE FILE_ID = '${foundFileId//\'/\'\'}';")"
        if [[ "${dbCount}" -eq "0" ]]; then
            # Doesn't exist, add it
            if sqDb "INSERT INTO rating_key_album (FILE_ID, RATING_KEY, CREATED, UPDATED) VALUES ('${foundFileId//\'/\'\'}', ${lookupRatingKey}, '$(date)', '$(date)');"; then
                printOutput "5" "Logged audio rating key [${lookupRatingKey}] for file ID [${foundFileId}]"
            else
                badExit "100" "Failed to log audio rating key [${lookupRatingKey}] for file ID [${foundFileId}]"
            fi
        fi
    fi
done < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")

if [[ "${foundMatch}" -eq "1" ]]; then
    printOutput "5" "Located rating key [${lookupRatingKey}] for album with file ID [${1}]"
else
    printOutput "1" "Failed to locate album rating key for file ID [${1}]"
    unset albumRatingKey
    return 1
fi
}

function setAlbumMetadata {
if ! [[ "${1}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
    printOutput "1" "Invalid file ID [${1}] passed to setAlbumMetadata function"
    return 1
fi
if ! [[ "${2}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid rating key passed to setAlbumMetadata function"
    return 1
fi

printOutput "3" "Setting album metadata for file ID [${1}]"

# Get the album name
albumName="$(sqDb "SELECT TITLE FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
if [[ -z "${albumName}" ]]; then
    printOutput "1" "Unable to retrieve album name for file ID [${1}], unable to update Plex metadata -- Skipping"
    return 1
fi
# Encode it
albumNameEncoded="$(rawUrlEncode "${albumName}")"
if [[ -z "${albumNameEncoded}" ]]; then
    printOutput "1" "Unable to encode album name [${albumName}] for file ID [${1}], unable to update Plex metadata -- Skipping"
    return 1
fi

# Get and encode the album description
albumDesc="$(sqDb "SELECT DESC FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
if [[ -z "${albumDesc}" ]]; then
    albumDesc="https://www.youtube.com/watch?v=${1}"
else
    albumDesc="${albumDesc}${lineBreak}-----${lineBreak}https://www.youtube.com/watch?v=${1}"
fi
# Encode it
albumDescEncoded="$(rawUrlEncode "${albumDesc}")"
if [[ -z "${albumDescEncoded}" ]]; then
    printOutput "1" "Unable to encode album description for file ID [${1}], unable to update Plex metadata -- Skipping"
    return 1
fi

# Get the artist rating key
# Get the channel ID for the file ID
local channelId
channelId="$(sqDb "SELECT CHANNEL_ID FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
if [[ -z "${channelId}" ]]; then
    printOutput "1" "Unable to retrieve channel ID for file ID [${1}]"
    return 1
fi
# Get the audio rating key for that channel ID
local artistRatingKey
artistRatingKey="$(sqDb "SELECT AUDIO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
if [[ -z "${artistRatingKey}" ]]; then
    printOutput "1" "Unable to retrieve artist rating key for channel ID [${channelId}]"
    return 1
fi

# Set the metadata
if callCurlPut "${plexAdd}/library/sections/16/all?type=9&id=${2}&includeExternalMedia=1&title.value=${albumNameEncoded}&titleSort.value=${albumNameEncoded}&summary.value=${albumDescEncoded}&title.locked=1&titleSort.locked=1&artist.id.value=${artistRatingKey}&X-Plex-Token=${plexToken}"; then
    printOutput "4" "Metadata for album [${albumName}] sucessfully updated"
else
    printOutput "1" "Metadata for album [${albumName}] failed"
fi
}

function setWatchStatus {
if ! [[ "${1}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
    printOutput "1" "Invalid file ID [${1}] passed to setWatchStatus function"
    return 1
fi

# Get its rating key
if ! getFileRatingKey "${1}"; then
    printOutput "1" "Failed to retrieve rating key for file ID [${1}]"
    return 1
fi

printOutput "3" "Correcting watch status for file ID [${1}]"
if [[ "${watchedArr[_${1}]}" == "watched" ]]; then
    # Issue the call to mark the item as watched
    printOutput "4" "Marking file ID [${1}] as watched"
    if callCurlGet "${plexAdd}/:/scrobble?identifier=com.plexapp.plugins.library&key=${ratingKey}&X-Plex-Token=${plexToken}"; then
        printOutput "5" "Successfully marked file ID [${1}] as watched"
        unset watchedArr["_${1}"]
    else
        printOutput "1" "Failed to mark file ID [${1}] as watched via rating key [${ratingKey}]"
    fi
elif [[ "${watchedArr[_${1}]}" == "unwatched" ]]; then
    # Issue the call to mark the item as unwatched
    printOutput "4" "Marking file ID [${1}] as unwatched"
    if callCurlGet "${plexAdd}/:/unscrobble?identifier=com.plexapp.plugins.library&key=${ratingKey}&X-Plex-Token=${plexToken}"; then
        printOutput "5" "Successfully marked file ID [${1}] as unwatched"
        unset watchedArr["_${1}"]
    else
        printOutput "1" "Failed to mark file ID [${1}] as unwatched via rating key [${ratingKey}]"
    fi
elif [[ "${watchedArr[_${1}]}" =~ ^[0-9]+$ ]]; then
    # Issue the call to mark the item as partially watched
    printOutput "4" "Marking file ID [${1}] as partially watched watched [$(msToTime "${watchedArr[_${1}]}")]"
    if callCurlPut "${plexAdd}/:/progress?key=${ratingKey}&identifier=com.plexapp.plugins.library&time=${watchedArr[_${1}]}&state=stopped&X-Plex-Token=${plexToken}"; then
        printOutput "5" "Successfully marked file ID [${1}] as partially watched [$(msToTime "${watchedArr[_${1}]}")]"
        unset watchedArr["_${1}"]
    else
        printOutput "1" "Failed to mark file ID [${1}] as partially watched [${watchedArr[_${1}]}|$(msToTime "${watchedArr[_${1}]}")] via rating key [${ratingKey}]"
    fi
else
    badExit "101" "Unexpected watch status for [${1}]: ${watchedArr[_${1}]}"
fi
}

function getFileRatingKey {
local lookupTime
lookupTime="$(($(date +%s%N)/1000000))"
# file ID should be passed as ${1}
if ! [[ "${1}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
    printOutput "1" "Invalid file ID [${1}] passed to getFileRatingKey function"
    return 1
elif [[ -n "${rkArr[_${1}]}" ]]; then
    # TODO: Validate that the rating key is valid
    ratingKey="${rkArr[_${1}]}"
    return 0
fi

# Get the channel ID of our file ID
local channelId
channelId="$(sqDb "SELECT CHANNEL_ID FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
if [[ -z "${channelId}" ]]; then
    printOutput "1" "Unable to retrieve channel ID for file ID [${1}] -- Possible database corruption"
    return 1
fi

# Get the rating key for this series
local showRatingKey
showRatingKey="$(sqDb "SELECT VIDEO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
if [[ -z "${showRatingKey}" ]]; then
    if ! setSeriesRatingKey "${channelId}"; then
        printOutput "1" "Failed to set series rating key for channel ID [${channelId}]"
        return 1
    fi
    # If we've gotten this far, we still have ${showRatingKey} defined from the setSeriesRatingKey function
fi

# Get the year for the file ID
local vidYear
vidYear="$(sqDb "SELECT UPLOAD_YEAR FROM media WHERE FILE_ID = '${1//\'/\'\'}';")"
if [[ -z "${vidYear}" ]]; then
    badExit "102" "Failed to retrieve year for file ID [${1}] -- Possible database corruption"
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
    badExit "103" "Impossible condition"
fi

# Get the episode list for the season
callCurlGet "${plexAdd}/library/metadata/${seasonRatingKey}/children?X-Plex-Token=${plexToken}"

while read -r ratingKey fileId; do
    fileId="${fileId%\]\.*}"
    fileId="${fileId##*\[}"
    if [[ -z "${fileId}" ]]; then
        printOutput "1" "Failed to isolate file ID for item rating key [${ratingKey}] of season rating key [${seasonRatingKey}]"
        return 1
    fi
    if [[ "${fileId}" == "${1}" ]]; then
        # We've matched!
        printOutput "5" "Located episode rating key [${ratingKey}] for file ID [${1}] [Took $(timeDiff "${lookupTime}")]"

        # Save it
        rkArr["_${1}"]="${ratingKey}"

        # Break the loop
        break
    fi
done < <(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | (.\"+@ratingKey\" + \" \" + .Media.Part.\"+@file\")" <<<"${curlOutput}")
}

function getWatchStatus {
if ! [[ "${1}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
    printOutput "1" "Invalid file ID [${1}] passed to getWatchStatus function"
    return 1
fi
if [[ -n "${watchedArr[_${1}]}" ]]; then
    printOutput "5" "Watch status for file ID [${1}] already defined as [${watchedArr[_${1}]}]"
    return 0
fi
if ! getFileRatingKey "${1}"; then
    printOutput "1" "Failed to retrieve rating key for file ID [${1}]"
    return 1
fi
# We now have the file's rating key assigned as ${ratingKey}
# Now, get the file's watch status from Plex
callCurlGet "${plexAdd}/library/metadata/${ratingKey}?X-Plex-Token=${plexToken}"
watchStatus="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .\"+@viewOffset\"" <<<"${curlOutput}")"
if [[ "${watchStatus}" =~ ^[0-9]+$ ]]; then
    # It's in progress
    printOutput "4" "Detected file ID [${1}] as in-progress with view offset [${watchStatus}]"
    if [[ -z "${watchedArr["_${1}"]}" ]]; then
        watchedArr["_${1}"]="${watchStatus}"
    else
        if [[ "${watchedArr["_${1}"]}" == "${watchStatus}" ]]; then
            printOutput "5" "File ID [${1}] already marked as [${watchStatus}]"
        else
            printAngryWarning
            printOutput "2" "Attempted to overwrite file ID [${1}] watch status of [${watchedArr["_${1}"]}] with [${watchStatus}]"
        fi
    fi
else
    # Not in progress, we need to check the view count
    watchStatus="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .\"+@viewCount\"" <<<"${curlOutput}")"
    if [[ "${watchStatus}" == "null" ]]; then
        # It's unwatched
        printOutput "4" "Detected file ID [${1}] as unwatched"
        if [[ -z "${watchedArr["_${1}"]}" ]]; then
            watchedArr["_${1}"]="unwatched"
        else
            if [[ "${watchedArr["_${1}"]}" == "unwatched" ]]; then
                printOutput "5" "File ID [${1}] already marked as [unwatched]"
            else
                printAngryWarning
                printOutput "2" "Attempted to overwrite file ID [${1}] watch status of [${watchedArr["_${1}"]}] with [unwatched]"
            fi
        fi
    else
        # It's watched
        printOutput "4" "Detected file ID [${1}] as watched"
        if [[ -z "${watchedArr["_${1}"]}" ]]; then
            watchedArr["_${1}"]="watched"
        else
            if [[ "${watchedArr["_${1}"]}" == "watched" ]]; then
                printOutput "5" "File ID [${1}] already marked as [watched]"
            else
                printAngryWarning
                printOutput "2" "Attempted to overwrite file ID [${1}] watch status of [${watchedArr["_${1}"]}] with [watched]"
            fi
        fi
    fi
fi
if [[ -z "${watchedArr[_${1}]}" ]]; then
    printOutput "1" "Unable to detect watch status for file ID [${1}]"
    return 1
fi
# We should now have watchedArr[_${ytId}] defined as 'watched', 'unwatched', or a numerical viewing offset (in progress)
}

function collectionGetOrder {
# Collection rating key should be passed as ${1}
if ! [[ "${1}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid rating key [${1}] passed to collectionGetOrder function"
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
}

function collectionSort {
if ! [[ "${1}" =~ ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$|^(LL|WL)$ ]]; then
    printOutput "1" "Invalid playlist ID [${1}] passed to collectionSort function"
    return 1
fi
if ! [[ "${2}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid rating key [${2}] passed to collectionSort function"
    return 1
fi

local playlistId="${1}"
local collectionKey="${2}"

printOutput "4" "Sorting items for collection [${collectionKey}] using playlist ID [${playlistId}]"

readarray -t plVidList < <(sqDb "SELECT FILE_ID FROM playlist_order WHERE PLAYLIST_ID = '${playlistId//\'/\'\'}' ORDER BY PLAYLIST_INDEX ASC;")
collectionGetOrder "${collectionKey}"

local lastFileId=""
local plPos="0"
for kk in "${plVidList[@]}"; do
    (( plPos++ ))
    printOutput "5" "Iterating over file ID [${kk}] in position [${plPos}] for collection sorting"
    # Make sure the video is actually downloaded
    local fileStatus="$(sqDb "SELECT VIDEO_STATUS FROM media WHERE FILE_ID = '${kk//\'/\'\'}';")"
    if ! [[ "${fileStatus}" == "downloaded" ]]; then
        # The file is not downloaded, so don't bother with this file ID
        printOutput "5" "Skipping file ID [${kk}] due to non-downloaded status [${fileStatus}]"
        (( plPos-- ))
        continue
    fi
    # If our current file ID [${kk}] matches the corresponding Plex file ID [${plexCollectionOrder[${plPos}]}], we're good
    if [[ "${kk}" == "${plexCollectionOrder[${plPos}]}" ]]; then
        printOutput "5" "Verified file ID [${kk}] correctly in position [${plPos}]"
        lastFileId="${kk}"
        continue
    fi
    # If we've gotten this far, it's out of position
    # If we're in position 1, move the file to the start
    getFileRatingKey "${kk}"
    if [[ "${plPos}" -eq "1" ]]; then
        printOutput "3" "Moving file ID [${kk}] to position [1] for collection [${collectionKey}]"
        callCurlPut "${plexAdd}/library/collections/${1}/items/${ratingKey}/move?type=2&X-Plex-Token=${plexToken}"
    else
        # Not in position 1
        # Store our current file ID rating key
        updateRatingKey="${ratingKey}"
        # Get the rating key of our last file ID
        getFileRatingKey "${lastFileId}"
        printOutput "3" "Moving file ID [${kk}] to position [${plPos}] via rating key [${updateRatingKey}], following file ID [${lastFileId}] with rating key [${ratingKey}] for collection [${collectionKey}]"
        callCurlPut "${plexAdd}/library/collections/${collectionKey}/items/${updateRatingKey}/move?type=2&after=${ratingKey}&X-Plex-Token=${plexToken}"
    fi
    collectionGetOrder "${collectionKey}"
    lastFileId="${kk}"
done
}

function collectionAdd {
if ! [[ "${1}" =~ ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$|^(LL|WL)$ ]]; then
    printOutput "1" "Invalid playlist ID [${1}] passed to collectionAdd function"
    return 1
fi
if ! [[ "${2}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid rating key [${2}] passed to collectionAdd function"
    return 1
fi

local playlistId="${1}"
local collectionKey="${2}"

printOutput "4" "Adding new items to collection [${collectionKey}] from playlist ID [${playlistId}]"

readarray -t plVidList < <(sqDb "SELECT FILE_ID FROM playlist_order WHERE PLAYLIST_ID = '${playlistId//\'/\'\'}' ORDER BY PLAYLIST_INDEX ASC;")
printOutput "5" "Found ${#plVidList[@]} entries in playlist_order for ID [${playlistId}]"

if [[ "${#plVidList[@]}" -eq "0" ]]; then
    printOutput "4" "No videos found in playlist_order for playlist ID [${playlistId}]"
    return 0
fi

collectionGetOrder "${collectionKey}"

for ii in "${plVidList[@]}"; do
    # Make sure the video is actually downloaded
    local fileStatus="$(sqDb "SELECT VIDEO_STATUS FROM media WHERE FILE_ID = '${ii//\'/\'\'}';")"
    if ! [[ "${fileStatus}" == "downloaded" ]]; then
        # The file is not downloaded, so don't bother with this file ID
        printOutput "5" "Skipping file ID [${jj}] due to non-downloaded status [${fileStatus}]"
        continue
    fi
    local found="0"
    for plexFileId in "${plexCollectionOrder[@]}"; do
        if [[ "${ii}" == "${plexFileId}" ]]; then
            found="1"
            break
        fi
    done
    if [[ "${found}" -eq "0" ]]; then
        getFileRatingKey "${ii}"
        printOutput "3" "Adding missing file ID [${ii}] with rating key [${ratingKey}] to collection [${collectionKey}]"
        callCurlPut "${plexAdd}/library/collections/${collectionKey}/items?uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${ratingKey}&X-Plex-Token=${plexToken}"
        if [[ "${curlExitCode}" -eq "0" ]]; then
            printOutput "4" "Added item to collection"
        fi
    fi
done

collectionGetOrder "${collectionKey}"
}

function collectionDelete {
if ! [[ "${1}" =~ ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$|^(LL|WL)$ ]]; then
    printOutput "1" "Invalid playlist ID [${1}] passed to collectionDelete function"
    return 1
fi
if ! [[ "${2}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid rating key [${2}] passed to collectionDelete function"
    return 1
fi

local playlistId="${1}"
local collectionKey="${2}"

printOutput "4" "Removing stale items from collection [${collectionKey}] for playlist ID [${playlistId}]"

readarray -t plVidList < <(sqDb "SELECT FILE_ID FROM playlist_order WHERE PLAYLIST_ID = '${playlistId//\'/\'\'}' ORDER BY PLAYLIST_INDEX ASC;")
collectionGetOrder "${collectionKey}"

local anyRemoved="0"

for ii in "${plexCollectionOrder[@]}"; do
    local inDbPlaylist="0"
    for jj in "${plVidList[@]}"; do
        printOutput "5" "Checking for file ID [${jj}] in playlist index"
        if [[ "${jj}" == "${ii}" ]]; then
            printOutput "5" "Found file ID [${ii}] matching playlist index [${jj}]"
            inDbPlaylist="1"
            break
        fi
    done
    if [[ "${inDbPlaylist}" -eq "0" ]]; then
        getFileRatingKey "${ii}"
        printOutput "3" "Removing file ID [${ii}] with rating key [${ratingKey}] from collection [${collectionKey}], as it does not appear in the playlist index"
        callCurlDelete "${plexAdd}/library/collections/${collectionKey}/children/${ratingKey}?excludeAllLeaves=1&X-Plex-Token=${plexToken}"
        anyRemoved="1"
    fi
done

if [[ "${anyRemoved}" -eq "1" ]]; then
    collectionGetOrder "${collectionKey}"
fi
}

function collectionUpdate {
if ! [[ "${1}" =~ ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$|^(LL|WL)$ ]]; then
    printOutput "1" "Invalid playlist ID [${1}] passed to collectionUpdate function"
    return 1
fi
if ! [[ "${2}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid rating key [${2}] passed to collectionUpdate function"
    return 1
fi
collectionDesc="$(sqDb "SELECT DESC FROM playlist WHERE PLAYLIST_ID = '${1//\'/\'\'}';")"
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
collectionImg="$(sqDb "SELECT IMAGE FROM playlist WHERE PLAYLIST_ID = '${1//\'/\'\'}';")"
if [[ -n "${collectionImg}" ]] && ! [[ "${collectionImg}" == "null" ]]; then
    callCurlDownload "${collectionImg}" "${tmpDir}/${1}.jpg"
    callCurlPost "${plexAdd}/library/metadata/${2}/posters?X-Plex-Token=${plexToken}" --data-binary "@${tmpDir}/${1}.jpg"
    rm -f "${tmpDir}/${1}.jpg"
    printOutput "4" "Collection [${2}] image set"
fi
}

function playlistGetOrder {
if ! [[ "${1}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid rating key [${1}] passed to playlistGetOrder function"
    return 1
fi

printOutput "5" "Obtaining order of items in playlist from Plex"
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
    plexPlaylistOrder+=("${ii}")
done < <(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .Media.Part.\"+@file\"" <<<"${curlOutput}")
unset plexPlaylistOrder[0]
}

function playlistSort {
if ! [[ "${1}" =~ ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$|^(LL|WL)$ ]]; then
    printOutput "1" "Invalid playlist ID [${1}] passed to playlistSort function"
    return 1
fi
if ! [[ "${2}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid rating key [${2}] passed to playlistSort function"
    return 1
fi

local playlistId="${1}"
local playlistKey="${2}"

printOutput "4" "Sorting items for playlist [${playlistKey}] using playlist ID [${playlistId}]"

readarray -t plVidList < <(sqDb "SELECT FILE_ID FROM playlist_order WHERE PLAYLIST_ID = '${playlistId//\'/\'\'}' ORDER BY PLAYLIST_INDEX ASC;")
playlistGetOrder "${playlistKey}"

local lastFileId=""
local plPos="0"
for kk in "${plVidList[@]}"; do
    (( plPos++ ))
    printOutput "5" "Iterating over file ID [${kk}] in position [${plPos}] for playlist sorting"
    # Make sure the video is actually downloaded
    local fileStatus="$(sqDb "SELECT VIDEO_STATUS FROM media WHERE FILE_ID = '${kk//\'/\'\'}';")"
    if ! [[ "${fileStatus}" == "downloaded" ]]; then
        # The file is not downloaded, so don't bother with this file ID
        printOutput "5" "Skipping file ID [${kk}] due to non-downloaded status [${fileStatus}]"
        (( plPos-- ))
        continue
    fi
    # If our current file ID [${kk}] matches the corresponding Plex file ID [${plexPlaylistOrder[${plPos}]}], we're good
    if [[ "${kk}" == "${plexPlaylistOrder[${plPos}]}" ]]; then
        printOutput "5" "Verified file ID [${kk}] correctly in position [${plPos}]"
        lastFileId="${kk}"
        continue
    fi
    # If we've gotten this far, it's out of position
    # If we're in position 1, move the file to the start
    getFileRatingKey "${kk}"
    callCurlGet "${plexAdd}/playlists/${playlistKey}/items?X-Plex-Token=${plexToken}"
    playlistItemId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${ratingKey}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
    printOutput "5" "File ID [${kk}] | ratingKey [${ratingKey}] | Item PLID [${playlistItemId}]"
    if [[ "${plPos}" -eq "1" ]]; then
        printOutput "3" "Moving file ID [${kk}] to position [1] for playlist [${playlistKey}]"
        callCurlPut "${plexAdd}/library/playlists/${playlistKey}/items/${playlistItemId}/move?X-Plex-Token=${plexToken}"
    else
        # Not in position 1
        # Store our current playlist item ID
        updatePlaylistItemId="${playlistItemId}"
        # Get the rating key of our last file ID
        getFileRatingKey "${lastFileId}"
        # Get the playlist item ID of our last file ID
        callCurlGet "${plexAdd}/playlists/${playlistKey}/items?X-Plex-Token=${plexToken}"
        playlistItemId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${ratingKey}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
        printOutput "5" "File ID [${kk}] | ratingKey [${ratingKey}] | Item PLID [${playlistItemId}]"
        printOutput "3" "Moving file ID [${kk}] to position [${plPos}] via playlist item ID [${updatePlaylistItemId}], following file ID [${lastFileId}] with playlist item ID [${playlistItemId}] for playlist [${playlistKey}]"
        callCurlPut "${plexAdd}/playlists/${playlistKey}/items/${updatePlaylistItemId}/move?after=${playlistItemId}&X-Plex-Token=${plexToken}"
    fi
    playlistGetOrder "${playlistKey}"
    lastFileId="${kk}"
done
}

function playlistAdd {
if ! [[ "${1}" =~ ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$|^(LL|WL)$ ]]; then
    printOutput "1" "Invalid playlist ID [${1}] passed to playlistAdd function"
    return 1
fi
if ! [[ "${2}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid rating key [${2}] passed to playlistAdd function"
    return 1
fi

local playlistId="${1}"
local playlistKey="${2}"

printOutput "4" "Adding new items to playlist [${playlistKey}] from playlist ID [${playlistId}]"

readarray -t plVidList < <(sqDb "SELECT FILE_ID FROM playlist_order WHERE PLAYLIST_ID = '${playlistId//\'/\'\'}' ORDER BY PLAYLIST_INDEX ASC;")
printOutput "5" "Found ${#plVidList[@]} entries in playlist_order for ID [${playlistId}]"

if [[ "${#plVidList[@]}" -eq "0" ]]; then
    printOutput "4" "No videos found in playlist_order for playlist ID [${playlistId}]"
    return 0
fi

playlistGetOrder "${playlistKey}"

for ii in "${plVidList[@]}"; do
    # Make sure the video is actually downloaded
    local fileStatus="$(sqDb "SELECT VIDEO_STATUS FROM media WHERE FILE_ID = '${ii//\'/\'\'}';")"
    if ! [[ "${fileStatus}" == "downloaded" ]]; then
        # The file is not downloaded, so don't bother with this file ID
        printOutput "5" "Skipping file ID [${jj}] due to non-downloaded status [${fileStatus}]"
        continue
    fi
    local found="0"
    for plexFileId in "${plexPlaylistOrder[@]}"; do
        if [[ "${ii}" == "${plexFileId}" ]]; then
            found="1"
            break
        fi
    done
    if [[ "${found}" -eq "0" ]]; then
        getFileRatingKey "${ii}"
        printOutput "3" "Adding missing file ID [${ii}] with rating key [${ratingKey}] to playlist [${playlistKey}]"
        callCurlPut "${plexAdd}/playlists/${playlistKey}/items?uri=server%3A%2F%2F${serverMachineId}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${ratingKey}&X-Plex-Token=${plexToken}"
        if [[ "${curlExitCode}" -eq "0" ]]; then
            printOutput "4" "Added item to playlist"
        fi
    fi
done

playlistGetOrder "${playlistKey}"
}

function playlistDelete {
if ! [[ "${1}" =~ ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$|^(LL|WL)$ ]]; then
    printOutput "1" "Invalid playlist ID [${1}] passed to playlistDelete function"
    return 1
fi
if ! [[ "${2}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid rating key [${2}] passed to playlistDelete function"
    return 1
fi

local playlistId="${1}"
local playlistKey="${2}"

printOutput "4" "Removing stale items from playlist [${playlistKey}] for playlist ID [${playlistId}]"

readarray -t plVidList < <(sqDb "SELECT FILE_ID FROM playlist_order WHERE PLAYLIST_ID = '${playlistId//\'/\'\'}' ORDER BY PLAYLIST_INDEX ASC;")
playlistGetOrder "${playlistKey}"

local anyRemoved="0"

for ii in "${plexPlaylistOrder[@]}"; do
    local inDbPlaylist="0"
    for jj in "${plVidList[@]}"; do
        printOutput "5" "Checking for file ID [${jj}] in playlist index"
        if [[ "${jj}" == "${ii}" ]]; then
            printOutput "5" "Found file ID [${ii}] matching playlist index [${jj}]"
            inDbPlaylist="1"
            break
        fi
    done
    if [[ "${inDbPlaylist}" -eq "0" ]]; then
        getFileRatingKey "${ii}"
        callCurlGet "${plexAdd}/playlists/${playlistKey}/items?X-Plex-Token=${plexToken}"
        playlistItemId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${ratingKey}\" ) .\"+@playlistItemID\"" <<<"${curlOutput}")"
        anyRemoved="1"
        printOutput "3" "Removing file ID [${ii}] with rating key [${ratingKey}] from playlist [${playlistKey}], as it does not appear in the playlist index"
        callCurlDelete "${plexAdd}/playlists/${playlistKey}/items/${playlistItemId}?X-Plex-Token=${plexToken}"
        fi
done

if [[ "${anyRemoved}" -eq "1" ]]; then
    playlistGetOrder "${playlistKey}"
fi
}

function playlistUpdate {
if ! [[ "${1}" =~ ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$|^(LL|WL)$ ]]; then
    printOutput "1" "Invalid playlist ID [${1}] passed to playlistSort function"
    return 1
fi
if ! [[ "${2}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Invalid rating key [${2}] passed to playlistSort function"
    return 1
fi
playlistDesc="$(sqDb "SELECT DESC FROM playlist WHERE PLAYLIST_ID = '${1//\'/\'\'}';")"
if [[ -z "${playlistDesc}" || "${playlistDesc}" == "null" ]]; then
    # No playlist description set
    playlistDesc="https://www.youtube.com/playlist?list=${1}${lineBreak}Playlist last updated $(date)"
else
    playlistDesc="${playlistDesc}${lineBreak}-----${lineBreak}https://www.youtube.com/playlist?list=${1}${lineBreak}Playlist last updated $(date)"
fi
playlistDescEncoded="$(rawUrlEncode "${playlistDesc}")"
if callCurlPut "${plexAdd}/library/sections/${libraryId}/all?type=18&id=${2}&includeExternalMedia=1&summary.value=${playlistDescEncoded}&summary.locked=1&X-Plex-Token=${plexToken}"; then
    printOutput "5" "Updated description for playlist ID [${1}]"
else
    printOutput "1" "Failed to update description for playlist ID [${1}]"
fi

# Update the image
playlistImg="$(sqDb "SELECT IMAGE FROM playlist WHERE PLAYLIST_ID = '${1//\'/\'\'}';")"
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
    badExit "104" "Error: \"${realPath%/*}/${scriptName%.bash}.env\" does not appear to exist"
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
    printOutput "5" "Validated video output directory [${outputDir}]"
    outputDir="${outputDir%/}"
fi
allowAudio="0"
if [[ -n "${outputDirAudio}" ]]; then
    if ! [[ -d "${outputDirAudio}" ]]; then
        printOutput "1" "Audio output dir [${outputDirAudio}] does not appear to exist -- Disabling audio only library support"
    else
        printOutput "5" "Validated audio output directory [${outputDirAudio}]"
        allowAudio="1"
    fi
fi
if [[ -z "${tmpDir}" ]]; then
    printOutput "1" "Temporary directory [${tmpDir}] is not set"
    varFail="1"
else
    tmpDir="${tmpDir%/}"
    # Create our tmpDir
    if ! [[ -d "${tmpDir}" ]]; then
        if ! mkdir -p "${tmpDir}"; then
            badExit "105" "Unable to create tmp dir [${tmpDir}]"
        fi
    fi
    tmpDir="$(mktemp -d -p "${tmpDir}")"
fi

if [[ -z "${ytApiKey}" ]]; then
    printOutput "2" "No YouTube Data API key provided"
    varFail="1"
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
    badExit "106" "Please fix above errors"
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
dbRebuild="0"

# Define some global variables
sqliteDb="${realPath%/*}/.${scriptName}.db"
apiCallsYouTube="0"
apiCallsSponsor="0"
totalUnits="0"
totalVideoUnits="0"
totalCaptionsUnits="0"
totalChannelsUnits="0"
totalPlaylistsUnits="0"

declare -A reindexArr watchedArr verifiedArr updateMetadataChannel updateMetadataVideo updateMetadataArtist updateMetadataAlbum updatePlaylist updateSubtitles titleArr rkArr chanIdLookup updateVideoMetadata updateAudioMetadata newAudioDir

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
            # We were passed a specific file ID to update
            # Make sure we're not already updating all
            if [[ "${updateMetadataVideo[0]}" == "all" ]]; then
                printOutput "2" "Ignoring video metadata update call for file ID [${2}] as all videos are already being updated"
            # Make sure we're not already updating missing
            elif [[ "${updateMetadataVideo[0]}" == "missing" ]]; then
                printOutput "2" "Ignoring video metadata update call for file ID [${2}] as missing videos are already being updated"
            else
                printOutput "4" "Marking file ID [${2}] for metadata update"
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
    "-m"|"--artist-metadata")
        # Validate our following parameter
        if [[ "${2}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
            # We were passed a specific channel ID to update
            # Make sure we're not already updating all
            if [[ "${updateMetadataArtist[0]}" == "all" ]]; then
                printOutput "2" "Ignoring channel metadata update call for channel ID [${2}] as all artists are already being updated"
            else
                printOutput "4" "Marking channel ID [${2}] for metadata update"
                updateMetadataArtist["${2}"]="true"
            fi
        elif [[ "${2}" == "all" ]]; then
            # We are updating all artists
            if ! [[ "${updateMetadataArtist[0]}" == "all" ]]; then
                unset updateMetadataArtist
                updateMetadataArtist[0]="all"
                printOutput "4" "Marking all artists for metadata update"
            fi
        else
            printOutput "1" "Invalid option [${2}] passed for updating channel metadata"
        fi
        shift
    ;;
    "-a"|"--album-metadata")
        # Validate our following parameter
        if [[ "${2}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
            # We were passed a specific file ID to update
            # Make sure we're not already updating all
            if [[ "${updateMetadataAlbum[0]}" == "all" ]]; then
                printOutput "2" "Ignoring album metadata update call for file ID [${2}] as all albums are already being updated"
            # Make sure we're not already updating missing
            elif [[ "${updateMetadataAlbum[0]}" == "missing" ]]; then
                printOutput "2" "Ignoring album metadata update call for file ID [${2}] as missing albums are already being updated"
            else
                printOutput "4" "Marking file ID [${2}] for metadata update"
                updateMetadataAlbum["_${2}"]="true"
            fi
        elif [[ "${2}" == "all" ]]; then
            # We are updating all albums
            if ! [[ "${updateMetadataAlbum[0]}" == "all" ]]; then
                unset updateMetadataAlbum
                updateMetadataAlbum[0]="all"
                printOutput "4" "Marking all albums for metadata update"
            fi
        else
            printOutput "1" "Invalid option [${2}] passed for updating video metadata"
        fi
        shift
    ;;
    "-t"|"--subtitles")
        # Validate our following parameter
        if [[ "${2}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
            # We were passed a specific file ID to update
            # Make sure we're not already updating all
            if [[ "${updateSubtitles[0]}" == "all" ]]; then
                printOutput "2" "Ignoring video subtitle update call for file ID [${2}] as all videos are already being updated"
            # Make sure we're not already updating missing
            elif [[ "${updateSubtitles[0]}" == "missing" ]]; then
                printOutput "2" "Ignoring video subtitle update call for file ID [${2}] as missing videos are already being updated"
            else
                printOutput "4" "Marking file ID [${2}] for subtitle update"
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
            printOutput "1" "Invalid options [${2}] passed for file ID to be ignored"
        fi
        shift
    ;;
    "-d"|"--db-rebuild")
        dbRebuild="1"
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

                             Usage is: -c \"TARGET\"
                             If you want to update a specific channel,
                             list its channel ID as the TARGET, or you
                             can use the ALL if you want to update all
                             channels.

-m  --artist-metadata       Updates descriptions and images for
                             artists already downloaded.

                             Usage is: -c \"TARGET\"
                             If you want to update a specific channel,
                             list its channel ID as the TARGET, or you
                             can use the ALL if you want to update all
                             channels.

-p  --playlist-metadata     Updates descriptions and images for
                             playlists and colletions already made.

                             Usage is: -p \"TARGET\"
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

-d  --db-rebuild            Rebuilds the sqlite database."

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
            badExit "107" "Update downloaded, but unable to \`chmod +x\`"
        fi
    else
        badExit "108" "Unable to download Update"
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
                badExit "109" "Impossible condition"
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

# If no database exists, create one
if ! [[ -e "${sqliteDb}" ]]; then
    printOutput "3" "${colorBlue}############### Initializing database #################${colorReset}"
    if initDb "${sqliteDb}"; then
        printOutput "3" "DB successfully initialized [${sqliteDb}]"
    else
        badExit "110" "Failed to initialize DB [${sqliteDb}]"
    fi
fi

# Preform database maintenance, if needed
if [[ "${dbRebuild}" -eq "1" ]]; then
    startTime="$(($(date +%s%N)/1000000))"
    printOutput "3" "${colorBlue}############## Performing database rebuild ############${colorReset}"

    # ========== Validators ==========
    function validate_int { [[ "${1}" =~ ^[0-9]+$ ]]; }
    function validate_bool { [[ "${1}" == "0" || "${1}" == "1" ]]; }
    function validate_id { [[ "${1}" =~ ^[A-Za-z0-9_-]{11}$ ]]; }
    function validate_channel { [[ "${1}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; }
    function validate_url { [[ "${1}" =~ ^https?:// ]]; }
    function validate_lang { [[ "${1}" =~ ^([a-z]{2}|No\ subs\ available)$ ]]; }
    function validate_visibility { [[ "${1}" == "public" || "${1}" == "private" ]]; }
    function validate_type { [[ "${1}" =~ ^(video|members_only|short|waslive|normal_private|live|short_private)$ ]]; }
    function validate_status { [[ "${1}" =~ ^(downloaded|queued|failed|skipped|ignore|waiting)$ ]]; }
    function validate_audio_status { [[ -z "${1}" || "${1}" =~ ^(downloaded|queued|failed|skipped|ignore|waiting)$ ]]; }
    function validate_format { [[ "${1}" =~ ^(144|240|360|480|720|1080|1440|2160|4320|import|none|original)$ ]]; }
    function validate_audio_format { [[ -z "${1}" || "${1}" =~ ^(opus|mp3)$ ]]; }
    function validate_sb_mode { [[ "${1}" =~ ^(disable|mark|remove)$ ]]; }
    function validate_playlist_id { [[ "${1}" =~ ^(PL|RD|UU|OL)[A-Za-z0-9_-]+$ || "${1}" =~ ^(LL|WL)$ ]]; }

    # ========== Helpers ==========
    function log_validation_fail {
        local table="${1}" field="${2}" id="${3}" value="${4}"
        validationError+=("[INVALID] ${table}.${field} (ID: ${id}) => '${value}'")
    }

    function update_field {
        local table="${1}" field="${2}" id_col="${3}" id="${4}" value="${5}"
        if [[ -z "$value" ]]; then
            outputArr+=("UPDATE ${table} SET ${field} = NULL WHERE ${id_col} = '${id//\'/\'\'}';")
        else
            outputArr+=("UPDATE ${table} SET ${field} = '${value//\'/\'\'}' WHERE ${id_col} = '${id//\'/\'\'}';")
        fi
    }

    # ========== Main Import Logic ==========
    function import_table_rows {
        local table="${1}" id_column="${2}"
        shift 2
        local fields=("${@}")

        printOutput "3" "Importing table [${table}]"
        readarray -t ids < <(sqlite3 "${sqliteDb}" "SELECT ${id_column} FROM ${table};")
        n="1"
        for id in "${ids[@]}"; do
            progressBar "${n}" "${#ids[@]}"
            (( n++ ))
            sqlite3 "${sqliteDb}" "INSERT OR IGNORE INTO ${table} (${id_column//\'/\'\'}) VALUES ('${id//\'/\'\'}');"
            for field in "${fields[@]}"; do
                value=$(sqlite3 "${sqliteDb}" "SELECT ${field} FROM ${table} WHERE ${id_column} = '${id//\'/\'\'}';")

                typeCheck=$(sqlite3 "${sqliteDb}" "SELECT typeof(${field}) FROM ${table} WHERE ${id_column} = '${id//\'/\'\'}';")

                if [[ "${typeCheck}" == "blob" ]]; then
                    log_validation_fail "${table}" "${field}" "${id}" "BLOB"
                    continue
                fi

                if type -t validate_${field,,} &>/dev/null && ! validate_${field,,} "${value}"; then
                    log_validation_fail "${table}" "${field}" "${id}" "${value}"
                else
                    update_field "${table}" "${field}" "${id_column}" "${id}" "${value}"
                fi
            done
        done
        # Pad the end of the progress bar
        echo ""
    }

    # Rebuild tables
    import_table_rows "config" "FILE_ID" \
        VIDEO_RESOLUTION MARK_WATCHED ALLOW_SHORTS ALLOW_LIVE \
        SUBTITLE_LANGUAGES SPONSORBLOCK_ENABLED_VIDEO SPONSORBLOCK_REQUIRED_VIDEO \
        SPONSORBLOCK_FLAGS_VIDEO AUDIO_FORMAT SPONSORBLOCK_ENABLED_AUDIO \
        SPONSORBLOCK_REQUIRED_AUDIO SPONSORBLOCK_FLAGS_AUDIO SOURCE CREATED UPDATED

    import_table_rows "hash" "FILE" \
        HASH CREATED UPDATED

    import_table_rows "channel" "CHANNEL_ID" \
        NAME NAME_SAFE TIMESTAMP SUB_COUNT COUNTRY URL VID_COUNT \
        VIEW_COUNT DESC PATH IMAGE BANNER CREATED UPDATED

    import_table_rows "media" "FILE_ID" \
        TITLE TITLE_SAFE CHANNEL_ID TIMESTAMP THUMBNAIL_URL UPLOAD_YEAR YEAR_INDEX \
        DESC TYPE SPONSORBLOCK_AVAILABLE VIDEO_STATUS VIDEO_ERROR \
        AUDIO_STATUS AUDIO_ERROR CREATED UPDATED

    import_table_rows "playlist" "PLAYLIST_ID" \
        VISIBILITY TITLE DESC IMAGE AUDIO CREATED UPDATED

    import_table_rows "playlist_order" "INT_ID" \
        FILE_ID PLAYLIST_ID PLAYLIST_INDEX CREATED UPDATED

    import_table_rows "rating_key_channel" "CHANNEL_ID" \
        VIDEO_RATING_KEY AUDIO_RATING_KEY CREATED UPDATED

    import_table_rows "rating_key_album" "FILE_ID" \
        RATING_KEY CREATED UPDATED

    import_table_rows "subtitle" "INT_ID" \
        FILE_ID LANG_CODE CREATED UPDATED

    import_table_rows "api_log" "INT_ID" \
        CALL COST RESPONSE EPOCH TIME

    import_table_rows "db_log" "INT_ID" \
        COMMAND OUTPUT TIME

    # Write the instructions
    printOutput "4" "Writing SQL instructions"
    sqlInstr="${sqliteDb%db}sql"
    printf "%s\n" "${outputArr[@]}" > "${sqlInstr}"
    printOutput "4" "SQL instructions written to [${sqlInstr}]"

    # Move the old DB
    dbBackup="${sqliteDb%db}old-$(date +%s).db"
    if mv "${sqliteDb}" "${dbBackup}"; then
        printOutput "3" "Backed up DB [${sqliteDb}] to [${dbBackup}]"
    else
        badExit "111" "Failed to back up DB [${sqliteDb}] to [${dbBackup}]"
    fi
    # Create a new DB
    if initDb "${sqliteDb}"; then
        printOutput "3" "DB successfully initialized [${sqliteDb}]"
    else
        badExit "112" "Failed to initialize DB [${sqliteDb}]"
    fi

    # Import
    printOutput "4" "Importing instructions"
    if sqlite3 "${sqliteDb}" < "${sqlInstr}"; then
        printOutput "3" "Database rebuild complete [Took $(timeDiff "${startTime}")]"
    else
        printOutput "1" "Failed to import instructions"
    fi

    # Print any errors
    if [[ "${#validationError[@]}" -ne "0" ]]; then
        printOutput "2" "Validation error log:"
        for line in "${validationError[@]}"; do
            printOutput "1" "${line}"
        done
    fi

    cleanExit
fi

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

# Verify that we can connect to Plex
printOutput "3" "${colorBlue}############# Verifying Plex connectivity #############${colorReset}"
getContainerIp "${plexIp}"

# Build our full address
plexAdd="${plexScheme}://${containerIp}:${plexPort}"
if ! callCurlGet "${plexAdd}/servers?X-Plex-Token=${plexToken}"; then
    badExit "113" "Unable to intiate connection to the Plex Media Server"
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
    badExit "114" "No Plex Media Servers found."
fi
if [[ -z "${serverName}" || -z "${serverVersion}" || -z "${serverMachineId}" ]]; then
    badExit "115" "Unable to validate Plex Media Server"
fi
# Get the library ID for our video output directory
# Count how many libraries we have
callCurlGet "${plexAdd}/library/sections/?X-Plex-Token=${plexToken}"
numLibraries="$(yq -p xml ".MediaContainer.Directory | length" <<<"${curlOutput}")"
if [[ "${numLibraries}" -eq "0" ]]; then
    badExit "116" "No libraries detected in the Plex Media Server"
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
    badExit "117" "Unable to identify [${outputDir}] from existing Plex libraries"
fi
if ! [[ "${libraryType}" == "show" ]]; then
    badExit "118" "Plex Library not detected as 'TV Show' type library [Found: ${libraryType}] -- Unable to proceed"
fi
if ! [[ "${libraryScanner}" == "Plex Series Scanner" ]]; then
    badExit "119" "Plex Library Scanner not detected as 'Plex Series Scanner' [Found: ${libraryScanner}] -- Unable to proceed"
fi

# If we have audio support enabled, get the library ID for our audio library
if [[ "${allowAudio}" -eq "1" ]]; then
    z="0"
    while [[ "${z}" -lt "${numLibraries}" ]]; do
        # Get the path for our library ID
        plexPath="$(yq -p xml ".MediaContainer.Directory[${z}].Location.\"+@path\"" <<<"${curlOutput}")"
        # Match based on the top level directory
        if [[ "${outputDirAudio##*/}" == "${plexPath##*/}" ]]; then
            # Get the library name
            audioLibraryName="$(yq -p xml ".MediaContainer.Directory[${z}].\"+@title\"" <<<"${curlOutput}")"
            # Get the library ID
            audioLibraryId="$(yq -p xml ".MediaContainer.Directory[${z}].\"+@key\"" <<<"${curlOutput}")"
            # Get the library type
            audioLibraryType="$(yq -p xml ".MediaContainer.Directory[${z}].\"+@type\"" <<<"${curlOutput}")"
            # Get the library Scanner
            audioLibraryScanner="$(yq -p xml ".MediaContainer.Directory[${z}].\"+@scanner\"" <<<"${curlOutput}")"

            printOutput "4" "Matched Plex audio library [${audioLibraryName}] to library ID [${audioLibraryId}]"
            break
        fi
        (( z++ ))
    done
    if [[ -z "${audioLibraryId}" ]]; then
        printOutput "1" "Unable to identify audio [${outputDirAudio}] from existing Plex libraries -- Disabling audio library support"
        allowAudio="0"
    fi
    if ! [[ "${audioLibraryType}" == "artist" ]]; then
        printOutput "1" "Plex Library not detected as 'Music' type library [Found: ${audioLibraryType}] -- Disabling audio library support"
        allowAudio="0"
    fi
    if ! [[ "${audioLibraryScanner}" == "Plex Music Scanner" ]]; then
        printOutput "1" "Plex Library Scanner not detected as 'Plex Music Scanner' [Found: ${audioLibraryScanner}] -- Disabling audio library support"
        allowAudio="0"
    fi
fi

printOutput "3" "Validated Plex Media Server: ${serverName} [Version: ${serverVersion}] [Machine ID: ${serverMachineId}]"

last24HoursUsage="$(sqDb "SELECT COALESCE(SUM(COST), 0) FROM api_log WHERE EPOCH > strftime('%s', 'now', '-1 day');")"
last24HoursUsage="$(( last24HoursUsage ))"
printOutput "3" "24 hour API unit usage [${last24HoursUsage}]"

if [[ "${verifyMedia}" -eq "1" ]]; then
    printOutput "3" "${colorBlue}############### Verifying media library ###############${colorReset}"
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
        # Get a list of seasons for that show
        callCurlGet "${plexAdd}/library/metadata/${ratingKey}/children?X-Plex-Token=${plexToken}"
        # Get the show name, for printing
        seriesTitle="$(yq -p xml ".MediaContainer.\"+@parentTitle\"" <<<"${curlOutput}")"
        printOutput "4" "Verifying series [${seriesTitle}] with rating key [${ratingKey}]"
        readarray -t knownSeasonRatingKeys < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
        # For every season of that show
        for seasonRatingKey in "${knownSeasonRatingKeys[@]}"; do
            # Get a list of episodes for that season
            callCurlGet "${plexAdd}/library/metadata/${seasonRatingKey}/children?X-Plex-Token=${plexToken}"
            # Get the season number, for printing
            seasonYear="$(yq -p xml ".MediaContainer.\"+@parentIndex\"" <<<"${curlOutput}")"
            printOutput "4" "Verifying season year [${seasonYear}] with rating key [${seasonRatingKey}]"
            # For every episode of that season
            while read -r knownFileId; do
                # Isolate the file ID
                ytId="${knownFileId%\]\.mp4}"
                ytId="${ytId##* \[}"
                # Remove the file ID from the array
                if [[ -n "${knownFiles[_${ytId}]}" ]]; then
                    unset knownFiles["_${ytId}"]
                    printOutput "5" "Verified [${knownFileId##*/}]"
                    (( verifySuccessCount++ ))
                else
                    # If the file ID is not in the array, log it in an error array (Exists in Plex, not on FS)
                    orphanFiles+=("${knownFileId}")
                    printOutput "5" "Failed to verify [${knownFileId##*/}]"
                    (( verifyFailCount++ ))
                fi
            done < <(yq -p xml ".MediaContainer.Video | ([] + .) | .[] | .Media | ([] + .) | .[] | .Part.\"+@file\"" <<<"${curlOutput}")
        done
    done
    printOutput "3" "Verified ${verifySuccessCount} files | Failed to verify ${verifyFailCount} files"
    # Print any remaining FS file ID's which were not matched in plex (Exist on FS, not in Plex) -- Print error array, if not empty
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
    printOutput "3" "${colorBlue}################ Verifying rating keys ################${colorReset}"
    # Update all rating keys for all channels in Plex
    # Get a list of shows from the database
    callCurlGet "${plexAdd}/library/sections/${libraryId}/all?X-Plex-Token=${plexToken}"
    while read -r ratingKey; do
        # Get a list of seasons for that show
        callCurlGet "${plexAdd}/library/metadata/${ratingKey}/children?X-Plex-Token=${plexToken}"
        # Get the show name, for printing
        seriesTitle="$(yq -p xml ".MediaContainer.\"+@parentTitle\"" <<<"${curlOutput}")"
        # Get the first season
        firstYear="$(yq -p xml ".MediaContainer.Directory  | ([] + .) | .[0].\"+@index\"" <<<"${curlOutput}")"
        # Get the first season rating key
        firstYearKey="$(yq -p xml ".MediaContainer.Directory  | ([] + .) | .[0].\"+@ratingKey\"" <<<"${curlOutput}")"
        if [[ "${firstYear}" == "null" ]]; then
            firstYear="$(yq -p xml ".MediaContainer.Directory  | ([] + .) | .[1].\"+@index\"" <<<"${curlOutput}")"
            firstYearKey="$(yq -p xml ".MediaContainer.Directory  | ([] + .) | .[1].\"+@ratingKey\"" <<<"${curlOutput}")"
        fi
        printOutput "4" "Looking up series [${seriesTitle}] via rating key [${ratingKey}] with season year [${firstYear}] via rating key [${firstYearKey}]"
        # Get the first file of the first season
        callCurlGet "${plexAdd}/library/metadata/${firstYearKey}/children?X-Plex-Token=${plexToken}"
        firstFileId="$(yq -p xml ".MediaContainer.Video | ([] + .) | .[0].Media.Part.\"+@file\"" <<<"${curlOutput}")"
        firstFileId="${firstFileId%\]\.mp4}"
        firstFileId="${firstFileId##*\[}"
        # Now look up that file ID in the database for its CHANNEL_ID
        firstFileChannelId="$(sqDb "SELECT CHANNEL_ID FROM media WHERE FILE_ID = '${firstFileId//\'/\'\'}';")"
        # Now get the rating key for that channel ID in the database
        readarray -t foundRatingKey < <(sqDb "SELECT VIDEO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${firstFileChannelId//\'/\'\'}';")
        if [[ "${#foundRatingKey[@]}" -eq "0" ]]; then
            # Doesn't exist in the database
            printOutput "5" "No rating keys found in database for series [${seriesTitle}]"
            if sqDb "INSERT INTO rating_key_channel (CHANNEL_ID, VIDEO_RATING_KEY, CREATED, UPDATED) VALUES ('${firstFileChannelId//\'/\'\'}', ${ratingKey}, '$(date)', '$(date)');"; then
                printOutput "3" "Added rating key [${ratingKey}] for series [${seriesTitle}] to database"
            else
                printOutput "1" "Failed to add rating key [${ratingKey}] for series [${seriesTitle}] to database"
            fi
        elif [[ "${#foundRatingKey[@]}" -eq "1" ]]; then
            # Something exists. Compare.
            if [[ "${foundRatingKey[0]}" -eq "${ratingKey}" ]]; then
                # Matches
                printOutput "3" "Verified existing rating key [${ratingKey}] for series [${seriesTitle}]"
            else
                # Mismatch. Update.
                if sqDb "UPDATE rating_key_channel SET VIDEO_RATING_KEY = ${ratingKey}, UPDATED = '$(date)' WHERE CHANNEL_ID = '${firstFileChannelId//\'/\'\'}';"; then
                    printOutput "5" "Updated stale rating key for series [${seriesTitle}] from [${foundRatingKey[0]}] to [${ratingKey}]"
                else
                    printOutput "1" "Failed to update stale rating key for series [${seriesTitle}] from [${foundRatingKey[0]}] to [${ratingKey}]"
                fi
            fi
        else
            printOutput "1" "Unexpected count [${#foundRatingKey[@]}] when looking up rating key for channel ID [${firstFileChannelId}] - [${foundRatingKey[*]}]"
        fi
    done < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
    # TODO: Update audio rating keys
fi

if [[ "${#updateMetadataChannel[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}############## Updating channel metadata ##############${colorReset}"
    if [[ "${updateMetadataChannel[0]}" == "all" ]]; then
        callCurlGet "${plexAdd}/library/sections/${libraryId}/all?X-Plex-Token=${plexToken}"
        declare -A dblChk
        while read -r i title; do
            dblChk["${i}"]="${title}"
        done < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | ( .\"+@ratingKey\" + \" \" + .\"+@title\" )" <<<"${curlOutput}")
        # Update all channel information in database
        printOutput "3" "Processing channels in database"
        while read -r channelId; do
            chanName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            printOutput "4" "Updating database information for channel ID [${channelId}] [${chanName}]"
            if channelToDb "${channelId}"; then
                channelRatingKey="$(sqDb "SELECT VIDEO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
                if [[ -z "${channelRatingKey}" ]]; then
                    if ! setSeriesRatingKey "${channelId}"; then
                        printOutput "1" "Failed to set series rating key for channel ID [${channelId}]"
                        continue
                    else
                        channelRatingKey="$(sqDb "SELECT VIDEO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
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
        done < <(sqDb "SELECT DISTINCT CHANNEL_ID FROM media WHERE VIDEO_STATUS = 'downloaded';")
        # Update all channel images, banner images, season images
        printOutput "3" "Updating series media images"
        while read -r channelId; do
            chanName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            printOutput "4" "Updating series images for channel ID [${channelId}] [${chanName}]"
            # Create the series image (This will only create new images if there's been an updated image)
            makeShowImage "${channelId}"
        done < <(sqDb "SELECT CHANNEL_ID FROM channel;")

        # Update all series metadata in Plex
        printOutput "3" "Setting series metadata in PMS"
        while read -r channelId; do
            printOutput "4" "Updating metadata for channel ID [${channelId}]"
            # Get the series rating key
            channelRatingKey="$(sqDb "SELECT VIDEO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            if [[ -n "${channelRatingKey}" ]]; then
                setSeriesMetadata "${channelRatingKey}"
            else
                printOutput "1" "Unable to retrieve rating key for channel ID [${channelId}]"
            fi
        done < <(sqDb "SELECT CHANNEL_ID FROM channel;")

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
            chanName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            printOutput "4" "Updating database information for channel ID [${channelId}] [${chanName}]"
            if channelToDb "${channelId}"; then
                channelRatingKey="$(sqDb "SELECT VIDEO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
                if [[ -z "${channelRatingKey}" ]]; then
                    if ! setSeriesRatingKey "${channelId}"; then
                        printOutput "1" "Failed to set series rating key for channel ID [${channelId}]"
                        continue
                    else
                        channelRatingKey="$(sqDb "SELECT VIDEO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
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
            channelRatingKey="$(sqDb "SELECT VIDEO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            if [[ -n "${channelRatingKey}" ]]; then
                setSeriesMetadata "${channelRatingKey}"
            else
                printOutput "1" "Unable to retrieve rating key for channel ID [${channelId}]"
            fi
        done
    fi
fi

if [[ "${#updateMetadataArtist[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}############## Updating artist metadata ###############${colorReset}"
    if [[ "${updateMetadataArtist[0]}" == "all" ]]; then
        callCurlGet "${plexAdd}/library/sections/${audioLibraryId}/all?X-Plex-Token=${plexToken}"
        declare -A dblChk
        while read -r i title; do
            dblChk["${i}"]="${title}"
        done < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | ( .\"+@ratingKey\" + \" \" + .\"+@title\" )" <<<"${curlOutput}")
        # Update all channel information in database
        printOutput "3" "Processing channels in database"
        while read -r channelId; do
            chanName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            printOutput "4" "Updating database information for channel ID [${channelId}] [${chanName}]"
            if channelToDb "${channelId}"; then
                channelRatingKey="$(sqDb "SELECT AUDIO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
                if [[ -z "${channelRatingKey}" ]]; then
                    if ! setArtistRatingKey "${channelId}"; then
                        printOutput "1" "Failed to set artist rating key for channel ID [${channelId}]"
                        continue
                    else
                        channelRatingKey="$(sqDb "SELECT AUDIO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
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
        done < <(sqDb "SELECT DISTINCT CHANNEL_ID FROM media WHERE AUDIO_STATUS = 'downloaded';")
        # Update all channel images, banner images, season images
        printOutput "3" "Updating artist media images"
        while read -r channelId; do
            chanName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            printOutput "4" "Updating artist images for channel ID [${channelId}] [${chanName}]"
            # Create the artist image (This will only create new images if there's been an updated image)
            makeArtistImage "${channelId}"
        done < <(sqDb "SELECT CHANNEL_ID FROM channel;")

        # Update all artist metadata in Plex
        printOutput "3" "Setting artist metadata in PMS"
        while read -r channelId; do
            printOutput "4" "Updating metadata for channel ID [${channelId}]"
            # Get the artist rating key
            channelRatingKey="$(sqDb "SELECT AUDIO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            if [[ -n "${channelRatingKey}" ]]; then
                setArtistMetadata "${channelRatingKey}"
            else
                printOutput "1" "Unable to retrieve rating key for channel ID [${channelId}]"
            fi
        done < <(sqDb "SELECT CHANNEL_ID FROM channel;")

        if [[ "${#dblChk[@]}" -ne "0" ]]; then
            printOutput "1" "Failed to update the following Plex artist:"
            for title in "${dblChk[@]}"; do
                printOutput "1" "${title}"
            done
        else
            printOutput "3" "Successfully updated all artist in Plex"
        fi

    else
        printOutput "3" "Processing [${#updateMetadataArtist[@]}] channels"
        for channelId in "${!updateMetadataArtist[@]}"; do
            # Update the database entries for the channel ID
            chanName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            printOutput "4" "Updating database information for channel ID [${channelId}] [${chanName}]"
            if channelToDb "${channelId}"; then
                channelRatingKey="$(sqDb "SELECT AUDIO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
                if [[ -z "${channelRatingKey}" ]]; then
                    if ! setArtistRatingKey "${channelId}"; then
                        printOutput "1" "Failed to set artist rating key for channel ID [${channelId}]"
                        continue
                    else
                        channelRatingKey="$(sqDb "SELECT AUDIO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
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
            printOutput "4" "Updating artist images for channel ID [${channelId}] [${chanName}]"
            makeArtistImage "${channelId}"

            # Update the metadata
            printOutput "4" "Updating metadata for channel ID [${channelId}]"
            # Get the artist rating key
            channelRatingKey="$(sqDb "SELECT AUDIO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            if [[ -n "${channelRatingKey}" ]]; then
                setArtistMetadata "${channelRatingKey}"
            else
                printOutput "1" "Unable to retrieve rating key for channel ID [${channelId}]"
            fi
        done
    fi
fi

# TODO: Add audio album update to the 'help' display
if [[ "${#updateMetadataAlbum[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}############### Updating album metadata ###############${colorReset}"
    # 1. Get a list of all file ID's which are 'downloaded' for desired audio (From DB)
    declare -A knownAlbums
    while read -r ytId; do
        knownAlbums["_${ytId}"]="true"
    done < <(sqDb "SELECT FILE_ID FROM media WHERE AUDIO_STATUS = 'downloaded';")
    if [[ "${updateMetadataAlbum[0]}" == "all" ]]; then
        # 2. If we're updating 'all', get a list of all artists (From Plex)
        # Get a list of all artist rating keys
        callCurlGet "${plexAdd}/library/sections/${audioLibraryId}/all?X-Plex-Token=${plexToken}"
        readarray -t artistRatingKeys < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
        printOutput "4" "Found [${#artistRatingKeys[@]}] artist rating keys to iterate through"
        n="1"
        # 3. Get a list of all albums for each artist (From Plex)
        for artistRatingKey in "${artistRatingKeys[@]}"; do
            printOutput "4" "Grabbing album rating keys for artist rating key [${artistRatingKey}] [Item ${n} of ${#artistRatingKeys[@]}]"
            (( n++ ))
            # Get a list of their album rating keys
            callCurlGet "${plexAdd}/library/metadata/${artistRatingKey}/children?X-Plex-Token=${plexToken}"
            while read -r albumRatingKey; do
                printOutput "5" "Found album rating key [${albumRatingKey}]"
                albumRatingKeys+=("${albumRatingKey}")
            done < <(yq -p xml ".MediaContainer.Directory | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
        done
        # We now have all album rating keys loaded in to ${albumRatingKeys[@]}
        printOutput "3" "Updating [${#albumRatingKeys[@]}] albums"
        n="1"
        totalItems="${#albumRatingKeys[@]}"
        for index in "${!albumRatingKeys[@]}"; do
            albumRatingKey="${albumRatingKeys[${index}]}"
            printOutput "3" "Updating metadata for rating key [${albumRatingKey}] [Item ${n} of ${totalItems}]"
            (( n++ ))
            # 4. For each album, isolate its file ID
            callCurlGet "${plexAdd}/library/metadata/${albumRatingKey}/children?X-Plex-Token=${plexToken}"
            readarray -t foundFileIds < <(yq -p xml ".MediaContainer.Track | ([] + .) | .[] | .Media.Part.\"+@file\"" <<<"${curlOutput}")
            foundFileId="${foundFileIds[0]%/*}"
            foundFileId="${foundFileId%\]}"
            foundFileId="${foundFileId##*\[}"
            # Validate it
            if [[ "${foundFileId}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
                printOutput "5" "Found file ID [${foundFileId}] for album rating key [${albumRatingKey}]"
            else
                printOutput "1" "Unable to validate any file ID for album rating key [${albumRatingKey}] -- Skipping"
                continue
            fi
            # 5. Get the relevant details for that file ID
            # 6. Apply the relevant details for that file ID
            if setAlbumMetadata "${foundFileId}" "${albumRatingKey}"; then
                printOutput "4" "Successfully updated album metadata for file ID [${foundFileId}] via rating key [${albumRatingKey}]"
            else
                printOutput "1" "Failed to update album metadata for file ID [${foundFileId}] via rating key [${albumRatingKey}]"
                continue
            fi
            # 7. Remove that file ID from the double check array
            unset albumRatingKeys["${index}"]
            # 8. Remove that file ID from the triple check array
            unset knownAlbums["_${foundFileId}"]
            # 9. Store the updating album rating key
            dbCount="$(sqDb "SELECT COUNT(1) FROM rating_key_album WHERE FILE_ID = '${foundFileId}';")"
            if [[ "${dbCount}" -eq "0" ]]; then
                # Insert row if not exists
                if sqlite3 "${sqliteDb}" "INSERT INTO rating_key_album (FILE_ID, RATING_KEY, CREATED, UPDATED) VALUES ('${foundFileId//\'/\'\'}', ${albumRatingKey}, '$(date)', '$(date)');"; then
                    printOutput "5" "Initialized rating key for album file ID [${foundFileId}]"
                else
                    badExit "120" "Failed to initialize rating key for album file ID [${foundFileId}]"
                fi
            elif [[ "${dbCount}" -eq "1" ]]; then
                if sqlite3 "${sqliteDb}" "UPDATE rating_key_album SET RATING_KEY = ${albumRatingKey}, UPDATED = '$(date)' WHERE FILE_ID = '${foundFileId//\'/\'\'}';"; then
                    printOutput "5" "Updated rating key for album file ID [${foundFileId}]"
                else
                    badExit "121" "Failed to update rating key for album file ID [${foundFileId}]"
                fi
            else
                badExit "122" "Impossible condition"
            fi
        done
        # 8. Print any file ID's left over in the double check array
        if [[ "${#albumRatingKeys[@]}" -ne "0" ]]; then
            printOutput "1" "Failed to update album metadata for rating keys [${albumRatingKeys[*]}]"
        fi
        if [[ "${#knownAlbums[@]}" -ne "0" ]]; then
            for key in "${!knownAlbums[@]}"; do
                knownAlbumsError+=("${key#_}")
            done
            printOutput "1" "Failed to locate rating keys for file ID's [${knownAlbumsError[*]}]"
        fi
    else
        # This is for specific file ID's
        printOutput "3" "Updating [${#updateMetadataAlbum[@]}] albums"
        n="1"
        for ytId in "${!updateMetadataAlbum[@]}"; do
            ytId="${ytId#_}"
            # Get the rating key
            if getAlbumRatingKey "${ytId}"; then
                printOutput "5" "Retrieved album rating key [${albumRatingKey}] for file ID [${ytId}]"
            else
                printOutput "1" "Failed to retrieve album rating key for file ID [${ytId}] -- Skipping"
                continue
            fi
            # Update the metadata
            if setAlbumMetadata "${ytId}" "${albumRatingKey}"; then
                printOutput "4" "Successfully updated album metadata for file ID [${ytId}] via rating key [${albumRatingKey}]"
            else
                printOutput "1" "Failed to update album metadata for file ID [${ytId}] via rating key [${albumRatingKey}]"
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
    done < <(sqDb "SELECT PLAYLIST_ID FROM playlist;")
fi

if [[ "${#updateMetadataVideo[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}############### Updating video metadata ###############${colorReset}"

    # If our parameter is "all", then replace the array wtih an array of file ID's
    if [[ "${updateMetadataVideo[0]}" == "all" ]]; then
        unset updateMetadataVideo
        declare -A updateMetadataVideo
        while read -r ytId; do
            updateMetadataVideo["_${ytId}"]="true"
        done < <(sqDb "SELECT FILE_ID FROM media;")
    fi

    loopNum="0"
    for ytId in "${!updateMetadataVideo[@]}"; do
        (( loopNum++ ))
        ytId="${ytId#_}"
        printOutput "3" "Updating metadata for file ID [${ytId}] [Item ${loopNum} of ${#updateMetadataVideo[@]}]"
        # Get its current downloaded path
        readarray -t verifyPath < <(find "${outputDir}" -type f -name "*\[${ytId}\].mp4")
        if [[ "${#verifyPath[@]}" -eq "0" ]]; then
            # It's not downloaded yet?
            vidStatus="$(sqDb "SELECT VIDEO_STATUS FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            if [[ "${vidStatus}" == "downloaded" ]]; then
                # We think it's downloaded, so that's a problem
                printOutput "1" "File ID [${ytId}] is marked as downloaded, but cannot be located in [${outputDir}]"
            fi
        elif [[ "${#verifyPath[@]}" -eq "1" ]]; then
            # We only found one, that's good
            printOutput "5" "Verified file ID [${ytId}] at path [${verifyPath[0]}]"
        elif [[ "${#verifyPath[@]}" -ge "2" ]]; then
            # We found multiple matches, that's not good
            printOutput "1" "Found [${#verifyPath[@]}] matches for file ID [${ytId}] in [${outputDir}]"
            for path in "${verifyPath[@]}"; do
                printOutput "1" "${path}"
            done
            printOutput "1" "Skipping metadata update for file ID [${ytId}]"
            continue
        fi

        # We need the existing global variables for this video
        # We have the video format option
        outputResolution="$(sqDb "SELECT VIDEO_RESOLUTION FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # We have the include shorts option
        includeShorts="$(sqDb "SELECT ALLOW_SHORTS FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # We have the include live option
        includeLiveBroadcasts="$(sqDb "SELECT ALLOW_LIVE FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # We have the mark watched option
        markWatched="$(sqDb "SELECT MARK_WATCHED FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # We have the sponsor block enable option
        sponsorblockEnable="$(sqDb "SELECT SPONSORBLOCK_ENABLED_VIDEO FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # We have the sponsor block require option
        sponsorblockRequire="$(sqDb "SELECT SPONSORBLOCK_REQUIRED_VIDEO FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"

        # Go ahead and update the database entry
        ytIdToDb "${ytId}"

        # We only need to keep going if the file exists on the file system
        if [[ "${#verifyPath[@]}" -eq "0" ]]; then
            continue
        fi

        # Get the path that it _should_ be at
        channelId="$(sqDb "SELECT CHANNEL_ID FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${channelId}" ]]; then
            badExit "123" "Unable to determine channel ID for file ID [${ytId}] -- Possible database corruption"
        fi
        channelPath="$(sqDb "SELECT PATH FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
        if [[ -z "${channelPath}" ]]; then
            badExit "124" "Unable to determine channel path for file ID [${ytId}] -- Possible database corruption"
        fi
        channelName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
        if [[ -z "${channelName}" ]]; then
            badExit "125" "Unable to determine channel name for file ID [${ytId}] -- Possible database corruption"
        fi
        channelNameClean="$(sqDb "SELECT NAME_SAFE FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
        if [[ -z "${channelNameClean}" ]]; then
            badExit "126" "Unable to determine clean channel name for file ID [${ytId}] -- Possible database corruption"
        fi
        vidYear="$(sqDb "SELECT UPLOAD_YEAR FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidYear}" ]]; then
            badExit "127" "Unable to determine video year for file ID [${ytId}] -- Possible database corruption"
        fi
        vidIndex="$(sqDb "SELECT YEAR_INDEX FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidIndex}" ]]; then
            badExit "128" "Unable to determine video index for file ID [${ytId}] -- Possible database corruption"
        fi
        vidTitle="$(sqDb "SELECT TITLE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidTitle}" ]]; then
            badExit "129" "Unable to determine video title for file ID [${ytId}] -- Possible database corruption"
        fi
        vidTitleClean="$(sqDb "SELECT TITLE_SAFE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidTitleClean}" ]]; then
            badExit "130" "Unable to determine clean video title for file ID [${ytId}] -- Possible database corruption"
        fi
        # String it together
        verifyPathCorrect="${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4"

        # Verify that the two match
        if [[ "${verifyPath[0]}" == "${verifyPathCorrect}" ]]; then
            # We're good
            printOutput "5" "Verified file ID [${ytId}] to be correctly named on file system"
        else
            # We're not good. Let's go ahead and move the file to where it _should_ be.
            printOutput "4" "File ID [${ytId}] not correctly named on file system -- Fixing"
            # Make sure our destination exists
            if ! [[ -d "${verifyPathCorrect%/*}" ]]; then
                badExit "131" "Unexpected condition - Destination path [${verifyPathCorrect%/*}] for file ID [${verifyPath[0]}] does not exist"
            fi
            if mv "${verifyPath[0]}" "${verifyPathCorrect}"; then
                printOutput "3" "Corrected file ID [${ytId}] name on file system"
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
        printOutput "4" "Checking for updated thumbnail for file ID [${ytId}]"
        vidVisibility="$(sqDb "SELECT TYPE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        if [[ "${vidVisibility}" =~ ^.*_private$ ]]; then
            printOutput "2" "Unable to update thumbnail for file ID [${ytId}] due to no longer being public"
        else
            # Get the thumbnail URL
            thumbUrl="$(sqDb "SELECT THUMBNAIL_URL FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            if [[ -n "${thumbUrl}" ]]; then
                callCurlDownload "${thumbUrl}" "${tmpDir}/${ytId}.jpg"
            else
                printOutput "1" "Failed to retrieve thumbnail URL for file ID [${ytId}]"
                continue
            fi

            # Compare them
            if cmp -s "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg" "${tmpDir}/${ytId}.jpg"; then
                printOutput "5" "No changes detected for file ID [${ytId}], removing newly downloaded file thumbnail"
                if ! rm -f "${tmpDir}/${ytId}.jpg"; then
                    printOutput "1" "Failed to remove newly downloaded file thumbmail for file ID [${ytId}]"
                fi
            else
                printOutput "4" "New file thumbnail detected for file ID [${ytId}], backing up old image and replacing with new one"
                if ! mv "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg" "${outputDir}/${channelPath}/Season ${vidYear}/.${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].bak-$(date +%s).jpg"; then
                    printOutput "1" "Failed to back up previously downloaded file thumbnail for file ID [${ytId}]"
                fi
                if ! mv "${tmpDir}/${ytId}.jpg" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"; then
                    printOutput "1" "Failed to move newly downloaded show image file for channel ID [${1}]"
                else
                    printOutput "3" "Updated thumbnail for file ID [${ytId}]"
                fi
            fi

            if ! [[ -e "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg" ]]; then
                printOutput "1" "Failed to get thumbnail for file ID [${tmpId}]"
            fi
        fi
    done
fi

if [[ "${#updateSubtitles[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}################## Updating subtitles #################${colorReset}"
    if [[ "${updateSubtitles[0]}" == "all" ]]; then
        unset updateSubtitles
        declare -A updateSubtitles
        # Do a random order, as we'll likely exhaust our API calls with this, so randomizing it means future runs won't get stuck on the same data over and over
        while read -r ytId; do
            updateSubtitles["_${ytId}"]="true"
        done < <(sqDb "SELECT FILE_ID FROM media WHERE VIDEO_STATUS = 'downloaded' ORDER BY RANDOM();")
    elif [[ "${updateSubtitles[0]}" == "missing" ]]; then
        unset updateSubtitles
        declare -A updateSubtitles
        # Do a random order, as we'll likely exhaust our API calls with this, so randomizing it means future runs won't get stuck on the same data over and over
        while read -r ytId; do
            updateSubtitles["_${ytId}"]="true"
        done < <(sqDb "SELECT FILE_ID FROM media WHERE VIDEO_STATUS = 'downloaded' ORDER BY RANDOM();")
        # Remove file ID's which already have subtitles
        while read -r ytId; do
            unset updateSubtitles["_${ytId}"]
        done < <(sqDb "SELECT FILE_ID FROM subtitle;")
    fi
    subsLoopNum="0"
    for ytId in "${!updateSubtitles[@]}"; do
        (( subsLoopNum++ ))
        printOutput "4" "Checking subtitles for file ID [${ytId#_}] [Item ${subsLoopNum} of ${#updateSubtitles[@]}]"
        if ! downloadSubs "${ytId#_}"; then
            printOutput "1" "Failed to download subtitles for file ID [${ytId#_}]"
        fi
    done
fi

if [[ "${#ignoreId[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}############### Processing ID's to ignore #############${colorReset}"
    ignoreLoopNum="0"
    for ytId in "${ignoreId[@]}"; do
        (( ignoreLoopNum++ ))
        printOutput "3" "Processing file ID [${ytId}][Item ${ignoreLoopNum} of ${#ignoreId[@]}]"
        # Make sure it's not already in the database
        dbCount="$(sqDb "SELECT COUNT(1) FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        if [[ "${dbCount}" -eq "0" ]]; then
            # It's not in the database, add it as an IGNORE entry
            if sqDb "INSERT INTO media (FILE_ID, VIDEO_STATUS, CREATED, UPDATED) VALUES ('${ytId//\'/\'\'}', 'ignore', '$(date)', '$(date)');"; then
                printOutput "4" "Successfully marked file ID [${ytId}] to be ignored"
            else
                printOutput "1" "Failed to mark file ID [${ytId}] to be ignored"
            fi
        elif [[ "${dbCount}" -eq "1" ]]; then
            # Update it to an IGNORE entry
            if sqDb "UPDATE media SET VIDEO_STATUS = 'ignore', UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                printOutput "4" "Successfully updated file ID [${ytId}] to be ignored"
            else
                printOutput "1" "Failed to update file ID [${ytId}] to be ignored"
            fi
        else
            printOutput "1" "Unexpected dbCount returned [${dbCount}] for file ID [${ytId}] -- Possible database corruption"
        fi
    done
fi

if [[ "${#importDir[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}############# Checking for files to import ############${colorReset}"
    for dir in "${importDir[@]}"; do
        # Start by searching the import directory for files to import
        printOutput "5" "Found import dir: ${dir}"
        # Make sure the import dir actually exists
        if ! [[ -d "${dir}" ]]; then
            printOutput "1" "Import directory [${dir}] does not appear to actually exist -- Skipping"
        else
            # Find video files to import
            readarray -t importArrVideo < <(find "${dir}" -type f -regextype egrep -regex "^.*\[([A-Za-z0-9_-]{11})\]\.mp4")
            if [[ "${#importArrVideo[@]}" -ne "0" ]]; then
                printOutput "3" "Found [${#importArrVideo[@]}] video files to import"
                # Set some default global variables for these imported files
                markWatched="0"
                includeShorts="1"
                includeLiveBroadcasts="1"
                sponsorblockEnable="disable"
                sponsorblockRequire="0"
                n="1"
                for f in "${importArrVideo[@]}"; do
                    ytId="${f%\]\.mp4}"
                    ytId="${ytId##*\[}"
                    printOutput "4" "Processing file ID [${ytId}] [Item ${n} of ${#importArrVideo[@]}]"
                    (( n++ ))

                    # If it's already in the database, we can skip it
                    dbCount="$(sqDb "SELECT COUNT(1) FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Safety check
                        printOutput "5" "File ID [${ytId}] not present in database"
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # Safety check
                        printOutput "5" "File ID [${ytId}] already present in database"
                    else
                        badExit "132" "Unexpected count returned [${dbCount}] for file ID [${ytId}] -- Possible database corruption"
                    fi

                    # Set its resolution
                    outputResolution="import"

                    # Now add the file to our database
                    ytIdToDb "${ytId}" "import" "${f}"
                done
            fi

            # Find audio files to import
            readarray -t importArrAudio < <(find "${dir}" -type f -regextype egrep -regex "^.*\[([A-Za-z0-9_-]{11})\]\.(mp3|opus)")
            if [[ "${#importArrAudio[@]}" -ne "0" ]]; then
                printOutput "3" "Found [${#importArrAudio[@]}] audio files to import"
                # Set some default global variables for these imported files
                markWatched="0"
                includeShorts="1"
                includeLiveBroadcasts="1"
                sponsorblockEnable="disable"
                sponsorblockRequire="0"
                n="1"
                for f in "${importArrAudio[@]}"; do
                    ytId="${f%\]\.mp3}"
                    ytId="${f%\]\.opus}"
                    ytId="${ytId##*\[}"
                    printOutput "4" "Processing file ID [${ytId}] [Item ${n} of ${#importArrAudio[@]}]"
                    (( n++ ))

                    # If it's already in the database, we can skip it
                    dbCount="$(sqDb "SELECT COUNT(1) FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
                    if [[ "${dbCount}" -eq "0" ]]; then
                        # Safety check
                        printOutput "5" "File ID [${ytId}] not present in database"
                    elif [[ "${dbCount}" -eq "1" ]]; then
                        # Safety check
                        printOutput "5" "File ID [${ytId}] already present in database"
                    else
                        badExit "133" "Unexpected count returned [${dbCount}] for file ID [${ytId}] -- Possible database corruption"
                    fi

                    # Now add the file to our database
                    ytIdToDb "${ytId}" "importaudio" "${f}"
                done
            fi
        fi
    done
fi

if [[ "${skipSource}" -eq "0" ]]; then
    printOutput "3" "${colorBlue}############### Processing media sources ##############${colorReset}"
    # TODO: Add per-source 'limit' option
    readarray -t sources < <(find "${realPath%/*}/${scriptName%.bash}.sources/" -type f -name "*.env" | sort -n -k1,1)
    n="1"
    for source in "${sources[@]}"; do
        startTime="$(($(date +%s%N)/1000000))"
        # Unset some variables we need to be able to be blank
        unset videoArr sponsorArr configArr itemType channelId plId ytId
        declare -A videoArr sponsorArr configArr
        # Unset some variables from the previous source
        unset sourceUrl outputResolution markWatched includeShorts includeLiveBroadcasts subLanguages videoEnableSB videoRequireSB videoCategorySB outputAudio audioEnableSB audioRequireSB audioCategorySB
        printOutput "3" "Processing source: ${source##*/} [Item ${n} of ${#sources[@]}]"
        (( n++ ))
        source "${source}"
        sourceHash="$(md5sum "${source}")"
        sourceHash="${sourceHash%% *}"
        oldHash="$(sqDb "SELECT HASH FROM hash WHERE FILE = '${source//\'/\'\'}';")"
        if [[ "${oldHash}" == "${sourceHash}" ]]; then
            printOutput "5" "No changes detected in config options since last run, skipping config update for found file ID's"
            updateConfig="0"
        else
            printOutput "4" "Changes detected in config since last run, updating config option for found file ID's"
            updateConfig="1"
        fi

        printOutput "4" "Validating source config"
        # Verify source config options
        if [[ -z "${sourceUrl}" ]]; then
            printOutput "1" "No source URL provided in source file [${source}] -- Skipping"
            continue
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
        if ! [[ "${reversePlaylist,,}" == "true" ]]; then
            reversePlaylist="0"
        else
            reversePlaylist="1"
        fi
        printOutput "5" "Reverse playlist [${reversePlaylist}]"

        # Mark as watched on import?
        if ! [[ "${markWatched,,}" == "true" ]]; then
            markWatched="0"
        else
            markWatched="1"
        fi
        printOutput "5" "Mark as watched on import [${markWatched}]"

        # Include shorts?
        if ! [[ "${includeShorts,,}" == "true" ]]; then
            includeShorts="0"
        else
            includeShorts="1"
        fi
        printOutput "5" "Include shorts [${includeShorts}]"

        # Include live broadcasts?
        if ! [[ "${includeLiveBroadcasts,,}" == "true" ]]; then
            includeLiveBroadcasts="0"
        else
            includeLiveBroadcasts="1"
        fi
        printOutput "5" "Include live broadcasts [${includeLiveBroadcasts}]"

        # Desired subtitle languages?
        for lang in "${!subLanguages[@]}"; do
            if checkSubs "${subLanguages[${lang}]}"; then
                printOutput "5" "Validated language code [${subLanguages[${lang}]}]"
            else
                printOutput "1" "Failed to validate language code [${subLanguages[${lang}]}] -- Ignoring"
                unset subLanguages["${lang}"]
            fi
        done
        printOutput "5" "Desired subtitles [${subLanguages[*]}]"

        # Enable SponsorBlock?
        if ! [[ "${videoEnableSB,,}" =~ ^(mark|remove)$ ]]; then
            videoEnableSB="disable"
        else
            videoEnableSB="${videoEnableSB,,}"
        fi
        printOutput "5" "Enable Video SponsorBlock [${videoEnableSB}]"

        # If enabled, require SponsorBlock?
        if [[ "${videoEnableSB,,}" =~ ^(mark|remove)$ ]]; then
            if [[ "${videoRequireSB,,}" =~ ^(true|false)$ ]]; then
                if ! [[ "${videoRequireSB,,}" == "true" ]]; then
                    videoRequireSB="0"
                else
                    videoRequireSB="1"
                fi
            fi
            printOutput "5" "Video require SponsorBlock [${videoRequireSB}]"
        fi

        # If enabled, what flags for SponsorBlock?
        if [[ "${videoEnableSB,,}" =~ ^(mark|remove)$ ]]; then
            if [[ "${videoEnableSB,,}" == "mark" ]]; then
                validFlags=("sponsor" "intro" "outro" "selfpromo" "preview" "filler" "interaction" "music_offtopic" "poi_highlight" "chapter")
            elif [[ "${videoEnableSB,,}" == "remove" ]]; then
                validFlags=("sponsor" "intro" "outro" "selfpromo" "preview" "filler" "interaction" "music_offtopic")
            fi
            # Validation and removal logic for videoCategorySB
            if [[ "${videoCategorySB}" != "all" ]]; then
            IFS=',' read -ra categories <<< "${videoCategorySB}"
            validCategories=()
            badCategories=()

            for category in "${categories[@]}"; do
            category_trimmed="${category#"${category%%[![:space:]]*}"}" # Trim leading whitespace
            category_trimmed="${category_trimmed%"${category_trimmed##*[![:space:]]}"}" # Trim trailing whitespace

            isValidCategory="false"
            for validFlag in "${validFlags[@]}"; do
                if [[ "${category_trimmed}" == "${validFlag}" ]]; then
                    isValidCategory="true"
                    break
                fi
            done

            if "${isValidCategory}"; then
                validCategories+=("${category_trimmed}")
            else
                badCategories+=("${category_trimmed}")
                printOutput "2" "Invalid SponsorBlock category [${category_trimmed}]"
            fi
            done

            # Update videoCategorySB with only valid categories
            if [[ "${#validCategories[@]}" -gt 0 ]]; then
                IFS=','
                videoCategorySB="${validCategories[*]}"
                unset IFS
                printOutput "3" "Updated videoCategorySB to [${videoCategorySB}]"
            else
                # If no valid categories remain, set it to the default 'all'
                videoCategorySB="all"
                printOutput "2" "No valid categories found. Setting videoCategorySB to default [all]"
                fi

                # Optionally, you can still print a message if all were bad initially
                if [[ "${#badCategories[@]}" -gt 0 ]] && [[ "${videoCategorySB}" == "all" ]]; then
                    printOutput "3" "All specified categories were invalid, using default [all]"
                fi
            fi

            printOutput "5" "Video SponsorBlock category flags [${videoCategorySB}]"
        fi

        if [[ "${outputAudio,,}" == "opus" ]]; then
            outputAudio="opus"
        elif [[ "${outputAudio,,}" == "mp3" ]]; then
            outputAudio="mp3"
        else
            unset outputAudio
        fi
        printOutput "5" "Output audio [${outputAudio}]"

        # Enable SponsorBlock?
        if ! [[ "${audioEnableSB,,}" == "remove" ]]; then
            audioEnableSB="disable"
        else
            audioEnableSB="remove"
        fi
        printOutput "5" "Enable Audio SponsorBlock [${audioEnableSB}]"

        # If enabled, require SponsorBlock?
        if [[ "${audioEnableSB,,}" == "remove" ]]; then
            if [[ "${audioRequireSB,,}" =~ ^(true|false)$ ]]; then
                if ! [[ "${audioRequireSB,,}" == "true" ]]; then
                    audioRequireSB="0"
                else
                    audioRequireSB="1"
                fi
            fi
            printOutput "5" "Audio require SponsorBlock [${audioRequireSB}]"
        fi

        # If enabled, what flags for SponsorBlock?
        if [[ "${audioEnableSB,,}" == "remove" ]]; then
            validFlags=("sponsor" "intro" "outro" "selfpromo" "preview" "filler" "interaction" "music_offtopic")
            # Validation and removal logic for audioCategorySB
            if [[ "${audioCategorySB}" != "all" ]]; then
            IFS=',' read -ra categories <<< "${audioCategorySB}"
            validCategories=()
            badCategories=()

            for category in "${categories[@]}"; do
            category_trimmed="${category#"${category%%[![:space:]]*}"}" # Trim leading whitespace
            category_trimmed="${category_trimmed%"${category_trimmed##*[![:space:]]}"}" # Trim trailing whitespace

            isValidCategory="false"
            for validFlag in "${validFlags[@]}"; do
                if [[ "${category_trimmed}" == "${validFlag}" ]]; then
                    isValidCategory="true"
                    break
                fi
            done

            if "${isValidCategory}"; then
                validCategories+=("${category_trimmed}")
            else
                badCategories+=("${category_trimmed}")
                printOutput "2" "Invalid SponsorBlock category [${category_trimmed}]"
            fi
            done

            # Update audioCategorySB with only valid categories
            if [[ "${#validCategories[@]}" -gt 0 ]]; then
                IFS=','
                audioCategorySB="${validCategories[*]}"
                unset IFS
                printOutput "3" "Updated audioCategorySB to [${audioCategorySB}]"
            else
                # If no valid categories remain, set it to the default 'all'
                audioCategorySB="all"
                printOutput "2" "No valid categories found. Setting audioCategorySB to default [all]"
                fi

                # Optionally, you can still print a message if all were bad initially
                if [[ "${#badCategories[@]}" -gt 0 ]] && [[ "${audioCategorySB}" == "all" ]]; then
                    printOutput "3" "All specified categories were invalid, using default [all]"
                fi
            fi

            printOutput "5" "Audio SponsorBlock category flags [${audioCategorySB}]"
        fi

        # Config validated
        # Parse the source URL
        printOutput "4" "Parsing source URL [${sourceUrl}]"
        id="${sourceUrl#http:\/\/}"
        id="${id#https:\/\/}"
        id="${id#m\.}"
        id="${id#www\.}"
        if [[ "${id:0:8}" == "youtu.be" ]]; then
            # I think these short URL's can only be a file ID?
            itemType="video"
            ytId="${id:9:11}"
            printOutput "4" "Found file ID [${ytId}]"
        elif [[ "${id:12:6}" == "shorts" ]]; then
            # This is a file ID for a short
            itemType="video"
            ytId="${id:19:11}"
            printOutput "4" "Found short file ID [${ytId}]"
        elif [[ "${id:0:8}" == "youtube." ]]; then
            # This can be a file ID (video, live, or short), a channel ID, a channel name, or a playlist
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
                        badExit "134" "Impossible condition"
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
                # It's a file ID
                itemType="video"
                ytId="${id:20:11}"
                printOutput "4" "Found file ID [${ytId}]"
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
                printOutput "4" "Found playlist ID [${plId}]"
            fi
        else
            printOutput "1" "Unable to parse input [${id}] -- skipping"
            continue
        fi

        if [[ "${itemType}" == "video" ]]; then
            # Add it to our array of videos to index
            # Using the keys of an associative array prevents any element from being added multiple times
            # The array element must be padded with an underscore, or it can be misinterpreted as an integer
            # Make sure we update the config
            configArr["_${i}"]="true"
            # Only process the video if it's not accounted for
            dbReply="$(sqDb "SELECT COUNT(1) FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            if [[ "${dbReply}" -eq "0" ]]; then
                printOutput "4" "Queueing file ID [${ytId}] for database addition"
                videoArr["_${ytId}"]="true"
            elif [[ "${dbReply}" -eq "1" ]]; then
                # Do we need to download the audio?
                if [[ -n "${outputAudio}" ]]; then
                    vidType="$(sqDb "SELECT TYPE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
                    audStatus="$(sqDb "SELECT AUDIO_STATUS FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
                    if [[ "${vidType}" == "video" ]] && [[ ! "${audStatus}" =~ ^(downloaded|queued)$ ]]; then
                        # It's a normal video, and we haven't downloaded the audio, queue it
                        videoArr["_${ytId}"]="true"
                    fi
                fi
                # Do we need to replace it based on sponsorblock availability?
                if ! [[ "${sponsorblockEnable}" -eq "0" ]]; then
                    # SponsorBlock is enabled, see if we should upgrade
                    if [[ "${sponsorblockRequire}" == "0" ]]; then
                        # Yes, we may need to upgrade
                        # See if we've already pulled the data for the video
                        sponsorblockAvailable="$(sqDb "SELECT SPONSORBLOCK_AVAILABLE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
                        if [[ "${sponsorblockAvailable%% \[*}" == "Found" ]]; then
                            # We can skip it
                            printOutput "5" "Skipping file ID [${i}] as SponsorBlock criteria already met"
                            continue
                        else
                            # It's not found, add the video to the queue
                            printOutput "4" "Queueing file ID [${ytId}] to check for SponsorBlock availability"
                            sponsorArr["_${ytId}"]="true"
                        fi
                    fi
                fi
            else
                badExit "135" "Counted [${dbReply}] rows with file ID [${ytId}] -- Possible database corruption"
            fi
        elif [[ "${itemType}" == "channel" ]]; then
            # We should use ${channelId} for the channel ID rather than ${ytId} which could be the handle
            # Get a list of the videos for the channel
            printOutput "3" "Getting video list for channel ID [${channelId}]"
            unset chanVidList
            if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
                while read -r ytId; do
                    if [[ "${ytId}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
                        chanVidList+=("${ytId}")
                    else
                        printOutput "1" "File ID [${ytId}] failed to pass regex validation -- Skipping"
                    fi
                done < <(yt-dlp --flat-playlist --playlist-reverse --no-warnings --cookies "${cookieFile}" --print "%(id)s" "https://www.youtube.com/channel/${channelId}" 2>&1)
            else
                while read -r ytId; do
                    if [[ "${ytId}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
                        chanVidList+=("${ytId}")
                    else
                        printOutput "1" "File ID [${ytId}] failed to pass regex validation -- Skipping"
                    fi
                done < <(yt-dlp --flat-playlist --playlist-reverse --no-warnings --print "%(id)s" "https://www.youtube.com/channel/${channelId}" 2>&1)
            fi

            printOutput "4" "Pulled list of [${#chanVidList[@]}] videos from channel"

            for i in "${chanVidList[@]}"; do
                # Make sure we update the config
                configArr["_${i}"]="true"

                # Only process the video if it's not accounted for
                dbReply="$(sqDb "SELECT COUNT(1) FROM media WHERE FILE_ID = '${i//\'/\'\'}';")"
                if [[ "${dbReply}" -eq "0" ]]; then
                    printOutput "4" "Queueing file ID [${i}] for database addition"
                    videoArr["_${i}"]="true"
                elif [[ "${dbReply}" -eq "1" ]]; then
                    # Do we need to download the audio?
                    if [[ -n "${outputAudio}" ]]; then
                        vidType="$(sqDb "SELECT TYPE FROM media WHERE FILE_ID = '${i//\'/\'\'}';")"
                        audStatus="$(sqDb "SELECT AUDIO_STATUS FROM media WHERE FILE_ID = '${i//\'/\'\'}';")"
                        if [[ "${vidType}" == "video" ]] && [[ ! "${audStatus}" =~ ^(downloaded|queued)$ ]]; then
                            # It's a normal video, and we haven't downloaded the audio, queue it
                            videoArr["_${i}"]="true"
                        fi
                    fi
                    # Do we need to replace it based on sponsorblock availability?
                    if ! [[ "${sponsorblockEnable}" -eq "0" ]]; then
                        # SponsorBlock is enabled, see if we should upgrade
                        if [[ "${sponsorblockRequire}" == "0" ]]; then
                            # Yes, we may need to upgrade
                            # See if we've already pulled the data for the video
                            sponsorblockAvailable="$(sqDb "SELECT SPONSORBLOCK_AVAILABLE FROM media WHERE FILE_ID = '${i//\'/\'\'}';")"
                            if [[ "${sponsorblockAvailable%% \[*}" == "Found" ]]; then
                                # We can skip it
                                printOutput "5" "Skipping file ID [${i}] as SponsorBlock criteria already met"
                                continue
                            else
                                # It's not found, add the video to the queue
                                printOutput "4" "Queueing file ID [${i}] to check for SponsorBlock availability"
                                sponsorArr["_${i}"]="true"
                            fi
                        fi
                    fi
                else
                    badExit "136" "Counted [${dbReply}] rows with file ID [${i}] -- Possible database corruption"
                fi
            done
        elif [[ "${itemType}" == "playlist" ]]; then
            printOutput "3" "Processing playlist ID [${plId}]"
            
            if [[ "${reversePlaylist}" -eq "1" ]]; then
                plOpt="--playlist-reverse"
            else
                unset plOpt
            fi
            if [[ -n "${cookieFile}" && -e "${cookieFile}" ]]; then
                cookieOpt="--cookies "${cookieFile}""
            else
                unset cookieOpt
            fi

            # Get a list of videos in the playlist -- Easier/faster to do this via yt-dlp than API
            unset plVidList
            while read -r ytId; do
                if [[ "${ytId}" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
                    for idChk in "${plVidList[@]}"; do
                        if [[ "${ytId}" == "${idChk}" ]]; then
                            # We've already grabbed this file ID
                            printOutput "5" "File ID [${ytId}] already appears in playlist ID [${plId}] -- Skipping duplicate entry"
                            continue 2
                        fi
                    done
                    plVidList+=("${ytId}")
                else
                    printOutput "1" "File ID [${ytId}] failed to pass regex validation -- Skipping"
                fi
            done < <(yt-dlp ${plOpt} ${cookieOpt} --flat-playlist --no-warnings --print "%(id)s" "https://www.youtube.com/playlist?list=${plId}" 2>&1)

            if [[ "${#plVidList[@]}" -eq "0" ]]; then
                printOutput "1" "Pulled [0] videos from playlist [https://www.youtube.com/playlist?list=${plId}] -- Is the URL valid and does the playlist contain videos? If so, is any necessary cookie file valid and not expired?"
                continue
            fi

            printOutput "4" "Pulled list of [${#plVidList[@]}] videos from playlist"

            # Is the playlist already in our database?
            dbReply="$(sqDb "SELECT COUNT(1) FROM playlist WHERE PLAYLIST_ID = '${plId}';")"
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
                    dbCount="$(sqDb "SELECT COUNT(1) FROM playlist_order WHERE FILE_ID = '${ytId//\'/\'\'}' AND PLAYLIST_ID = '${plId//\'/\'\'}';")"
                    if [[ "${dbCount}" -ne "0" ]]; then
                        printOutput "5" "File ID [${ytId}] already appears in playlist ID [${plId}] -- Skipping duplicate entry"
                        continue
                    fi
                    (( plPos++ ))
                    # Add it to the database
                    # Insert what we have
                    if sqDb "INSERT INTO playlist_order (FILE_ID, PLAYLIST_ID, PLAYLIST_INDEX, CREATED, UPDATED) VALUES ('${ytId//\'/\'\'}', '${plId//\'/\'\'}', ${plPos}, '$(date)', '$(date)');"; then
                        printOutput "3" "Added file ID [${ytId}] in position [${plPos}] for playlist ID [${plId}] to database"
                    else
                        badExit "137" "Failed to add file ID [${ytId}] in position [${plPos}] for playlist ID [${plId}] to database"
                    fi
                done
            elif [[ "${dbReply}" -eq "1" ]]; then
                # It already exists in the database
                # Get a list of videos in the database for this playlist (in order)
                readarray -t dbVidList < <(sqDb "SELECT FILE_ID FROM playlist_order WHERE PLAYLIST_ID = '${plId//\'/\'\'}' ORDER BY PLAYLIST_INDEX ASC;")

                # Start by comparing the number of items in each array
                if [[ "${#plVidList[@]}" -ne "${#dbVidList[@]}" ]]; then
                    # Item count mismatch.
                    # Make a note that we need to update this playlist in Plex
                    updatePlaylist["_${plId}"]="true"
                    # Dump the DB playlist info and re-add it.
                    printOutput "5" "Playlist item count [${#plVidList[@]}] does not match database item count [${#dbVidList[@]}]"
                    if sqDb "DELETE FROM playlist_order WHERE PLAYLIST_ID = '${plId//\'/\'\'}';"; then
                        printOutput "5" "Removed playlist order due to item count mismatch for playlist ID [${plId}] from database"
                    else
                        badExit "138" "Failed to remove playlist order for playlist ID [${plId}] from database"
                    fi
                    # Add the order of items in the playlist_order table
                    plPos="0"
                    for ytId in "${plVidList[@]}"; do
                        (( plPos++ ))
                        # Add it to the database
                        # Insert what we have
                        if sqDb "INSERT INTO playlist_order (FILE_ID, PLAYLIST_ID, PLAYLIST_INDEX, CREATED, UPDATED) VALUES ('${ytId}', '${plId//\'/\'\'}', ${plPos}, '$(date)', '$(date)');"; then
                            printOutput "5" "Added file ID [${ytId}] in position [${plPos}] for playlist ID [${plId}] to database"
                        else
                            badExit "139" "Failed to add file ID [${ytId}] in position [${plPos}] for playlist ID [${plId}] to database"
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
                            printOutput "5" "Playlist key [${key}] with file ID [${plVidList[${key}]}] does not match database file ID [${dbVidList[${key}]}]"
                            if sqDb "DELETE FROM playlist_order WHERE PLAYLIST_ID = '${plId//\'/\'\'}';"; then
                                printOutput "5" "Removed playlist order due to order mismatch for playlist ID [${plId}] from database"
                            else
                                badExit "140" "Failed to remove playlist order for playlist ID [${plId}] from database"
                            fi
                            # Add the order of items in the playlist_order table
                            plPos="0"
                            for ytId in "${plVidList[@]}"; do
                                (( plPos++ ))
                                # Add it to the database
                                # Insert what we have
                                if sqDb "INSERT INTO playlist_order (FILE_ID, PLAYLIST_ID, PLAYLIST_INDEX, CREATED, UPDATED) VALUES ('${ytId}', '${plId//\'/\'\'}', ${plPos}, '$(date)', '$(date)');"; then
                                    printOutput "3" "Updated file ID [${ytId}] in position [${plPos}] for playlist ID [${plId}] to database"
                                else
                                    badExit "141" "Failed to add file ID [${ytId}] in position [${plPos}] for playlist ID [${plId}] to database"
                                fi
                            done
                            # We can break the loop, as we've just re-done the whole entry
                            break
                        fi
                    done
                fi
            elif [[ "${dbReply}" -ge "2" ]]; then
                badExit "142" "Database query returned [${dbReply}] results -- Possible database corruption"
            else
                badExit "143" "Impossible condition"
            fi

            for i in "${plVidList[@]}"; do
                # Make sure we update the config
                configArr["_${i}"]="true"
                # Only process the video if it's not accounted for
                dbReply="$(sqDb "SELECT COUNT(1) FROM media WHERE FILE_ID = '${i//\'/\'\'}';")"
                if [[ "${dbReply}" -eq "0" ]]; then
                    printOutput "4" "Queueing file ID [${i}] for database addition"
                    videoArr["_${i}"]="true"
                elif [[ "${dbReply}" -eq "1" ]]; then
                    # Do we need to download the audio?
                    if [[ -n "${outputAudio}" ]]; then
                        vidType="$(sqDb "SELECT TYPE FROM media WHERE FILE_ID = '${i//\'/\'\'}';")"
                        audStatus="$(sqDb "SELECT AUDIO_STATUS FROM media WHERE FILE_ID = '${i//\'/\'\'}';")"
                        if [[ "${vidType}" == "video" ]] && [[ ! "${audStatus}" =~ ^(downloaded|queued)$ ]]; then
                            # It's a normal video, and we haven't downloaded the audio, queue it
                            videoArr["_${i}"]="true"
                        fi
                    fi
                    # Do we need to replace it based on sponsorblock availability?
                    if ! [[ "${sponsorblockEnable}" -eq "0" ]]; then
                        # SponsorBlock is enabled, see if we should upgrade
                        if [[ "${sponsorblockRequire}" == "0" ]]; then
                            # Yes, we may need to upgrade
                            # See if we've already pulled the data for the video
                            sponsorblockAvailable="$(sqDb "SELECT SPONSORBLOCK_AVAILABLE FROM media WHERE FILE_ID = '${i//\'/\'\'}';")"
                            if [[ "${sponsorblockAvailable%% \[*}" == "Found" ]]; then
                                # We can skip it
                                printOutput "5" "Skipping file ID [${i}] as SponsorBlock criteria already met"
                                continue
                            else
                                # It's not found, add the video to the queue
                                printOutput "4" "Queueing file ID [${i}] to check for SponsorBlock availability"
                                sponsorArr["_${i}"]="true"
                            fi
                        fi
                    fi
                else
                    badExit "144" "Counted [${dbReply}] rows with file ID [${i}] -- Possible database corruption"
                fi
            done
        fi

        if [[ "${updateConfig}" -eq "1" ]]; then
            if [[ "${#configArr[@]}" -ne "0" ]]; then
                printOutput "3" "Updating [${#configArr[@]}] source item configurations"
                # Get our row ID
                configId="$(sqDb "SELECT INT_ID FROM hash WHERE FILE = '${source//\'/\'\'}';")"
                if [[ -z "${configId}" ]]; then
                    # Row doesn't exist, initiate one
                    if ! sqDb "INSERT INTO hash (FILE, HASH, CREATED, UPDATED) VALUES ('${source//\'/\'\'}', '${sourceHash//\'/\'\'}', '$(date)', '$(date)');"; then
                        badExit "145" "Failed to initiate row for config [${source}] in database"
                    else
                        printOutput "5" "Successfully initiated row for config [${source}] in database"
                    fi
                else
                    # Row exists, update it
                    if ! sqDb "UPDATE hash SET HASH = '${sourceHash//\'/\'\'}', UPDATED = '$(date)' WHERE INT_ID = ${configId};"; then
                        badExit "146" "Failed to update row for config [${source}] in database"
                    else
                        printOutput "5" "Successfully updated row for config [${source}] in database"
                    fi
                fi
                nn="1"
                for ytId in "${!configArr[@]}"; do
                    ytId="${ytId#_}"
                    printOutput "4" "Processing file ID for config changes [${ytId}] [Item ${nn} of ${#configArr[@]}]"
                    if ! updateConfig "${ytId}"; then
                        printOutput "1" "Failed to update configuration for file ID [${ytId}]"
                    fi
                    (( nn++ ))
                done
            fi
        elif [[ "${updateConfig}" -eq "0" ]]; then
            if [[ "${#videoArr[@]}" -ne "0" ]]; then
                # We should do a config update for each video in videoArr
                printOutput "3" "Updating [${#videoArr[@]}] video item configurations"
                # Get our row ID
                configId="$(sqDb "SELECT INT_ID FROM hash WHERE FILE = '${source//\'/\'\'}';")"
                printOutput "5" "Isolated config ID [${configId}]"
                if [[ -z "${configId}" ]]; then
                    # Row doesn't exist, initiate one
                    if ! sqDb "INSERT INTO hash (FILE, HASH, CREATED, UPDATED) VALUES ('${source//\'/\'\'}', '${sourceHash//\'/\'\'}', '$(date)', '$(date)');"; then
                        badExit "147" "Failed to initiate row for config [${source}] in database"
                    else
                        printOutput "5" "Successfully initiated row for config [${source}] in database"
                    fi
                else
                    # Row exists, update it
                    if ! sqDb "UPDATE hash SET HASH = '${sourceHash//\'/\'\'}', UPDATED = '$(date)' WHERE INT_ID = ${configId};"; then
                        badExit "148" "Failed to update row for config [${source}] in database"
                    else
                        printOutput "5" "Successfully updated row for config [${source}] in database"
                    fi
                fi
                nn="1"
                for ytId in "${!videoArr[@]}"; do
                    ytId="${ytId#_}"
                    printOutput "4" "Processing file ID for config changes [${ytId}] [Item ${nn} of ${#videoArr[@]}]"
                    if ! updateConfig "${ytId}"; then
                        printOutput "1" "Failed to update configuration for file ID [${ytId}]"
                    fi
                    (( nn++ ))
                done
            fi
        fi

        if [[ "${#videoArr[@]}" -ne "0" ]]; then
            printOutput "3" "Processing videos"
            # Iterate through our video list
            printOutput "3" "Found [${#videoArr[@]}] file ID's to be processed into database"
            nn="1"
            for ytId in "${!videoArr[@]}"; do
                ytId="${ytId#_}"
                printOutput "4" "Processing file ID in to database [${ytId}] [Item ${nn} of ${#videoArr[@]}]"
                if ! ytIdToDb "${ytId}"; then
                    printOutput "1" "Failed to add file ID [${ytId}] from source [${source##*/}] to database"
                fi
                if [[ "${markWatched}" == "1" && -z "${watchedArr[_${ytId}]}" ]]; then
                    printOutput "4" "Noting file ID [${ytId}] to be marked as 'Watched'"
                    watchedArr["_${ytId}"]="watched"
                fi
                (( nn++ ))
            done
        fi

        if [[ "${#sponsorArr[@]}" -ne "0" ]]; then
            printOutput "3" "Processing videos"
            # Iterate through our video list
            printOutput "3" "Found [${#sponsorArr[@]}] file ID's to be check for SponsorBlock availability"
            nn="1"
            for ytId in "${!sponsorArr[@]}"; do
                ytId="${ytId#_}"
                printOutput "4" "Processing file ID for updated SponsorBlock data [${ytId}] [Item ${nn} of ${#sponsorArr[@]}]"
                if ! updateSponsorBlock "${ytId}"; then
                    printOutput "1" "Failed to check file ID [${1}] for SponsorBlock availability"
                fi
                (( nn++ ))
            done
        fi

        printOutput "4" "Source successfully processed [Took $(timeDiff "${startTime}")]"
    done

    # Deal with skipped videos, as a part of sourcing
    readarray -t skippedVids < <(sqDb "SELECT FILE_ID FROM media WHERE VIDEO_STATUS = 'waiting';")
    if [[ "${#skippedVids[@]}" -ne "0" ]]; then
        printOutput "3" "${colorBlue}########### Checking previously live videos ###########${colorReset}"
        # Update their status in the database
        loopNum="0"
        for ytId in "${skippedVids[@]}"; do
            (( loopNum++ ))
            printOutput "3" "Updating metadata for file ID [${ytId}] [Item ${loopNum} of ${#skippedVids[@]}]"

            # We need the existing global variables for this video
            # We have the video format option
            outputResolution="$(sqDb "SELECT VIDEO_RESOLUTION FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            # We have the include shorts option
            includeShorts="$(sqDb "SELECT ALLOW_SHORTS FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            # We have the include live option
            includeLiveBroadcasts="$(sqDb "SELECT ALLOW_LIVE FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            # We have the mark watched option
            markWatched="$(sqDb "SELECT MARK_WATCHED FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            # We have the sponsor block enable option
            sponsorblockEnable="$(sqDb "SELECT SPONSORBLOCK_ENABLED_VIDEO FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            # We have the sponsor block require option
            sponsorblockRequire="$(sqDb "SELECT SPONSORBLOCK_REQUIRED_VIDEO FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"

            # Go ahead and update the database entry
            ytIdToDb "${ytId}"
        done
    fi
fi

if [[ "${#reindexArr[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}############## Updating re-indexed files ##############${colorReset}"
    for ytId in "${!reindexArr[@]}"; do
        ytId="${ytId#_}"
        channelId="$(sqDb "SELECT CHANNEL_ID FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        channelPath="$(sqDb "SELECT PATH FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
        channelNameClean="$(sqDb "SELECT NAME_SAFE FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
        vidYear="$(sqDb "SELECT UPLOAD_YEAR FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        vidIndex="$(sqDb "SELECT YEAR_INDEX FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        vidTitleClean="$(sqDb "SELECT TITLE_SAFE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # Move the old file to the new destination
        if ! mv "${reindexArr[_${ytId}]}" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4"; then
            printOutput "1" "Failed to move file ID [${ytId}] from [${reindexArr[_${ytId}]}] to [${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4]"
        fi
        if [[ -e "${reindexArr[_${ytId}]%mp4}jpg" ]]; then
            if ! mv "${reindexArr[_${ytId}]%mp4}jpg" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"; then
                printOutput "1" "Failed to move thumbnail for file ID [${ytId}] from [${reindexArr[_${ytId}]%mp4}jpg] to [${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg]"
            fi
        fi
        printOutput "3" "Successfully re-indexed file ID [${ytId}]"
    done
fi

readarray -t importArrVideo < <(sqDb "SELECT FILE_ID FROM media WHERE VIDEO_STATUS = 'import';")
if [[ "${#importArrVideo[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}################ Importing video files ################${colorReset}"
    n="1"
    for ytId in "${importArrVideo[@]}"; do
        printOutput "3" "Processing file ID [${ytId}] [Item ${n} of ${#importArrVideo[@]}]"
        (( n++ ))
        # Get the file origin location
        moveFrom="$(sqDb "SELECT VIDEO_ERROR FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # Make sure the file origin actually exists
        if ! [[ -e "${moveFrom}" ]]; then
            printOutput "1" "Import file [${moveFrom}] does not appear to exist -- Skipping"
            continue
        fi

        # Build our move-to path
        channelId="$(sqDb "SELECT CHANNEL_ID FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${channelId}" ]]; then
            badExit "149" "Unable to determine channel ID for file ID [${ytId}] -- Possible database corruption"
        fi
        channelPath="$(sqDb "SELECT PATH FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
        if [[ -z "${channelPath}" ]]; then
            badExit "150" "Unable to determine channel path for file ID [${ytId}] -- Possible database corruption"
        fi
        channelName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
        if [[ -z "${channelName}" ]]; then
            badExit "151" "Unable to determine channel name for file ID [${ytId}] -- Possible database corruption"
        fi
        channelNameClean="$(sqDb "SELECT NAME_SAFE FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
        if [[ -z "${channelNameClean}" ]]; then
            badExit "152" "Unable to determine clean channel name for file ID [${ytId}] -- Possible database corruption"
        fi
        vidYear="$(sqDb "SELECT UPLOAD_YEAR FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidYear}" ]]; then
            badExit "153" "Unable to determine video year for file ID [${ytId}] -- Possible database corruption"
        fi
        vidIndex="$(sqDb "SELECT YEAR_INDEX FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidIndex}" ]]; then
            badExit "154" "Unable to determine video index for file ID [${ytId}] -- Possible database corruption"
        fi
        vidTitle="$(sqDb "SELECT TITLE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidTitle}" ]]; then
            badExit "155" "Unable to determine video title for file ID [${ytId}] -- Possible database corruption"
        fi
        vidTitleClean="$(sqDb "SELECT TITLE_SAFE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        if [[ -z "${vidTitleClean}" ]]; then
            badExit "156" "Unable to determine clean video title for file ID [${ytId}] -- Possible database corruption"
        fi

        # We've got all the things we need, now make sure the destination folder(s) we need exist.
        # Check if the base channel directory exists
        if ! [[ -d "${outputDir}/${channelPath}" ]]; then
            # Create it
            if ! mkdir -p "${outputDir}/${channelPath}"; then
                badExit "157" "Unable to create directory [${outputDir}/${channelPath}]"
            fi
            newVideoDir+=("${channelId}")

            # Create the series image
            makeShowImage "${channelId}"
        fi

        if ! [[ -d "${outputDir}/${channelPath}/Season ${vidYear}" ]]; then
            # Create the season directory
            if ! mkdir -p "${outputDir}/${channelPath}/Season ${vidYear}"; then
                badExit "158" "Unable to create season directory [${outputDir}/${channelPath}/Season ${vidYear}"
            fi

            # Create the season image
            makeShowImage "${channelId}" "${vidYear}"
        fi

        # Move our imported file
        if ! mv "${moveFrom}" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4"; then
            printOutput "1" "Failed to move file ID [${ytId}] from tmp dir [${tmpDir}] to destination [${channelPath}/Season ${vidYear}]"
            vidStatus="import_failed"
        else
            vidStatus="downloaded"
        fi

        # If we have a thumbnail
        if [[ -e "${moveFrom%mp4}jpg" ]]; then
            # Move it
            if ! mv "${moveFrom%mp4}jpg" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"; then
                printOutput "1" "Failed to move thumbnail for file ID [${ytId}] from tmp dir [${tmpDir}] to destination [${channelPath}/Season ${vidYear}]"
            fi
        fi
        if ! [[ -e "${moveFrom%mp4}jpg" ]]; then
            # Still don't have one, so get it from web
            printOutput "5" "Pulling thumbail from web"
            thumbUrl="$(sqDb "SELECT THUMBNAIL_URL FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            callCurlDownload "${thumbUrl}" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"
            if ! [[ -e "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg" ]]; then
                printOutput "1" "Failed to get thumbnail for file ID [${ytId}]"
            fi
        fi

        if [[ -e "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4" ]]; then
            printOutput "3" "Imported video [${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}]"
            if ! sqDb "UPDATE media SET VIDEO_STATUS = '${vidStatus}', VIDEO_ERROR = NULL, UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                badExit "159" "Unable to update status to [${vidStatus}] for file ID [${ytId}]"
            fi
        else
            printOutput "1" "Failed to import [${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}]"
            if ! sqDb "UPDATE media SET VIDEO_STATUS = '${vidStatus}', UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                badExit "160" "Unable to update status to [${vidStatus}] for file ID [${ytId}]"
            fi
        fi
    done
fi

if [[ "${allowAudio}" -eq "1" ]]; then
    readarray -t importArrAudio < <(sqDb "SELECT FILE_ID FROM media WHERE AUDIO_STATUS = 'import';")
    if [[ "${#importArrAudio[@]}" -ne "0" ]]; then
        printOutput "3" "${colorBlue}################ Importing audio files ################${colorReset}"
        n="1"
        for ytId in "${importArrAudio[@]}"; do
            printOutput "3" "Processing file ID [${ytId}] [Item ${n} of ${#importArrAudio[@]}]"
            (( n++ ))
            # Get the file origin location
            moveFrom="$(sqDb "SELECT AUDIO_ERROR FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            # Make sure the file origin actually exists
            if ! [[ -e "${moveFrom}" ]]; then
                printOutput "1" "Import file [${moveFrom}] does not appear to exist -- Skipping"
                continue
            else
                fileExt="${moveFrom##*.}"
            fi

            # Build our move-to path
            channelId="$(sqDb "SELECT CHANNEL_ID FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            if [[ -z "${channelId}" ]]; then
                badExit "161" "Unable to determine channel ID for file ID [${ytId}] -- Possible database corruption"
            fi
            channelPath="$(sqDb "SELECT PATH FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            if [[ -z "${channelPath}" ]]; then
                badExit "162" "Unable to determine channel path for file ID [${ytId}] -- Possible database corruption"
            fi
            channelName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            if [[ -z "${channelName}" ]]; then
                badExit "163" "Unable to determine channel name for file ID [${ytId}] -- Possible database corruption"
            fi
            channelNameClean="$(sqDb "SELECT NAME_SAFE FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            if [[ -z "${channelNameClean}" ]]; then
                badExit "164" "Unable to determine clean channel name for file ID [${ytId}] -- Possible database corruption"
            fi
            vidYear="$(sqDb "SELECT UPLOAD_YEAR FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            if [[ -z "${vidYear}" ]]; then
                badExit "165" "Unable to determine video year for file ID [${ytId}] -- Possible database corruption"
            fi
            vidTitle="$(sqDb "SELECT TITLE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            if [[ -z "${vidTitle}" ]]; then
                badExit "166" "Unable to determine video title for file ID [${ytId}] -- Possible database corruption"
            fi
            vidTitleClean="$(sqDb "SELECT TITLE_SAFE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            if [[ -z "${vidTitleClean}" ]]; then
                badExit "167" "Unable to determine clean video title for file ID [${ytId}] -- Possible database corruption"
            fi

            # Get the description so we can check for track splitting later
            vidDesc="$(sqDb "SELECT DESC FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"

            # Build our album path
            readarray -t albumVersion < <(sqDb "SELECT FILE_ID FROM media WHERE CHANNEL_ID = '${channelId//\'/\'\'}' AND TITLE_SAFE = '${vidTitleClean//\'/\'\'}' AND UPLOAD_YEAR = ${vidYear} ORDER BY TIMESTAMP ASC;")
            if [[ "${#albumVersion[@]}" -eq "1" ]]; then
                albumTitle="${vidTitleClean} (${vidYear}) [${ytId}]"
            else
                # Find out what version we are
                albumVersion="1"
                for localId in "${albumVersion[@]}"; do
                    if [[ "${localId}" == "${ytId}" ]]; then
                        break
                    else
                        (( albumVersion++ ))
                    fi
                done
                if [[ "${albumVersion}" -eq "1" ]]; then
                    albumTitle="${vidTitleClean} (${vidYear}) [${ytId}]"
                else
                    albumTitle="${vidTitleClean}, Version ${albumVersion} (${vidYear}) [${ytId}]"
                fi
            fi

            # We've got all the things we need, now make sure the destination folder(s) we need exist.
            # Check if the base channel directory exists
            if ! [[ -d "${outputDirAudio}/${channelPathClean}" ]]; then
                # Create it
                if ! mkdir -p "${outputDirAudio}/${channelPathClean}"; then
                    badExit "168" "Unable to create directory [${outputDirAudio}/${channelPath}]"
                fi
                newAudioDir["${channelId}"]="true"

                # Create the artist image
                makeArtistImage "${channelId}"
            fi

            # Since we're importing, the destination shouldn't exist
            if [[ -d "${outputDirAudio}/${channelPathClean}/${albumTitle}" ]]; then
                printOutput "1" "Skipping import of [${moveFrom}] due to destination [${outputDirAudio}/${channelPath}/${albumTitle}] already existing"
                continue
            else
                # Create the album directory
                if ! mkdir -p "${outputDirAudio}/${channelPathClean}/${albumTitle}"; then
                    badExit "169" "Unable to create album directory [${outputDirAudio}/${channelPath}/${albumTitle}]"
                fi
                newAlbumDir+=("${ytId}")

                # Create the album image
                # If we have a thumbnail
                if [[ -e "${moveFrom%${fileExt}}jpg" ]]; then
                    # Move it
                    if ! convert "${moveFrom%${fileExt}}jpg" -gravity center -crop "$(identify -format '%[fx:min(w,h)]x%[fx:min(w,h)]' "${moveFrom%${fileExt}}jpg")+0+0" +repage "${outputDirAudio}/${channelPathClean}/${albumTitle}/cover.jpg"; then
                        printOutput "1" "Failed to generate album cover for file ID [${ytId}] from import path [${moveFrom%${fileExt}}jpg] to destination [${channelPathClean}/${albumTitle}/cover.jpg]"
                    else
                        printOutput "5" "Generated album cover from local asset for file ID [${ytId}]"
                        rm -f "${moveFrom%${fileExt}}jpg"
                    fi
                fi
                if ! [[ -e "${outputDirAudio}/${channelPathClean}/${albumTitle}/cover.jpg" ]]; then
                    # Still don't have one, so get it from web
                    printOutput "5" "Pulling thumbail from web"
                    thumbUrl="$(sqDb "SELECT THUMBNAIL_URL FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
                    callCurlDownload "${thumbUrl}" "${tmpDir}/${ytId}.jpg"
                    if ! convert "${tmpDir}/${ytId}.jpg" -gravity center -crop "$(identify -format '%[fx:min(w,h)]x%[fx:min(w,h)]' "${tmpDir}/${ytId}.jpg")+0+0" +repage "${outputDirAudio}/${channelPathClean}/${albumTitle}/cover.jpg"; then
                        printOutput "1" "Failed to get thumbnail for file ID [${ytId}]"
                    else
                        printOutput "5" "Downloaded album cover for file ID [${ytId}]"
                        rm -f "${tmpDir}/${ytId}.jpg"
                    fi
                fi
            fi

            # Check and see if we need to split our source file into tracks
            unset trackArr
            while read -r trackLine; do
                if [[ "${trackLine}" =~ ^([0-9]{1,3}:)?[0-5]?[0-9]:[0-5][0-9]\ .* ]]; then
                    if [[ "${#trackArr[@]}" -eq "0" ]]; then
                        # Track 1
                        trackTime="0"
                    else
                        trackTime="${trackLine%% *}"
                        if [[ "${trackTime}" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
                            # Format is HH:MM:SS
                            trackHours="${trackTime%%:*}"
                            if ! [[ "${trackHours}" =~ ^[0-9]+$ ]]; then
                                badExit "170" "Track Hours for file ID [${ytId}] returned non integer [${trackHours}] from source [${trackTime}]"
                            else
                                # Trim leading zeroes so bash doesn't lose its shit
                                while [[ "${trackHours:0:1}" -eq "0" && ! "${trackHours}" == "0" ]]; do
                                    trackHours="${trackHours:1}"
                                done
                            fi
                            trackMins="${trackTime#*:}"
                            trackMins="${trackMins%:*}"
                            if ! [[ "${trackMins}" =~ ^[0-9]+$ ]]; then
                                badExit "171" "Track Minutes for file ID [${ytId}] returned non integer [${trackMins}] from source [${trackTime}]"
                            else
                                # Trim leading zeroes so bash doesn't lose its shit
                                while [[ "${trackMins:0:1}" -eq "0" && ! "${trackMins}" == "0" ]]; do
                                    trackMins="${trackMins:1}"
                                done
                            fi
                            trackSecs="${trackTime##*:}"
                            if ! [[ "${trackSecs}" =~ ^[0-9]+$ ]]; then
                                badExit "172" "Track Seconds for file ID [${ytId}] returned non integer [${trackSecs}] from source [${trackTime}]"
                            else
                                # Trim leading zeroes so bash doesn't lose its shit
                                while [[ "${trackSecs:0:1}" -eq "0" && ! "${trackSecs}" == "0" ]]; do
                                    trackSecs="${trackSecs:1}"
                                done
                            fi
                            trackTime="$(( trackHours * 3600 + trackMins * 60 + trackSecs ))"
                        elif [[ "${trackTime}" =~ ^[0-9]+:[0-9]+$ ]]; then
                            # Format is MM:SS
                            trackMins="${trackTime%:*}"
                            if ! [[ "${trackMins}" =~ ^[0-9]+$ ]]; then
                                badExit "173" "Track Minutes for file ID [${ytId}] returned non integer [${trackMins}] from source [${trackTime}]"
                            else
                                # Trim leading zeroes so bash doesn't lose its shit
                                while [[ "${trackMins:0:1}" -eq "0" && ! "${trackMins}" == "0" ]]; do
                                    trackMins="${trackMins:1}"
                                done
                            fi
                            trackSecs="${trackTime#*:}"
                            if ! [[ "${trackSecs}" =~ ^[0-9]+$ ]]; then
                                badExit "174" "Track Seconds for file ID [${ytId}] returned non integer [${trackSecs}] from source [${trackTime}]"
                            else
                                # Trim leading zeroes so bash doesn't lose its shit
                                while [[ "${trackSecs:0:1}" -eq "0" && ! "${trackSecs}" == "0" ]]; do
                                    trackSecs="${trackSecs:1}"
                                done
                            fi
                            trackTime="$(( trackMins * 60 + trackSecs ))"
                        else
                            badExit "175" "Invalid time string format [${trackLine}]"
                        fi
                    fi
                    trackTitle="${trackLine#* }"
                    trackTitle="${trackTitle#-}"
                    trackTitle="${trackTitle# }"
                    printOutput "5" "Found track time [${trackTime}] title [${trackTitle}] from input [${trackLine}]"
                    trackArr+=("${trackTime} ${trackTitle}")
                fi
            done <<<"${vidDesc}"

            # Move our imported file
            if [[ "${#trackArr[@]}" -ne "0" ]]; then
                # Our file needs to be split totalTracks
                ffmpegFail="0"
                for i in "${!trackArr[@]}"; do
                    trackNum="$(printf "%02d" "$(( i + 1 ))")" # Format as 01, 02, etc.
                    trackName="${trackArr[${i}]}"
                    trackName="${trackName#* }"
                    # Clean the track name
                    # Get the clean track title
                    trackNameClean="$(cleanTrackName "${trackName}")"

                    # Get our ID3 sanitized title
                    trackNameMetadata="${trackName}"
                    # Trim any leading spaces and/or periods
                    while [[ "${trackNameMetadata:0:1}" =~ ^( |\.)$ ]]; do
                        trackNameMetadata="${trackNameMetadata# }"
                        trackNameMetadata="${trackNameMetadata#\.}"
                    done
                    # Remove any leading track identifiers
                    if [[ "${trackNameMetadata}" =~ ^[0-9]+\.?\ ?\)\ ?.*$ ]]; then
                        trackNameMetadata="${trackNameMetadata#*\)}"
                        trackNameMetadata="${trackNameMetadata# }"
                    fi
                    # Trim any URL's
                    trackNameMetadata="${trackNameMetadata%%http*}"
                    # Trim any trailing spaces and/or periods
                    while [[ "${trackNameMetadata:$(( ${#trackNameMetadata} - 1 )):1}" =~ ^( |\.)$ ]]; do
                        trackNameMetadata="${trackNameMetadata% }"
                        trackNameMetadata="${trackNameMetadata%\.}"
                    done
                    # Trim any trailing dashes or colons
                    trackNameMetadata="${trackNameMetadata%:}"
                    trackNameMetadata="${trackNameMetadata%-}"
                    # Trim any trailing spaces and/or periods
                    while [[ "${trackNameMetadata:$(( ${#trackNameMetadata} - 1 )):1}" =~ ^( |\.)$ ]]; do
                        trackNameMetadata="${trackNameMetadata% }"
                        trackNameMetadata="${trackNameMetadata%\.}"
                    done
                    # Consense any excessive hyphens
                    while [[ "${trackNameMetadata}" =~ .*"- –".* ]]; do
                        trackNameMetadata="${trackNameMetadata//- -/-}"
                    done

                    # Get our start time
                    trackStartTime="${trackArr[${i}]}"
                    trackStartTime="${trackStartTime%% *}"

                    if [[ "${i}" -ne "$(( ${#trackArr[@]} - 1 ))" ]]; then
                        trackEndTime="${trackArr[$(( i + 1 ))]}"
                        trackEndTime="${trackEndTime%% *}"
                        # Check and make sure our end time is after our start time
                        if [[ "${trackStartTime}" -gt "${trackEndTime}" ]]; then
                            printOutput "1" "Found start time [${trackStartTime}] greater than end time [${trackEndTime}] for file ID [${ytId}] -- Skipping"
                            continue
                        fi
                    else
                        unset trackEndTime  # Let ffmpeg handle duration for the last track
                    fi

                    # Output path
                    outputPath="${outputDirAudio}/${channelPathClean}/${albumTitle}/${trackNum} - ${trackNameClean}.${fileExt}"

                    # FFmpeg command to extract segment and embed metadata
                    if [[ -n "${trackEndTime}" ]]; then
                        printOutput "5" "Issuing ffmpeg command [ffmpeg -hide_banner -loglevel error -i \"${moveFrom}\" -map_metadata -1 -ss \"${trackStartTime}\" -to \"${trackEndTime}\" -metadata title=\"${trackNameMetadata}\" -metadata track=\"${trackNum}/${#trackArr[@]}\" -metadata artist=\"${channelName}\" -metadata album=\"${vidTitle}\" -acodec copy \"${outputPath}\"]"
                        readarray -t ffmpegOutput< <(ffmpeg -i "${moveFrom}" \
                            -hide_banner -loglevel error \
                            -map_metadata -1 \
                            -ss "${trackStartTime}" \
                            -to "${trackEndTime}" \
                            -metadata title="${trackNameMetadata}" \
                            -metadata track="${trackNum}/${#trackArr[@]}" \
                            -metadata artist="${channelName}" \
                            -metadata album="${vidTitle}" \
                            -acodec copy "${outputPath}" 2>&1)
                    else
                        printOutput "5" "Issuing ffmpeg command [ffmpeg -hide_banner -loglevel error -i \"${moveFrom}\" -map_metadata -1 -ss \"${trackStartTime}\" -metadata title=\"${trackNameMetadata}\" -metadata track=\"${trackNum}/${#trackArr[@]}\" -metadata artist=\"${channelName}\" -metadata album=\"${vidTitle}\" -acodec copy \"${outputPath}\"]"
                        readarray -t ffmpegOutput < <(ffmpeg -i "${moveFrom}" \
                            -hide_banner -loglevel error \
                            -map_metadata -1 \
                            -ss "${trackStartTime}" \
                            -metadata title="${trackNameMetadata}" \
                            -metadata track="${trackNum}/${#trackArr[@]}" \
                            -metadata artist="${channelName}" \
                            -metadata album="${vidTitle}" \
                            -acodec copy "${outputPath}" 2>&1)
                    fi

                    if ! [[ -e "${outputPath}" ]]; then
                        ffmpegFail="1"
                        printOutput "1" "ffmpeg failed to generate output file [${vidTitle} (${vidYear}) [${ytId}]/${trackNum} - ${trackNameClean}.${fileExt}]"
                        printOutput "1" "ffmpeg output:"
                        for line in "${ffmpegOutput[@]}"; do
                            printOutput "1" "${line}"
                        done
                    else
                        printOutput "3" "Generated track [${vidTitle} (${vidYear}) [${ytId}]/${trackNum} - ${trackNameClean}.${fileExt}]"
                    fi
                done
                if [[ "${ffmpegFail}" -eq "0" ]]; then
                    audStatus="downloaded"
                    rm -f "${moveFrom}"
                else
                    audStatus="import_failed"
                fi
            else
                # Our file can be moved directly
                if ! mv "${moveFrom}" "${outputDirAudio}/${channelPathClean}/${albumTitle}/01 - ${vidTitleClean}.${fileExt}"; then
                    printOutput "1" "Failed to move file ID [${ytId}] from import path [${moveFrom}] to destination [${channelPath}/${albumTitle}/01 - ${vidTitleClean}.${fileExt}]"
                    audStatus="import_failed"
                else
                    audStatus="downloaded"
                    printOutput "3" "Imported audio [${albumTitle}/01 - ${vidTitleClean}.${fileExt}]"
                fi
            fi

            if [[ "${audStatus}" == "downloaded" ]]; then
                if ! sqDb "UPDATE config SET AUDIO_FORMAT = '${fileExt//\'/\'\'}', AUDIO_STATUS = '${audStatus}', AUDIO_ERROR = NULL, UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                    badExit "176" "Unable to update status to [${audStatus}] for file ID [${ytId}]"
                fi
            else
                printOutput "1" "Failed to import [${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}]"
                if ! sqDb "UPDATE media SET AUDIO_STATUS = '${audStatus}', UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                    badExit "177" "Unable to update status to [${audStatus}] for file ID [${ytId}]"
                fi
            fi
        done
    fi
fi

# Make sure we actually have downloads to process
videosDownloaded="0"
readarray -t downloadQueue < <(sqDb "SELECT FILE_ID FROM media WHERE VIDEO_STATUS = 'queued';")
if [[ "${#downloadQueue[@]}" -ne "0" && "${skipDownload}" -eq "0" ]]; then
    n="1"
    printOutput "3" "${colorBlue}########## Processing queued video downloads ##########${colorReset}"
    for ytId in "${downloadQueue[@]}"; do
        printOutput "4" "Downloading file ID [${ytId}] [Item ${n} of ${#downloadQueue[@]}]"
        (( n++ ))

        # Clean out our tmp dir, as if we previously failed due to out of space, we don't want everything else after to fail
        rm -rf "${tmpDir:?}/"*

        # Get the video title
        vidTitle="$(sqDb "SELECT TITLE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${vidTitle}" ]]; then
            badExit "178" "Retrieved blank title for file ID [${ytId}]"
        fi

        # Get the sanitized video title
        vidTitleClean="$(sqDb "SELECT TITLE_SAFE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${vidTitleClean}" ]]; then
            badExit "179" "Retrieved blank clean title for file ID [${ytId}]"
        fi

        # Get the channel ID
        channelId="$(sqDb "SELECT CHANNEL_ID FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${channelId}" ]]; then
            badExit "180" "Retrieved blank channel ID for file ID [${ytId}]"
        fi

        # Get the channel name
        channelName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${channelName}" ]]; then
            badExit "181" "Retrieved blank channel name for channel ID [${channelId}]"
        fi

        # Get the clean channel name
        channelNameClean="$(sqDb "SELECT NAME_SAFE FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${channelNameClean}" ]]; then
            badExit "182" "Retrieved blank clean channel name for channel ID [${channelId}]"
        fi

        # Get the channel path
        channelPath="$(sqDb "SELECT PATH FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${channelPath}" ]]; then
            badExit "183" "Retrieved blank channel path for channel ID [${channelId}]"
        fi

        # Get the season year
        vidYear="$(sqDb "SELECT UPLOAD_YEAR FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${vidYear}" ]]; then
            badExit "184" "Retrieved blank year for file ID [${ytId}]"
        fi

        # Get the episode index
        vidIndex="$(sqDb "SELECT YEAR_INDEX FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${vidIndex}" ]]; then
            badExit "185" "Retrieved blank index for file ID [${ytId}]"
        fi

        # Get the desired resolution
        videoOutput="$(sqDb "SELECT VIDEO_RESOLUTION FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${videoOutput}" ]]; then
            badExit "186" "Retrieved blank video format for file ID [${ytId}]"
        fi

        # Get the mark as watched option
        markWatched="$(sqDb "SELECT MARK_WATCHED FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${markWatched}" ]]; then
            badExit "187" "Retrieved blank mark watched option for file ID [${ytId}]"
        fi

        # Get the sponsor block status
        sponsorblockOpts="$(sqDb "SELECT SPONSORBLOCK_ENABLED_VIDEO FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${sponsorblockOpts}" ]]; then
            badExit "188" "Retrieved blank sponsor block setting for file ID [${ytId}]"
        fi

        # Get the thumbnail URL
        thumbUrl="$(sqDb "SELECT THUMBNAIL_URL FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${thumbUrl}" ]]; then
            badExit "189" "Retrieved blank thumbnail URL for file ID [${ytId}]"
        fi

        # Get the video type
        vidType="$(sqDb "SELECT TYPE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${vidType}" ]]; then
            badExit "190" "Retrieved blank video type for file ID [${ytId}]"
        fi
        case "${vidType}" in
            video | normal_private)
                vidType="Video"
                ;;
            members_only)
                vidType="Members Only Video"
                ;;
            short | short_private)
                vidType="Short"
                ;;
            waslive | live)
                vidType="Live Broadcast"
                ;;
            *)
                printOutput "1" "Unknown vidType [${vidType}] encountered."
                ;;
        esac

        # Check if the base channel directory exists
        if ! [[ -d "${outputDir}/${channelPath}" ]]; then
            # Create it
            if ! mkdir -p "${outputDir}/${channelPath}"; then
                badExit "191" "Unable to create directory [${outputDir}/${channelPath}]"
            fi
            newVideoDir+=("${channelId}")

            # Create the series image
            makeShowImage "${channelId}"
        fi

        # Check if the season directory exists
        if ! [[ -d "${outputDir}/${channelPath}/Season ${vidYear}" ]]; then
            # Create it
            if ! mkdir -p "${outputDir}/${channelPath}/Season ${vidYear}"; then
                badExit "192" "Unable to create directory [${outputDir}/${channelPath}/Season ${vidYear}]"
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
            printOutput "1" "Download of video file ID [${ytId}] failed"
            if [[ -n "${dlpError}" ]]; then
                printOutput "1" "Found yt-dlp error message [${dlpError}]"
            fi
            printOutput "1" "=========== Begin yt-dlp log ==========="
            for z in "${dlpOutput[@]}"; do
                printOutput "1" "${z}"
            done
            printOutput "1" "============ End yt-dlp log ============"
            printOutput "1" "Skipping file ID [${ytId}]"
            if ! sqDb "UPDATE media SET VIDEO_STATUS = 'failed', UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                badExit "193" "Unable to update status to [failed] for file ID [${ytId}]"
            fi
            if [[ "${dlpError}" == "ERROR: [youtube] ${ytId}: Join this channel from your computer or Android app to get access to members-only content like this video." ]]; then
                # It's a members-only video. Mark it as 'skipped' rather than 'failed'.
                if ! sqDb "UPDATE media SET TYPE = 'members_only', VIDEO_STATUS = 'skipped', VIDEO_ERROR = 'Video is members only', UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                    badExit "194" "Unable to update status to [skipped] due to being a members only video for file ID [${ytId}]"
                fi
            elif [[ "${dlpError}" == "ERROR: [youtube] ${ytId}: Join this channel to get access to members-only content like this video, and other exclusive perks." ]]; then
                # It's a members-only video. Mark it as 'skipped' rather than 'failed'.
                if ! sqDb "UPDATE media SET TYPE = 'members_only', VIDEO_STATUS = 'skipped', VIDEO_ERROR = 'Video is members only', UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                    badExit "195" "Unable to update status to [skipped] due to being a members only video for file ID [${ytId}]"
                fi
            elif [[ "${dlpError}" =~ ^"ERROR: [youtube] ${ytId}: This video is available to this channel's members on level".*$ ]]; then
                # It's a members-only video. Mark it as 'skipped' rather than 'failed'.
                if ! sqDb "UPDATE media SET TYPE = 'members_only', VIDEO_STATUS = 'skipped', VIDEO_ERROR = 'Video is members only', UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                    badExit "196" "Unable to update status to [skipped] due to being a members only video for file ID [${ytId}]"
                fi
            elif [[ "${dlpError}" == "ERROR: [youtube] ${ytId}: This live stream recording is not available." ]]; then
                # It's a previous live broadcast whose recording is not (and won't) be available
                if ! sqDb "UPDATE media SET TYPE = 'hidden_broadcast', VIDEO_STATUS = 'skipped', VIDEO_ERROR = 'Video is a previous live broadcast with unavailable stream', UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                    badExit "197" "Unable to update status to [skipped] due to being a live broadcast with unavailable stream video for file ID [${ytId}]"
                fi
            else
                # Failed for some other reason
                errorFormatted="$(printf "%s\n" "${dlpOutput[@]}")"
                if ! sqDb "UPDATE media SET VIDEO_STATUS = 'failed', VIDEO_ERROR = '${errorFormatted//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                    badExit "198" "Unable to update status to [failed] for file ID [${ytId}]"
                fi
            fi
            # Throttle if it's not the last item
            if [[ "${n}" -lt "${#downloadQueue[@]}" ]]; then
                throttleDlp
            fi
            continue
        else
            printOutput "4" "File downloaded [$(timeDiff "${startTime}" "${endTime}")]"
            (( videosDownloaded++ ))
        fi

        # Get the thumbnail
        callCurlDownload "${thumbUrl}" "${tmpDir}/${ytId}.jpg"

        if ! [[ -e "${tmpDir}/${ytId}.jpg" ]]; then
            printOutput "1" "Download of thumbnail for video file ID [${ytId}] failed"
        fi

        # Make sure we can move the video from tmp to destination
        if ! mv "${tmpDir}/${ytId}.mp4" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4"; then
            printOutput "1" "Failed to move file ID [${ytId}] from tmp dir [${tmpDir}] to destination [${channelPath}/Season ${vidYear}] -- Skipping"
            continue
        else
            # Make sure we can move the thumbnail from tmp to destination
            if ! mv "${tmpDir}/${ytId}.jpg" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"; then
                printOutput "1" "Failed to move thumbnail for file ID [${ytId}] from tmp dir [${tmpDir}] to destination [${channelPath}/Season ${vidYear}] -- Skipping"
                continue
            fi
        fi

        # Safety check on the move
        if [[ -e "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4" ]]; then
            printOutput "3" "Successfully imported video [${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}]"
            if ! sqDb "UPDATE media SET VIDEO_STATUS = 'downloaded', UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                badExit "199" "Unable to update status to [downloaded] for file ID [${ytId}]"
            fi
        else
            printOutput "1" "Failed to download [${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}]"
            if ! sqDb "UPDATE media SET VIDEO_STATUS = 'failed', UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                badExit "200" "Unable to update status to [failed] for file ID [${ytId}]"
            fi
        fi

        # Grab any desired subtitles
        downloadSubs "${ytId}"

        # If we should mark a video as watched, add it to an array to deal with later
        if [[ "${markWatched}" == "1" ]]; then
            if [[ -z "${watchedArr["_${ytId}"]}" ]]; then
                watchedArr["_${ytId}"]="watched"
            else
                if [[ "${watchedArr["_${ytId}"]}" == "watched" ]]; then
                    printOutput "5" "File ID [${ytId}] already marked as [watched]"
                else
                    printAngryWarning
                    printOutput "2" "Attempted to overwrite file ID [${ytId}] watch status of [${watchedArr["_${ytId}"]}] with [watched]"
                fi
            fi
        fi

        # Add the channel ID to an array for metadata update later
        updateVideoMetadata["${channelId}"]="true"

        # Send a telegram message, if allowed
        if [[ -n "${telegramBotId}" && -n "${telegramChannelVideo}" ]]; then
            if [[ -e "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg" ]]; then
                printOutput "4" "Sending Telegram image message"
                sendTelegramImage "${telegramChannelVideo}" "<b>${vidType} Downloaded</b>${lineBreak}${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"
            else
                printOutput "4" "Sending Telegram text message"
                sendTelegramMessage "${telegramChannelVideo}" "<b>${vidType} Downloaded</b>${lineBreak}${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}"
            fi
        else
            printOutput "5" "Telegram messaging disabled"
        fi
        # Send a discord message, if allowed
        if [[ -n "${discordWebhookVideo}" ]]; then
            if [[ -e "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg" ]]; then
                printOutput "4" "Sending Discord image message"
                sendDiscordImage "${discordWebhookVideo}" "**${vidType} Downloaded**${lineBreak}${channelName} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitle}" "${outputDir}/${channelPath}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].jpg"
            else
                printOutput "4" "Sending Discord text message"
                # TODO: This
            fi
        else
            printOutput "5" "Discord messaging disabled"
        fi

        # Throttle if it's not the last item
        if [[ "${n}" -lt "${#downloadQueue[@]}" ]]; then
            throttleDlp
        fi
    done
fi

# Download albums
albumsDownloaded="0"
if [[ "${allowAudio}" -eq "1" ]]; then
    readarray -t downloadQueue < <(sqDb "SELECT FILE_ID FROM media WHERE AUDIO_STATUS = 'queued';")
    if [[ "${#downloadQueue[@]}" -ne "0" && "${skipDownload}" -eq "0" ]]; then
        n="1"
        printOutput "3" "${colorBlue}########## Processing queued audio downloads ##########${colorReset}"
        for ytId in "${downloadQueue[@]}"; do
            printOutput "4" "Downloading file ID [${ytId}] [Item ${n} of ${#downloadQueue[@]}]"
            (( n++ ))
            unset audioCheck
            # Check and see what format we want the audio in
            outputAudio="$(sqDb "SELECT AUDIO_FORMAT FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            # Check our SponsorBlock options
            audioEnableSB="$(sqDb "SELECT SPONSORBLOCK_ENABLED_AUDIO FROM config WHERE FILE_ID = '${1//\'/\'\'}';")"
            # Check and see if we have a video file we can just rip the audio from
            vidStatus="$(sqDb "SELECT VIDEO_STATUS FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            # We need: channelPathClean, vidYear, channelNameClean, vidIndex, vidTitleClean
            # We need the channel ID to get the first two
            channelId="$(sqDb "SELECT CHANNEL_ID FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            channelName="$(sqDb "SELECT NAME FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            channelPathClean="$(sqDb "SELECT PATH FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            channelNameClean="$(sqDb "SELECT NAME_SAFE FROM channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
            vidYear="$(sqDb "SELECT UPLOAD_YEAR FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            vidIndex="$(sqDb "SELECT YEAR_INDEX FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            vidTitle="$(sqDb "SELECT TITLE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            vidTitleClean="$(sqDb "SELECT TITLE_SAFE FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            # Build our album path
            readarray -t albumVersion < <(sqDb "SELECT FILE_ID FROM media WHERE CHANNEL_ID = '${channelId//\'/\'\'}' AND TITLE_SAFE = '${vidTitleClean//\'/\'\'}' AND UPLOAD_YEAR = ${vidYear} ORDER BY TIMESTAMP ASC;")
            if [[ "${#albumVersion[@]}" -eq "1" ]]; then
                albumTitle="${vidTitleClean} (${vidYear}) [${ytId}]"
            else
                # Find out what version we are
                albumVersion="1"
                for localId in "${albumVersion[@]}"; do
                    if [[ "${localId}" == "${ytId}" ]]; then
                        break
                    else
                        (( albumVersion++ ))
                    fi
                done
                if [[ "${albumVersion}" -eq "1" ]]; then
                    albumTitle="${vidTitleClean} (${vidYear}) [${ytId}]"
                else
                    albumTitle="${vidTitleClean}, Version ${albumVersion} (${vidYear}) [${ytId}]"
                fi
            fi
            if [[ "${vidStatus}" == "downloaded" ]]; then
                # We have a video file, let's make sure it actually exists where we think it should
                # Build the expected path into a single variable
                vidLoc="${outputDir}/${channelPathClean}/Season ${vidYear}/${channelNameClean} - S${vidYear}E$(printf '%03d' "${vidIndex}") - ${vidTitleClean} [${ytId}].mp4"
                # Make sure that file exists, so we can interact with it
                if [[ -e "${vidLoc}" ]]; then
                    # Next let's make sure it's not altered by SponsorBlock
                    sbStatus="$(sqDb "SELECT SPONSORBLOCK_ENABLED_VIDEO FROM config WHERE FILE_ID = '${ytId//\'/\'\'}';")"
                    if ! [[ "${sbStatus}" == "remove" ]]; then
                        # The status is not 'remove', so we can use it for audio
                        if [[ "${audioEnableSB}" == "remove" ]]; then
                            # If we're using SponsorBlock 'remove', use yt-dlp to grab new audio
                            if ! downloadAudio "${ytId}"; then
                                printOutput "1" "Failed to download audio for file ID [${ytId}] -- Skipping"
                                continue
                            fi
                        else
                            printOutput "3" "Ripping audio from existing video download"
                            if [[ "${outputAudio}" == "opus" ]]; then
                                printOutput "4" "Extracting audio from source video in opus format"
                                readarray -t ffmpegOutput < <(ffmpeg -i "${vidLoc}" -vn -acodec copy "${tmpDir}/${ytId}.${outputAudio}" 2>&1)
                            elif [[ "${outputAudio}" == "mp3" ]]; then
                                printOutput "4" "Extracting audio from source video in mp3 format"
                                readarray -t ffmpegOutput < <(ffmpeg -i "${vidLoc}" -vn -b:a 192k "${tmpDir}/${ytId}.${outputAudio}" 2>&1)
                            else
                                badExit "201" "Invalid audio output format [${outputAudio}]"
                            fi
                            if ! [[ -e "${tmpDir}/${ytId}.${outputAudio}" ]]; then
                                printOutput "1" "Failed to extract audio from [${vidLoc}] to [${tmpDir}/${ytId}.${outputAudio}]"
                                printOutput "1" "ffmpeg log:"
                                for line in "${ffmpegOutput[@]}"; do
                                    printOutput "1" "${line}"
                                done
                                printOutput "1" "Skipping audio download for file ID [${ytId}]"
                                continue
                            else
                                # Make sure the output file is valid
                                if ffprobe "${tmpDir}/${ytId}.${outputAudio}" > /dev/null 2>&1; then
                                    # We're valid
                                    printOutput "5" "Validated extracted audio"
                                else
                                    # We're not valid
                                    printOutput "2" "Extracted audio for file ID [${ytId}] failed to validate, removing and grabbing via yt-dlp"
                                    rm -f "${tmpDir}/${ytId}.${outputAudio}"
                                    if ! downloadAudio "${ytId}"; then
                                        printOutput "1" "Failed to download audio for file ID [${ytId}] -- Skipping"
                                        continue
                                    fi
                                fi
                            fi
                        fi
                    else
                        # It is 'remove', so we can't use the video file
                        if ! downloadAudio "${ytId}"; then
                            printOutput "1" "Failed to download audio for file ID [${ytId}] -- Skipping"
                            continue
                        fi
                    fi
                else
                    # File does not exist
                    # Get the file via yt-dlp
                    if ! downloadAudio "${ytId}"; then
                        printOutput "1" "Failed to download audio for file ID [${ytId}] -- Skipping"
                        continue
                    fi
                fi
            else
                # No dice, we're gonna have to grab it via yt-dlp
                if ! downloadAudio "${ytId}"; then
                    printOutput "1" "Failed to download audio for file ID [${ytId}] -- Skipping"
                    continue
                fi
            fi
            # We now have the temporary audio file ${tmpDir}/${ytId}.${outputAudio}, process it further
            # Create our destination
            if ! mkdir -p "${outputDirAudio}/${channelPathClean}/${albumTitle}"; then
                printOutput "1" "Unable to create destination directory [${outputDirAudio}/${channelPathClean}/${albumTitle}] -- Skipping"
                continue
            else
                printOutput "5" "Created destination directory [${outputDirAudio}/${channelPathClean}/${albumTitle}]"
            fi

            # Get the thumbnail URL
            thumbUrl="$(sqDb "SELECT THUMBNAIL_URL FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"
            # Make sure it's not blank
            if [[ -z "${thumbUrl}" ]]; then
                badExit "202" "Retrieved blank thumbnail URL for file ID [${ytId}]"
            fi
            # Get the thumbnail
            callCurlDownload "${thumbUrl}" "${tmpDir}/${ytId}.jpg"
            if ! convert "${tmpDir}/${ytId}.jpg" -gravity center -crop "$(identify -format '%[fx:min(w,h)]x%[fx:min(w,h)]' "${tmpDir}/${ytId}.jpg")+0+0" +repage "${outputDirAudio}/${channelPathClean}/${albumTitle}/cover.jpg"; then
                printOutput "1" "Download of thumbnail for audio file ID [${ytId}] failed"
            else
                printOutput "5" "Thumbnail for audio file ID [${ytId}] generated successfully"
                rm -f "${tmpDir}/${ytId}.jpg"
            fi

            # If we used SponsorBlock, we can't track split, so just go ahead and move the album
            if [[ "${audioEnableSB}" == "remove" ]]; then
                # Move the file to its destination
                trackName="${vidTitle}"
                # Get the clean track title
                trackNameClean="$(cleanTrackName "${trackName}")"
                # Move it
                mv "${tmpDir}/${ytId}.${outputAudio}" "${outputDirAudio}/${channelPathClean}/${albumTitle}/01 - ${trackNameClean}.${outputAudio}"
                audioCheck+=("${outputDirAudio}/${channelPathClean}/${albumTitle}/01 - ${trackNameClean}.${outputAudio}")
            else
                # Check and see if we need to split the track
                # Get the description so we can see if we need to split the file in to tracks
                vidDesc="$(sqDb "SELECT DESC FROM media WHERE FILE_ID = '${ytId//\'/\'\'}';")"

                # Calculate our trackArr
                unset trackArr
                while read -r trackLine; do
                    if [[ "${trackLine}" =~ ^([0-9]{1,3}:)?[0-5]?[0-9]:[0-5][0-9]\ .* ]]; then
                        if [[ "${#trackArr[@]}" -eq "0" ]]; then
                            # Track 1
                            trackTime="0"
                        else
                            trackTime="${trackLine%% *}"
                            if [[ "${trackTime}" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
                                # Format is HH:MM:SS
                                trackHours="${trackTime%%:*}"
                                if ! [[ "${trackHours}" =~ ^[0-9]+$ ]]; then
                                    badExit "203" "Track Hours for file ID [${ytId}] returned non integer [${trackHours}] from source [${trackTime}]"
                                else
                                    # Trim leading zeroes so bash doesn't lose its shit
                                    while [[ "${trackHours:0:1}" -eq "0" && ! "${trackHours}" == "0" ]]; do
                                        trackHours="${trackHours:1}"
                                    done
                                fi
                                trackMins="${trackTime#*:}"
                                trackMins="${trackMins%:*}"
                                if ! [[ "${trackMins}" =~ ^[0-9]+$ ]]; then
                                    badExit "204" "Track Minutes for file ID [${ytId}] returned non integer [${trackMins}] from source [${trackTime}]"
                                else
                                    # Trim leading zeroes so bash doesn't lose its shit
                                    while [[ "${trackMins:0:1}" -eq "0" && ! "${trackMins}" == "0" ]]; do
                                        trackMins="${trackMins:1}"
                                    done
                                fi
                                trackSecs="${trackTime##*:}"
                                if ! [[ "${trackSecs}" =~ ^[0-9]+$ ]]; then
                                    badExit "205" "Track Seconds for file ID [${ytId}] returned non integer [${trackSecs}] from source [${trackTime}]"
                                else
                                    # Trim leading zeroes so bash doesn't lose its shit
                                    while [[ "${trackSecs:0:1}" -eq "0" && ! "${trackSecs}" == "0" ]]; do
                                        trackSecs="${trackSecs:1}"
                                    done
                                fi
                                trackTime="$(( trackHours * 3600 + trackMins * 60 + trackSecs ))"
                            elif [[ "${trackTime}" =~ ^[0-9]+:[0-9]+$ ]]; then
                                # Format is MM:SS
                                trackMins="${trackTime%:*}"
                                if ! [[ "${trackMins}" =~ ^[0-9]+$ ]]; then
                                    badExit "206" "Track Minutes for file ID [${ytId}] returned non integer [${trackMins}] from source [${trackTime}]"
                                else
                                    # Trim leading zeroes so bash doesn't lose its shit
                                    while [[ "${trackMins:0:1}" -eq "0" && ! "${trackMins}" == "0" ]]; do
                                        trackMins="${trackMins:1}"
                                    done
                                fi
                                trackSecs="${trackTime#*:}"
                                if ! [[ "${trackSecs}" =~ ^[0-9]+$ ]]; then
                                    badExit "207" "Track Seconds for file ID [${ytId}] returned non integer [${trackSecs}] from source [${trackTime}]"
                                else
                                    # Trim leading zeroes so bash doesn't lose its shit
                                    while [[ "${trackSecs:0:1}" -eq "0" && ! "${trackSecs}" == "0" ]]; do
                                        trackSecs="${trackSecs:1}"
                                    done
                                fi
                                trackTime="$(( trackMins * 60 + trackSecs ))"
                            else
                                badExit "208" "Invalid time string format [${trackLine}]"
                            fi
                        fi
                        trackTitle="${trackLine#* }"
                        trackTitle="${trackTitle#-}"
                        trackTitle="${trackTitle# }"
                        printOutput "5" "Found track time [${trackTime}] title [${trackTitle}] from input [${trackLine}]"
                        trackArr+=("${trackTime} ${trackTitle}")
                    fi
                done <<<"${vidDesc}"

                # If we need to split in to tracks...
                if [[ "${#trackArr[@]}" -gt "1" ]]; then
                    # Our file needs to be split totalTracks
                    unset trackMsgArr
                    # Go ahead and grab the whole audio so we can work with that
                    tmpFile="${tmpDir}/${ytId}.${outputAudio}"
                    # Generate our track list
                    ffmpegFail="0"
                    for i in "${!trackArr[@]}"; do
                        trackNum="$(printf "%02d" "$(( i + 1 ))")" # Format as 01, 02, etc.
                        trackName="${trackArr[${i}]}"
                        trackName="${trackName#* }"
                        # Get the clean track title
                        trackNameClean="$(cleanTrackName "${trackName}")"

                        # Get our ID3 sanitized title
                        trackNameMetadata="${trackName}"
                        # Trim any leading spaces and/or periods
                        while [[ "${trackNameMetadata:0:1}" =~ ^( |\.)$ ]]; do
                            trackNameMetadata="${trackNameMetadata# }"
                            trackNameMetadata="${trackNameMetadata#\.}"
                        done
                        # Remove any leading track identifiers
                        if [[ "${trackNameMetadata}" =~ ^[0-9]+\.?\ ?\)\ ?.*$ ]]; then
                            trackNameMetadata="${trackNameMetadata#*\)}"
                            trackNameMetadata="${trackNameMetadata# }"
                        fi
                        # Trim any URL's
                        trackNameMetadata="${trackNameMetadata%%http*}"
                        # Trim any trailing spaces and/or periods
                        while [[ "${trackNameMetadata:$(( ${#trackNameMetadata} - 1 )):1}" =~ ^( |\.)$ ]]; do
                            trackNameMetadata="${trackNameMetadata% }"
                            trackNameMetadata="${trackNameMetadata%\.}"
                        done
                        # Trim any trailing dashes or colons
                        trackNameMetadata="${trackNameMetadata%:}"
                        trackNameMetadata="${trackNameMetadata%-}"
                        # Trim any trailing spaces and/or periods
                        while [[ "${trackNameMetadata:$(( ${#trackNameMetadata} - 1 )):1}" =~ ^( |\.)$ ]]; do
                            trackNameMetadata="${trackNameMetadata% }"
                            trackNameMetadata="${trackNameMetadata%\.}"
                        done
                        # Consense any excessive hyphens
                        while [[ "${trackNameMetadata}" =~ .*"- –".* ]]; do
                            trackNameMetadata="${trackNameMetadata//- -/-}"
                        done

                        # Get our start time
                        trackStartTime="${trackArr[${i}]}"
                        trackStartTime="${trackStartTime%% *}"

                        if [[ "${i}" -ne "$(( ${#trackArr[@]} - 1 ))" ]]; then
                            trackEndTime="${trackArr[$(( i + 1 ))]}"
                            trackEndTime="${trackEndTime%% *}"
                            # Check and make sure our end time is after our start time
                            if [[ "${trackStartTime}" -gt "${trackEndTime}" ]]; then
                                printOutput "1" "Found start time [${trackStartTime}] greater than end time [${trackEndTime}] for file ID [${ytId}] -- Skipping"
                                continue
                            fi
                        else
                            unset trackEndTime  # Let ffmpeg handle duration for the last track
                        fi

                        # Output path
                        outputPath="${outputDirAudio}/${channelPathClean}/${albumTitle}/${trackNum} - ${trackNameClean}.${outputAudio}"
                        trackMsgArr+=("${trackNum} - ${trackNameClean}")

                        # FFmpeg command to extract segment and embed metadata
                        if [[ "${outputAudio}" == "opus" ]]; then
                            if [[ -n "${trackEndTime}" ]]; then
                                printOutput "5" "Issuing ffmpeg command [ffmpeg -hide_banner -loglevel error -i \"${tmpFile}\" -map_metadata -1 -ss \"${trackStartTime}\" -to \"${trackEndTime}\" -metadata title=\"${trackNameMetadata}\" -metadata track=\"${trackNum}/${#trackArr[@]}\" -metadata artist=\"${channelName}\" -metadata album=\"${vidTitle}\" -acodec copy \"${outputPath}\"]"
                                readarray -t ffmpegOutput< <(ffmpeg -i "${tmpFile}" \
                                    -hide_banner -loglevel error \
                                    -map_metadata -1 \
                                    -ss "${trackStartTime}" \
                                    -to "${trackEndTime}" \
                                    -metadata title="${trackNameMetadata}" \
                                    -metadata track="${trackNum}/${#trackArr[@]}" \
                                    -metadata artist="${channelName}" \
                                    -metadata album="${vidTitle}" \
                                    -acodec copy "${outputPath}" 2>&1)
                            else
                                printOutput "5" "Issuing ffmpeg command [ffmpeg -hide_banner -loglevel error -i \"${tmpFile}\" -map_metadata -1 -ss \"${trackStartTime}\" -metadata title=\"${trackNameMetadata}\" -metadata track=\"${trackNum}/${#trackArr[@]}\" -metadata artist=\"${channelName}\" -metadata album=\"${vidTitle}\" -acodec copy \"${outputPath}\"]"
                                readarray -t ffmpegOutput < <(ffmpeg -i "${tmpFile}" \
                                    -hide_banner -loglevel error \
                                    -map_metadata -1 \
                                    -ss "${trackStartTime}" \
                                    -metadata title="${trackNameMetadata}" \
                                    -metadata track="${trackNum}/${#trackArr[@]}" \
                                    -metadata artist="${channelName}" \
                                    -metadata album="${vidTitle}" \
                                    -acodec copy "${outputPath}" 2>&1)
                            fi
                        elif [[ "${outputAudio}" == "mp3" ]]; then
                            if [[ -n "${trackEndTime}" ]]; then
                                printOutput "5" "Issuing ffmpeg command [ffmpeg -hide_banner -loglevel error -i \"${tmpFile}\" -map_metadata -1 -ss \"${trackStartTime}\" -to \"${trackEndTime}\" -metadata title=\"${trackNameMetadata}\" -metadata track=\"${trackNum}/${#trackArr[@]}\" -metadata artist=\"${channelName}\" -metadata album=\"${vidTitle}\" -b:a 192k \"${outputPath}\"]"
                                readarray -t ffmpegOutput< <(ffmpeg -i "${tmpFile}" \
                                    -hide_banner -loglevel error \
                                    -map_metadata -1 \
                                    -ss "${trackStartTime}" \
                                    -to "${trackEndTime}" \
                                    -metadata title="${trackNameMetadata}" \
                                    -metadata track="${trackNum}/${#trackArr[@]}" \
                                    -metadata artist="${channelName}" \
                                    -metadata album="${vidTitle}" \
                                    -b:a 192k "${outputPath}" 2>&1)
                            else
                                printOutput "5" "Issuing ffmpeg command [ffmpeg -hide_banner -loglevel error -i \"${tmpFile}\" -map_metadata -1 -ss \"${trackStartTime}\" -metadata title=\"${trackNameMetadata}\" -metadata track=\"${trackNum}/${#trackArr[@]}\" -metadata artist=\"${channelName}\" -metadata album=\"${vidTitle}\" -b:a 192k \"${outputPath}\"]"
                                readarray -t ffmpegOutput < <(ffmpeg -i "${tmpFile}" \
                                    -hide_banner -loglevel error \
                                    -map_metadata -1 \
                                    -ss "${trackStartTime}" \
                                    -metadata title="${trackNameMetadata}" \
                                    -metadata track="${trackNum}/${#trackArr[@]}" \
                                    -metadata artist="${channelName}" \
                                    -metadata album="${vidTitle}" \
                                    -b:a 192k "${outputPath}" 2>&1)
                            fi
                        else
                            printOutput "1" "Invalid output audio format [${outputAudio}] for file ID [${ytId}]"
                            continue
                        fi

                        audioCheck+=("${outputPath}")

                        if ! [[ -e "${outputPath}" ]]; then
                            ffmpegFail="1"
                            printOutput "1" "ffmpeg failed to generate output file [${vidTitle} (${vidYear}) [${ytId}]/${trackNum} - ${trackNameClean}.${outputAudio}]"
                            printOutput "1" "ffmpeg output:"
                            for line in "${ffmpegOutput[@]}"; do
                                printOutput "1" "${line}"
                            done
                        else
                            printOutput "3" "Generated track [${vidTitle} (${vidYear}) [${ytId}]/${trackNum} - ${trackNameClean}.${outputAudio}]"
                        fi
                    done
                    if [[ "${ffmpegFail}" -eq "0" ]]; then
                        audStatus="downloaded"
                    else
                        audStatus="failed"
                    fi
                    rm -f "${tmpFile}"
                else
                    # We don't need to split in to tracks, we can directly extract the audio to the destination
                    trackName="${vidTitle}"
                    # Get the clean track title
                    trackNameClean="$(cleanTrackName "${trackName}")"
                    # Move it
                    mv "${tmpDir}/${ytId}.${outputAudio}" "${outputDirAudio}/${channelPathClean}/${albumTitle}/01 - ${trackNameClean}.${outputAudio}"
                    audioCheck+=("${outputDirAudio}/${channelPathClean}/${albumTitle}/01 - ${trackNameClean}.${outputAudio}")
                fi
            fi

            # Check and make sure we're good
            audioCheckGood="1"
            unset audioCheckErrors
            for file in "${audioCheck[@]}"; do
                if [[ -e "${file}" ]]; then
                    printOutput "5" "Verified file [${file}]"
                else
                    printOutput "1" "Failed to verify file [${file}]"
                    audioCheckErrors+=("Failed to verify file [${file}]")
                    audioCheckGood="0"
                fi
            done

            if [[ "${audioCheckGood}" -eq "0" ]]; then
                # Failed
                printOutput "1" "Failed to download [${channelName} - ${trackNameClean}]"
                errorFormatted="$(printf "%s\n" "${audioCheckErrors[@]}")"
                if ! sqDb "UPDATE media SET AUDIO_STATUS = 'failed', AUDIO_ERROR = '${errorFormatted//\'/\'\'}', UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                    badExit "209" "Unable to update status to [failed] for file ID [${ytId}]"
                fi
            else
                # Succeeded
                printOutput "3" "Successfully imported album [${channelName} - ${trackNameClean}]"
                if ! sqDb "UPDATE media SET AUDIO_STATUS = 'downloaded', UPDATED = '$(date)' WHERE FILE_ID = '${ytId//\'/\'\'}';"; then
                    badExit "210" "Unable to update status to [downloaded] for file ID [${ytId}]"
                fi
                # Notate that we need to update the artist metadata
                newAudioDir["${channelId}"]="true"
                # Notate that we need to update the album metadata
                newAlbumDir+=("${ytId}")

                # Add to our download count
                (( albumsDownloaded++ ))

                trackMsg="${channelName} - ${vidTitle}"
                # Send the track list as the message, if we have a track list
                if [[ "${#trackArr[@]}" -gt "1" ]]; then
                    trackMsg="${trackMsg}${lineBreak}$(printf "%s\n" "${trackMsgArr[@]}")"
                fi

                # Send a telegram message, if allowed
                if [[ -n "${telegramBotId}" && -n "${telegramChannelAudio}" ]]; then
                    if [[ -e "${outputDirAudio}/${channelPathClean}/${vidTitleClean} (${vidYear}) [${ytId}]/cover.jpg" ]]; then
                        printOutput "4" "Sending Telegram image message"
                        sendTelegramImage "${telegramChannelAudio}" "<b>Album Downloaded</b>${lineBreak}${trackMsg}" "${outputDirAudio}/${channelPathClean}/${vidTitleClean} (${vidYear}) [${ytId}]/cover.jpg"
                    else
                        printOutput "4" "Sending Telegram text message"
                        sendTelegramMessage "<b>YouTube Audio Downloaded</b>${lineBreak}${trackMsg}"
                    fi
                fi
                # Send a discord message, if allowed
                if [[ -n "${discordWebhookVideo}" ]]; then
                    if [[ -e "${outputDirAudio}/${channelPathClean}/${vidTitleClean} (${vidYear}) [${ytId}]/cover.jpg" ]]; then
                        printOutput "4" "Sending Discord image message"
                        sendDiscordImage "${discordWebhookAudio}" "**Album Downloaded**${lineBreak}${trackMsg}" "${outputDirAudio}/${channelPathClean}/${vidTitleClean} (${vidYear}) [${ytId}]/cover.jpg"
                    else
                        printOutput "4" "Sending Discord text message"
                        # TODO: This
                    fi
                fi
            fi
        done
    fi
fi

vidTotal="$(( ${#reindexArr[@]} + ${#importArrVideo[@]} + videosDownloaded ))"
if [[ "${vidTotal}" -ne "0" ]]; then
    refreshSleep="$(( vidTotal * 3 ))"
    if [[ "${refreshSleep}" -lt "30" ]]; then
        refreshSleep="30"
    elif [[ "${refreshSleep}" -gt "900" ]]; then
        refreshSleep="900"
    fi
    refreshLibrary "${libraryId}"
    printOutput "3" "Sleeping for [${refreshSleep}] seconds to give the Plex Scanner time to work"
    sleep "${refreshSleep}"
fi
audTotle="$(( ${#importArrAudio[@]} + albumsDownloaded ))"
if [[ "${audTotle}" -ne "0" ]]; then
    refreshSleep="$(( audTotle * 3 ))"
    if [[ "${refreshSleep}" -lt "30" ]]; then
        refreshSleep="30"
    elif [[ "${refreshSleep}" -gt "900" ]]; then
        refreshSleep="900"
    fi
    refreshLibrary "${audioLibraryId}"
    printOutput "3" "Sleeping for [${refreshSleep}] seconds to give the Plex Scanner time to work"
    sleep "${refreshSleep}"
fi

if [[ "${#newVideoDir[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}######### Initializing metadata for new series ########${colorReset}"
    printOutput "3" "Found [${#newVideoDir[@]}] new series to set metadata for"
    itemCount="1"
    for channelId in "${newVideoDir[@]}"; do
        printOutput "3" "Updating metadata for channel ID [${channelId}] [Item ${itemCount} of ${#newVideoDir[@]}]"
        (( itemCount++ ))

        # If we were planning to update this series due to a download, ignore it
        if [[ -n "${updateVideoMetadata[${channelId}]}" ]]; then
            unset updateVideoMetadata["${channelId}"]
        fi

        # Search the PMS library for the rating key of the series
        # This will also save the rating key to the database (Set series rating key)
        if ! setSeriesRatingKey "${channelId}"; then
            continue
        fi
        # We now have ${showRatingKey} set

        # Update the series metadata
        setSeriesMetadata "${showRatingKey}"
    done
fi

# Update metadata for any newly initialized artists
if [[ "${#newAudioDir[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}######### Initializing metadata for new artists #######${colorReset}"
    printOutput "3" "Found [${#newAudioDir[@]}] new artists to set metadata for"
    itemCount="1"
    for channelId in "${!newAudioDir[@]}"; do
        printOutput "3" "Updating metadata for channel ID [${channelId}] [Item ${itemCount} of ${#newAudioDir[@]}]"
        (( itemCount++ ))

        # If we were planning to update this series due to a download, ignore it
        if [[ -n "${updateAudioMetadata[${channelId}]}" ]]; then
            unset updateAudioMetadata["${channelId}"]
        fi

        # Search the PMS library for the rating key of the artist
        # This will also save the rating key to the database (Set artist rating key)
        if ! setArtistRatingKey "${channelId}"; then
            printOutput "2" "Failed to set artist rating key for channel ID [${channelId}]"
        fi
        # We should now have ${artistRatingKey} set
        if [[ -z "${artistRatingKey}" ]]; then
            printOutput "1" "Unable to retrieve artist rating key for channel ID [${channelId}] -- Skipping metadata update"
            continue
        fi

        # Update the artist metadata
        setArtistMetadata "${artistRatingKey}"
    done
fi

# Update metadata for newly downloaded albums
if [[ "${#newAlbumDir[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}######### Initializing metadata for new albums ########${colorReset}"
    printOutput "3" "Found [${#newAlbumDir[@]}] new albums to set metadata for"
    itemCount="1"
    for ytId in "${newAlbumDir[@]}"; do
        printOutput "3" "Updating metadata for album [${ytId}] [Item ${itemCount} of ${#newAlbumDir[@]}]"
        (( itemCount++ ))

        # Search the PMS library for the rating key of the album
        if ! getAlbumRatingKey "${ytId}"; then
            printOutput "2" "Failed to get album rating key for file ID [${ytId}]"
        fi
        # We should now have ${albumRatingKey} set
        if [[ -z "${albumRatingKey}" ]]; then
            printOutput "1" "Unable to retrieve album rating key for file ID [${ytId}] -- Skipping metadata update"
            continue
        fi

        # Update the album metadata
        printOutput "5" "Setting album metadata for file ID [${ytId}] via rating key [${albumRatingKey}]"
        setAlbumMetadata "${ytId}" "${albumRatingKey}"
    done
fi

# Update metadata for channels with newly downloaded content
# Video
if [[ "${#updateVideoMetadata[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}##### Updating metadata for series with downloads #####${colorReset}"
    printOutput "3" "Found [${#updateVideoMetadata[@]}] series to update metadata for"
    itemCount="1"
    for channelId in "${!updateVideoMetadata[@]}"; do
        printOutput "3" "Updating metadata for channel ID [${channelId}] [Item ${itemCount} of ${#updateVideoMetadata[@]}]"
        (( itemCount++ ))

        # Update the DB entry
        channelToDb "${channelId}"

        # Get the series rating key as ${showRatingKey}
        showRatingKey="$(sqDb "SELECT VIDEO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
        if ! [[ "${showRatingKey}" =~ ^[0-9]+$ ]]; then
            printOutput "1" "Retrieved invalid VIDEO_RATING_KEY [${showRatingKey}] for channel ID [${channelId}]"
            continue
        fi

        # Update the series metadata
        setSeriesMetadata "${showRatingKey}"

        # Update any images
        makeShowImage "${channelId}"
    done
fi
# Audio
if [[ "${#updateAudioMetadata[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}##### Updating metadata for artists with downloads ####${colorReset}"
    printOutput "3" "Found [${#updateAudioMetadata[@]}] series to update metadata for"
    itemCount="1"
    for channelId in "${updateAudioMetadata[@]}"; do
        printOutput "3" "Updating metadata for channel ID [${channelId}] [Item ${itemCount} of ${#updateAudioMetadata[@]}]"
        (( itemCount++ ))

        # Get the series rating key as ${artistRatingKey}
        artistRatingKey="$(sqDb "SELECT AUDIO_RATING_KEY FROM rating_key_channel WHERE CHANNEL_ID = '${channelId//\'/\'\'}';")"
        if ! [[ "${artistRatingKey}" =~ ^[0-9]+$ ]]; then
            printOutput "1" "Retrieved invalid AUDIO_RATING_KEY [${artistRatingKey}] for channel ID [${channelId}]"
            continue
        fi

        # Update the series metadata
        setArtistMetadata "${artistRatingKey}"
    done
fi

if [[ "${#watchedArr[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}############### Correting watch status ################${colorReset}"
    itemCount="1"
    for ytId in "${!watchedArr[@]}"; do
        ytId="${ytId#_}"
        printOutput "4" "Setting watched status [${watchedArr[_${ytId}]}] for file ID [${ytId}] [Item ${itemCount} of ${#watchedArr[@]}]"
        (( itemCount++ ))
        if ! setWatchStatus "${ytId}"; then
            printOutput "1" "Failed to set watch status for file ID [${ytId#_}]"
        fi
    done
fi

if [[ "${#updatePlaylist[@]}" -ne "0" ]]; then
    printOutput "3" "${colorBlue}########## Updating Collections & Playlists ###########${colorReset}"
    # For each playlist ID
    for plId in "${!updatePlaylist[@]}"; do
        plId="${plId#_}"

        # Get the title of the playlist
        plTitle="$(sqDb "SELECT TITLE FROM playlist WHERE PLAYLIST_ID = '${plId//\'/\'\'}';")"

        printOutput "3" "Processing playlist ID [${plId}] [${plTitle}]"
        # Get a list of the videos in the playlist, in order
        # We're going to start it from 1, because that makes debugging positioning easier on my brain
        unset plVidList
        plVidList[0]="null"
        while read -r ytId; do
            # We only care about it if it's downloaded
            dbVidStatus="$(sqDb "SELECT VIDEO_STATUS FROM media WHERE FILE_ID = '${ytId}';")"
            if [[ "${dbVidStatus}" == "downloaded" ]]; then
                plVidList+=("${ytId}")
            fi
        done < <(sqDb "SELECT FILE_ID FROM playlist_order WHERE PLAYLIST_ID = '${plId}' ORDER BY PLAYLIST_INDEX ASC;")
        unset plVidList[0]
        for ii in "${!plVidList[@]}"; do
            printOutput "5" "           plVidList | ${ii} => ${plVidList[${ii}]} [${titleArr[_${plVidList[${ii}]}]}]"
        done

        # Get the visibility of the playlist
        plVis="$(sqDb "SELECT VISIBILITY FROM playlist WHERE PLAYLIST_ID = '${plId//\'/\'\'}';")"
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
                collectionDelete "${plId}" "${collectionRatingKey}"

                # Check for any items that need adding
                collectionAdd "${plId}" "${collectionRatingKey}"

                # Sort the collection
                collectionSort "${plId}" "${collectionRatingKey}"
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
                    printOutput "5" "Seeded collection rating key [${collectionRatingKey}] for playlist ID [${plId}] with file ID [${plVidList[1]}] via rating key [${ratingKey}]"
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
                        printOutput "4" "Added file ID [${ytId}] to collection [${collectionRatingKey}]"
                    else
                        printOutput "1" "Failed to add [${ytId}] to collection [${collectionRatingKey}]"
                    fi
                done

                # Verify the order, which seems to get mixed up on creation
                collectionSort "${plId}" "${collectionRatingKey}"
            fi
            # TODO: Add audio support for collections here
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
                playlistDelete "${plId}" "${playlistRatingKey}"

                # Check for any items that need adding
                playlistAdd "${plId}" "${playlistRatingKey}"

                # Sort the collection
                playlistSort "${plId}" "${playlistRatingKey}"
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
                    badExit "211" "Received non-interger [${playlistRatingKey}] for playlist rating key for playlist ID [${plId}] on creation -- Skipping"
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
                playlistSort "${plId}" "${playlistRatingKey}"
            fi
        else
            printOutput "1" "Received unexpected visibility [${plVis}] for playlist ID [${plId}] -- Skipping"
            continue
        fi
        # TODO: Add audio support for playlists here
    done
fi

cleanExit
