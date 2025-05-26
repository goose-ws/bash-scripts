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
# This script will convert a particular YouTube playlist or channel page to a podcast

#############################
##        Changelog        ##
#############################
# 2025-05-24
# Initial commit

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
depsArr=("awk" "basename" "chmod" "curl" "date" "ffprobe" "md5sum" "mimetype" "mkdir" "printf" "qrencode" "realpath" "sha256sum" "shuf" "sqlite3" "stat" "xmllint" "yq" "yt-dlp")
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
# Local variables
realPath="$(realpath "${0}")"
scriptName="$(basename "${0}")"
lockFile="${realPath%/*}/.${scriptName}.lock"
# URL of where the most updated version of the script is
updateURL="https://raw.githubusercontent.com/goose-ws/bash-scripts/main/youtube_to_podcast.bash"
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
    removeLock "--silent"
else
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

function throttleDlp {
if ! [[ "${throttleMin}" -eq "0" && "${throttleMax}" -eq "0" ]]; then
    printOutput "4" "Throttling after yt-dlp download call"
    randomSleep "${throttleMin}" "${throttleMax}"
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
            msgEncoded="$(rawurlencode "${1}")"
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
function sqDb {
# Validate it
if [[ -z "${idCount}" ]]; then
    # We're the first entry
    idCount="1"
elif [[ "${idCount}" =~ ^[0-9]+$ ]]; then
    # Expected outcome
    (( idCount++ ))
elif ! [[ "${idCount}" =~ ^[0-9]+$ ]]; then
    printOutput "1" "Data [${idCount}] failed to validate as an INTEGER"
    return 1
else
    badExit "3" "Impossible condition"
fi

# Execute the command
if sqOutput="$(sqlite3 "${sqliteDb}" "${1}" 2>&1)"; then
    if [[ -n "${sqOutput}" ]]; then
        echo "${sqOutput}"
    fi
else
    sqlite3 "${sqliteDb}" "INSERT INTO error_log (TIME, COMMAND, RESULT, OUTPUT) VALUES ('$(date)', '${1//\'/\'\'}', 'Failure', '${sqOutput//\'/\'\'}');"
    if [[ -n "${sqOutput}" ]]; then
        echo "${sqOutput}"
    fi
    return 1
fi
}

function clean_lf {
echo "${1///}"
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

function html_encode {
    local input="${1}"
    # Order is important: & must be encoded first.
    input="${input//&/&amp;}"
    input="${input//</&lt;}"
    input="${input//>/&gt;}"
    input="${input//\"/&quot;}"
    input="${input//\'/&apos;}" # or &#39;
    input="${input//“/&ldquo;}" # Left double quote
    input="${input//”/&rdquo;}" # Right double quote
    echo "${input}"
}

function cdata_encode {
    local input
    input="$(html_encode "${1}")"

    # Convert URLs to clickable links using sed
    input=$(sed -E 's|(http[s]?://[^[:space:]]+)|<a href="\1">\1</a>|g' <<< "${input}")

    # Convert double newlines to paragraph tags
    input="${input//$'\n\n'/<\/p><p>}"

    # Convert single newlines to line breaks
    #input="${input//$'\n'/<br \/>$'\n'}"
    input="${input//$'\n'/<br \/>}"

    # Break the </p><p> in to two lines
    #input="${input//<\/p><p>/<\/p>$'\n'<p>}"

    # Wrap the content in paragraph tags
    echo "<p>${input}</p>"
}

function generate_uuid {
    # Generate SHA-256
    local hash
    hash="$(sha256sum <<<"${1}")"
    # Format the hash into a UUID-like format from the first 32 characters
    echo "${hash:0:8}-${hash:8:4}-4${hash:13:3}-${hash:17:4}-${hash:21:12}"
}

function ytApiCall {
if [[ -z "${1}" ]]; then
    printOutput "1" "No API endpoint passed for YouTube API call"
    return 1
fi
callCurlGet "https://www.googleapis.com/youtube/v3/${1}&key=${ytApiKey}"
# Check for a 400 or 403 error code
errorCode="$(yq -p json ".error.code" <<<"${curlOutput}")"
if [[ "${errorCode}" == "403" || "${errorCode}" == "400" ]]; then
    if [[ "${errorCode}" == "403" ]]; then
        badExit "4" "API key exhaused, unable to preform API calls."
    elif [[ "${errorCode}" == "400" ]]; then
        badExit "5" "API key appears to be invalid"
    fi
else
    (( apiCallsYouTube++ ))
    # Account for unit cost
    if [[ "${1%%\?*}" == "videos" ]]; then
        # Costs 5 units
        totalUnits="$(( totalUnits + 5 ))"
        totalVideoUnits="$(( totalVideoUnits + 5 ))"
    elif [[ "${1%%\?*}" == "captions" ]]; then
        # Costs 50 units
        totalUnits="$(( totalUnits + 50 ))"
        totalCaptionsUnits="$(( totalCaptionsUnits + 50 ))"
    elif [[ "${1%%\?*}" == "channels" ]]; then
        # Costs 8 units
        totalUnits="$(( totalUnits + 8 ))"
        totalChannelsUnits="$(( totalChannelsUnits + 8 ))"
    elif [[ "${1%%\?*}" == "playlists" ]]; then
        # Costs 3 units
        totalUnits="$(( totalUnits + 3 ))"
        totalPlaylistsUnits="$(( totalPlaylistsUnits + 3 ))"
    fi
fi
}

function sponsorApiCall {
callCurlGet "https://sponsor.ajay.app/api/${1}" "goose's bash script - contact [github <at> goose <dot> ws] for any concerns or questions"
(( apiCallsSponsor++ ))
}

function generate_qr {
# Check if the URL is provided
if [[ -z "${1}" ]]; then
    printOutput "1" "No URL passed to generate QR code"
    return 1
fi

# Get terminal width and height
term_width=$(tput cols)
term_height=$(tput lines)

# Minimum dimensions required for a larger QR code (59x31)
min_width=58
min_height=30

# Check if the terminal is large enough
if [[ "${term_width}" -lt "${min_width}" ]] || [[ "${term_height}" -lt "${min_height}" ]]; then
    printOutput "1" "Terminal is too small to generate QR code (Minimum size required: ${min_width}x${min_height})"
    return 1
fi

# Generate the QR code
printOutput "3" "QR code for URL [${1}]"
while read -r line; do
    printOutput "3" "${line}"
done < <(qrencode -t ANSIUTF8 <<<"${1}")
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
case "${1,,}" in
    "-h"|"--help")
        echo "-h  --help      Displays this help message"
        echo ""
        echo "-u  --update    Self update to the most recent version"
        exit 0
    ;;
    "-u"|"--update")
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
                badExit "6" "Update downloaded, but unable to \`chmod +x\`"
            fi
        else
            badExit "7" "Unable to download Update"
        fi
    ;;
esac

#############################
##   Initiate .env file    ##
#############################
if [[ -e "${realPath%/*}/${scriptName%.bash}.env" ]]; then
    source "${realPath%/*}/${scriptName%.bash}.env"
else
    badExit "8" "Error: \"${realPath%/*}/${scriptName%.bash}.env\" does not appear to exist"
fi

#############################
##       Update check      ##
#############################
if [[ "${updateCheck,,}" =~ ^(yes|true)$ ]]; then
    newest="$(curl -skL "${updateURL}" | md5sum | awk '{print $1}')"
    current="$(md5sum "${0}" | awk '{print $1}')"
    if ! [[ "${newest}" == "${current}" ]]; then
        printOutput "0" "A newer version is available"
        # If our ${TERM} is dumb, we're probably running via cron, and should push a message to Telegram, if allowed
        if [[ "${TERM,,}" == "dumb" ]]; then
            if [[ "${telegramErrorMessages}" =~ ^(yes|true)$ ]]; then
                sendTelegramMessage "[${0##*/}] An update is available" "${telegramErrorChannel}"
            fi
        fi
    else
        printOutput "3" "No new updates available"
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

# Make sure our URL is a playlist ID or a channel ID, not a channel @username
printOutput "3" "################ Validating source URL ################"
printOutput "5" "Source URL [${sourceUrl}]"
id="${sourceUrl#http:\/\/}"
id="${id#https:\/\/}"
id="${id#m\.}"
id="${id#www\.}"
if [[ "${id:0:8}" == "youtu.be" ]]; then
    # I think these short URL's can only be a file ID?
    badExit "9" "Found single file ID, please provide a channel or playlist"
elif [[ "${id:12:6}" == "shorts" ]]; then
    # This is a file ID for a short
    badExit "10" "Found short file ID, please provide a channel or playlist"
elif [[ "${id:0:8}" == "youtube." ]]; then
    # This can be a file ID (normal, live, or short), a channel ID, a channel name, or a playlist
    if [[ "${id:12:1}" == "@" ]]; then
        printOutput "4" "Found username"
        # It's a username
        ytId="${id:13}"
        ytId="${ytId%\&*}"
        ytId="${ytId%\?*}"
        ytId="${ytId%\/*}"
        # We have the "@username", we need the channel ID
        # Try using yt-dlp as an API First
        printOutput "4" "Calling yt-dlp to obtain channel ID from channel handle [@${ytId}]"
        channelId="$(yt-dlp -J --playlist-items 0 "https://www.youtube.com/@${ytId}")"
        channelId="$(yq -p json ".channel_id" <<<"${channelId}")"
        if ! [[ "${channelId}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
            # We don't, let's try the official API
            printOutput "3" "Calling API to obtain channel ID from channel handle [@${ytId}]"
            ytApiCall "channels?forHandle=@${ytId}&part=snippet"
            apiResults="$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")"

            # Validate it
            if [[ -z "${apiResults}" ]]; then
                badExit "11" "API lookup for channel ID of handle [${ytId}] returned blank results output (Bad API call?)"
            elif [[ "${apiResults}" =~ ^[0-9]+$ ]]; then
                # Expected outcome
                true
            elif ! [[ "${apiResults}" =~ ^[0-9]+$ ]]; then
                badExit "12" "API lookup for channel ID of handle [${ytId}] returned non-integer results [${apiResults}]"
            else
                badExit "13" "Impossible condition"
            fi

            if [[ "${apiResults}" -eq "0" ]]; then
                badExit "14" "API lookup for source parsing returned zero results"
            fi
            if [[ "$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")" -eq "1" ]]; then
                channelId="$(yq -p json ".items[0].id" <<<"${curlOutput}")"
                # Validate it
                if ! [[ "${channelId}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
                    badExit "15" "Unable to validate channel ID for [@${ytId}]"
                fi
            else
                badExit "16" "Unable to isolate channel ID for [${sourceUrl}]"
            fi
        fi
        printOutput "2" " __          __              _             _ "
        printOutput "2" " \ \        / /             (_)           | |"
        printOutput "2" "  \ \  /\  / /_ _ _ __ _ __  _ _ __   __ _| |"
        printOutput "2" "   \ \/  \/ / _\` | '__| '_ \| | '_ \ / _\` | |"
        printOutput "2" "    \  /\  / (_| | |  | | | | | | | | (_| |_|"
        printOutput "2" "     \/  \/ \__,_|_|  |_| |_|_|_| |_|\__, (_)"
        printOutput "2" "                                      __/ |  "
        printOutput "2" "                                     |___/   "
        printOutput "1" "Channel usernames are less reliable than channel ID's, as usernames can be changed, but ID's can not."
        printOutput "1" "To have this source indexed, please replace your source URL:"
        printOutput "1" "  ${sourceUrl}"
        printOutput "1" "with its channel ID URL:"
        printOutput "1" "  https://www.youtube.com/channel/${channelId}"
        printOutput "2" " "
        badExit "17" "Refusing to index source with a non-constant URL"
    elif [[ "${id:12:8}" == "watch?v=" ]]; then
        # It's a file ID
        badExit "18" "Found single file ID, please provide a channel or playlist"
    elif [[ "${id:12:7}" == "channel" ]]; then
        # It's a channel ID
        itemType="channel"
        channelId="${id:20:24}"
        printOutput "3" "Validated channel ID [${channelId}]"
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
        printOutput "3" "Validated playlist ID [${plId}]"
    fi
else
    badExit "19" "Unable to parse input [${id}]"
fi

# If there is no sqlite db, create one
sqliteDb="${realPath%/*}/.${scriptName}.db"

if ! [[ -e "${sqliteDb}" ]]; then
    printOutput "3" "############### Initializing database #################"
    startTime="$(($(date +%s%N)/1000000))"
    newDb="true"
    sqlite3 "${sqliteDb}" "CREATE TABLE files( \
    ID INTEGER PRIMARY KEY AUTOINCREMENT, \
    YTID TEXT, \
    TITLE TEXT, \
    TIMESTAMP INTEGER, \
    THUMBNAIL TEXT, \
    DESC TEXT, \
    TYPE TEXT, \
    STATUS TEXT, \
    ERROR TEXT, \
    PATH TEXT, \
    DURATION INTERGER, \
    SB_AVAILABLE TEXT, \
    UPDATED INTEGER);"
    printOutput "3" "Main database initialized"

    sqlite3 "${sqliteDb}" "CREATE TABLE podcast_info( \
    ID INTEGER PRIMARY KEY AUTOINCREMENT, \
    TITLE TEXT, \
    DESC TEXT, \
    IMAGE TEXT, \
    UPDATED INTEGER);"
    printOutput "3" "Information table initialized"
    
    sqlite3 "${sqliteDb}" "CREATE TABLE error_log( \
    ID INTEGER PRIMARY KEY AUTOINCREMENT, \
    TIME TEXT, \
    RESULT TEXT, \
    COMMAND TEXT, \
    OUTPUT TEXT);"
    printOutput "3" "Error log initialized"
    
    printOutput "3" "Database initialization complete [Took $(timeDiff "${startTime}")]"
fi

# If we're dealing with a new database, get our playlist/channel info
if [[ "${newDb}" == "true" ]]; then
    printOutput "3" "########### Initializing channel information ##########"
    startTime="$(($(date +%s%N)/1000000))"
    if [[ "${itemType}" == "channel" ]]; then
        # API call
        printOutput "5" "Calling API for channel info [${channelId}]"
        ytApiCall "channels?id=${channelId}&part=snippet,statistics,brandingSettings"
    elif [[ "${itemType}" == "playlist" ]]; then
        # API call
        printOutput "5" "Calling API for playlist info [${plId}]"
        ytApiCall "playlists?part=snippet&id=${plId}"
    fi
    apiResults="$(yq -p json ".pageInfo.totalResults" <<<"${curlOutput}")"

    # Validate it
    if [[ -z "${apiResults}" ]]; then
        badExit "20" "No data provided to validate integer"
    elif [[ "${apiResults}" =~ ^[0-9]+$ ]]; then
        # Expected outcome
        true
    elif ! [[ "${apiResults}" =~ ^[0-9]+$ ]]; then
        badExit "21" "Data [${apiResults}] failed to validate as an integer"
    else
        badExit "22" "Impossible condition"
    fi

    if [[ "${apiResults}" -eq "0" ]]; then
        badExit "23" "API lookup for channel info returned zero results"
    fi

    # Get the channel name
    podName="$(yq -p json ".items[0].snippet.title" <<<"${curlOutput}")"
    # Validate it
    if [[ -z "${podName}" ]]; then
        badExit "24" "No channel name returned from API lookup for channel ID [${channelId}]"
    fi
    printOutput "5" "Channel name [${podName}]"
    
    # Get the channel description
    podDesc="$(yq -p json ".items[0].snippet.description" <<<"${curlOutput}")"
    if [[ -z "${podDesc}" || "${podDesc}" == "null" ]]; then
        # No channel description set
        printOutput "5" "No channel description set"
        podDesc="${sourceUrl}"
    else
        printOutput "5" "Channel description found [${#podDesc} characters]"
        podDesc="${podDesc}${lineBreak}-----${lineBreak}${sourceUrl}"
    fi
    
    # Get the channel image URL
    podImage="$(yq -p json ".items[0].snippet.thumbnails | to_entries | sort_by(.value.height) | reverse | .0 | .value.url" <<<"${curlOutput}")"
    printOutput "5" "Channel image URL [${podImage}]"
    
    # Store them in the database
    if sqDb "INSERT INTO podcast_info (TITLE, UPDATED) VALUES ('${podName//\'/\'\'}', $(date +%s));"; then
        printOutput "4" "Successfully initailized source in database"
    else
        badExit "25" "Failed to initialize source in database"
    fi
    if sqDb "UPDATE podcast_info SET DESC = '${podDesc//\'/\'\'}', UPDATED = $(date +%s);"; then
        printOutput "4" "Successfully updated description in database"
    else
        badExit "26" "Failed to update description in database"
    fi
    if sqDb "UPDATE podcast_info SET IMAGE = '${podImage//\'/\'\'}', UPDATED = $(date +%s);"; then
        printOutput "4" "Successfully updated image in database"
    else
        badExit "27" "Failed to update image in database"
    fi
    printOutput "3" "Channel information successfully initailized [Took $(timeDiff "${startTime}")]"
else
    dbCount="$(sqDb "SELECT COUNT(1) FROM podcast_info;")"
    if [[ "${dbCount}" -ne "1" ]]; then
        badExit "28" "Found [${dbCount}] source items in podcast_info table -- Database corruption"
    fi
    podName="$(sqDb "SELECT TITLE FROM podcast_info;")"
    podDesc="$(sqDb "SELECT DESC FROM podcast_info;")"
    podImage="$(sqDb "SELECT IMAGE FROM podcast_info;")"
fi

# Make sure we have a valid workDir
workDir="${workDir%/}/${podName//[^a-zA-Z0-9._-]/_}"
printOutput "5" "Setting work directory to [${workDir}]"
if ! [[ -d "${workDir}" ]]; then
    if mkdir -p "${workDir}"; then
        printOutput "5" "Workdir [${workDir}] created"
        callCurlDownload "${podImage}" "${workDir}/cover.jpg"
    else
        badExit "29" "Failed to create work directory [${workDir}]"
    fi
else
    printOutput "5" "Verified work directory [${workDir}]"
fi

# Get the list of file ID's we're working with from the source URL
printOutput "3" "################# Retrieving file ID's ################"
startTime="$(($(date +%s%N)/1000000))"
if ! readarray -t vidIds < <(yt-dlp --flat-playlist --no-warnings --print "%(id)s" "${sourceUrl}" 2>&1); then
    badExit "30" "Failed to pull file ID list for source URL [${sourceUrl}]"
else
    printOutput "3" "Pulled [${#vidIds[@]}] file ID's from source [Took $(timeDiff "${startTime}")]"
fi

# Number them
printOutput "3" "############## Assigning episode numbers ##############"
startTime="$(($(date +%s%N)/1000000))"
declare -A epNum
epNumDigit="${#vidIds[@]}"
for ytId in "${vidIds[@]}"; do
    epNum["_${ytId}"]="${epNumDigit}"
    (( epNumDigit-- ))
done
printOutput "3" "Done [Took $(timeDiff "${startTime}")]"

if [[ "${keepLimit}" -ne "0" ]]; then
    currentPos="0"
fi

printOutput "3" "################# Processing file ID's ################"
startTime="$(($(date +%s%N)/1000000))"
downloadQueue="0"
for ytId in "${vidIds[@]}"; do
    (( currentPos++ ))
    # Check and see if the file ID is already in the database or not
    dbCount="$(sqDb "SELECT COUNT(1) FROM files WHERE YTID = '${ytId//\'/\'\'}';")"
    if [[ "${dbCount}" -eq "0" ]]; then
        printOutput "3" "Processing file ID [${ytId}]"
        # It is not, do we need to worry about skipping it?
        if [[ "${keepLimit}" -ne "0" && "${downloadQueue}" -ge "${keepLimit}" ]]; then
            printOutput "4" "Skipping file ID [${ytId}] in position [${currentPos}] given limit of [${keepLimit}] files to keep"
            # Add it to the database as a skipped item
            if sqDb "INSERT INTO files (YTID, STATUS, ERROR, UPDATED) VALUES ('${ytId//\'/\'\'}', 'skipped', 'Skipping file ID given limit of [${keepLimit}] files to keep', $(date +%s));"; then
                printOutput "5" "Added file ID [${ytId}] to database"
            else
                badExit "31" "Failed to add file ID [${ytId}] to database"
            fi
            continue
        fi
        # If we've gotten this far, we can keep it, add it to the database
        # Call the YouTube Data API for info on the video
        unset dbCount vidTitle vidTitleClean channelId uploadDate uploadEpoch uploadYear vidDesc vidType vidStatus vidError sponsorCurl
        # Get the video info
        printOutput "5" "Calling API for video info [${ytId}]"
        ytApiCall "videos?id=${ytId}&part=snippet,liveStreamingDetails"
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
            badExit "32" "Impossible condition"
        fi
        if [[ "${apiResults}" -eq "0" ]]; then
            printOutput "1" "file ID [${ytId}] API lookup failed"
            continue
        elif [[ "${apiResults}" -eq "1" ]]; then
            # Get the video title
            vidTitle="$(yq -p json ".items[0].snippet.title" <<<"${curlOutput}")"
            # Get the video description
            # Blank if none set
            vidDesc="$(yq -p json ".items[0].snippet.description" <<<"${curlOutput}")"
            # Get the upload date and time
            uploadDate="$(yq -p json ".items[0].snippet.publishedAt" <<<"${curlOutput}")"
            # Get the video type (Check to see if it's a live broadcast)
            vidType="$(yq -p json ".items[0].snippet.liveBroadcastContent" <<<"${curlOutput}")"
            # Get the broadcast start time (Will only return value if it's a live broadcast)
            broadcastStart="$(yq -p json ".items[0].liveStreamingDetails.actualStartTime" <<<"${curlOutput}")"
            # Get the maxres thumbnail URL
            thumbUrl="$(yq -p json ".items[0].snippet.thumbnails | to_entries | .[-1].value.url" <<<"${curlOutput}")"
        else
            badExit "33" "Impossible condition"
        fi
        
        # Get the video title
        if [[ -z "${vidTitle}" ]]; then
            printOutput "1" "File ID [${ytId}] API lookup returned blank result for title"
            continue
        fi
        printOutput "5" "Video title [${vidTitle}]"
        # Put it in the database
        if sqDb "INSERT INTO files (YTID, TITLE, UPDATED) VALUES ('${ytId//\'/\'\'}', '${vidTitle//\'/\'\'}', $(date +%s));"; then
            printOutput "5" "Added file ID [${ytId}] with title [${vidTitle}] to database"
        else
            badExit "34" "Failed to add file ID [${ytId}] with title [${vidTitle}] to database"
        fi
        
        # Get the upload timestamp
        if [[ -z "${uploadDate}" ]]; then
            printOutput "1" "Upload date lookup failed for video [${ytId}]"
            return 1
        fi
        # Convert the date to a Unix timestamp
        uploadEpoch="$(date --date="${uploadDate}" "+%s")"
        if ! [[ "${uploadEpoch}" =~ ^[0-9]+$ ]]; then
            printOutput "1" "Unable to convert upload date [${uploadDate}] to unix epoch timestamp [${uploadEpoch}]"
            return 1
        fi
        printOutput "5" "Upload timestamp [${uploadEpoch}]"
        # Put it in the database
        if sqDb "UPDATE files SET TIMESTAMP = ${uploadEpoch}, UPDATED = $(date +%s) WHERE YTID = '${ytId//\'/\'\'}';"; then
            printOutput "5" "Updated epoch timestamp [${uploadEpoch}] for file ID [${ytId}] in database"
        else
            badExit "35" "Failed to update epoch timestamp [${uploadEpoch}] for file ID [${ytId}] in database"
        fi
        
        # Get the video thumbnail
        printOutput "5" "Thumbnail URL [${thumbUrl}]"
        # Put it in the database
        if sqDb "UPDATE files SET THUMBNAIL = '${thumbUrl//\'/\'\'}', UPDATED = $(date +%s) WHERE YTID = '${ytId//\'/\'\'}';"; then
            printOutput "5" "Updated thumbnail URL [${thumbUrl}] for file ID [${ytId}] in database"
        else
            badExit "36" "Failed to update thumbnail URL [${thumbUrl}] for file ID [${ytId}] in database"
        fi
        
        # Get the video description
        if [[ "${vidDesc}" == " " ]]; then
            unset vidDesc
        fi
        if [[ -z "${vidDesc}" ]]; then
            printOutput "5" "No video description"
            vidDesc="https://www.youtube.com/watch?v=${ytId}"
        else
            printOutput "5" "Video description present [${#vidDesc} characters]"
            vidDesc="${vidDesc}${lineBreak}-----${lineBreak}https://www.youtube.com/watch?v=${ytId}"
        fi
        # Put it in the database
        if sqDb "UPDATE files SET DESC = '${vidDesc//\'/\'\'}', UPDATED = $(date +%s) WHERE YTID = '${ytId//\'/\'\'}';"; then
            printOutput "5" "Updated description [${#vidDesc} characters] for file ID [${ytId}] in database"
        else
            badExit "37" "Failed to update description [${#vidDesc} characters] for file ID [${ytId}] in database"
        fi

        # Get the video type (Regular / Short / Live)
        if [[ -z "${vidType}" ]]; then
            printOutput "1" "Video type lookup for file ID [${ytId}] returned blank result"
            continue
        elif [[ "${vidType}" == "none" || "${vidType}" == "not_live" || "${vidType}" == "was_live" ]]; then
            # Not currently live
            # Check to see if it's a previous broadcast
            if [[ -z "${broadcastStart}" ]]; then
                # This should not be blank, it should be 'null' or a date/time
                printOutput "1" "Broadcast start time lookup for file ID [${ytId}] returned blank result [${broadcastStart}]"
                continue
            elif [[ "${broadcastStart}" == "null" || "${vidType}" == "not_live" ]]; then
                # It doesn't have one. Must be a short, or a regular video.
                # Use our bullshit to find out
                httpCode="$(curl -m 15 -s -I -o /dev/null -w "%{http_code}" "https://www.youtube.com/shorts/${ytId}")"
                if [[ "${httpCode}" == "000" ]]; then
                    # We're being throttled
                    printOutput "2" "Throttling detected"
                    randomSleep "5" "15"
                    httpCode="$(curl -m 15 -s -I -o /dev/null -w "%{http_code}" "https://www.youtube.com/shorts/${ytId}")"
                fi
                if [[ -z "${httpCode}" ]]; then
                    printOutput "1" "Curl lookup to determine video type returned blank result [${httpCode}]"
                    continue
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
                    printOutput "1" "Curl lookup returned HTTP code 404 for file ID [${ytId}]"
                    continue
                else
                    printOutput "1" "Curl lookup to determine file ID [${ytId}] type returned unexpected result [${httpCode}]"
                    continue
                fi
            elif [[ "${broadcastStart}" =~ ^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$ || "${vidType}" == "was_live" ]]; then
                printOutput "4" "file ID [${ytId}] detected to be a past live broadcast"
                vidType="waslive"
            else
                printOutput "Broadcast start time lookup returned unexpected result [${broadcastStart}]"
                continue
            fi
        elif [[ "${vidType}" == "live" || "${vidType}" == "is_live" || "${vidType}" == "upcoming" ]]; then
            # Currently, or going to be, live
            printOutput "2" "file ID [${ytId}] detected to be a live broadcast"
            vidType="live"
        else
            printOutput "1" "file ID [${ytId}] lookup video type returned invalid result [${vidType}]"
            continue
        fi
        printOutput "5" "Video type [${vidType}]"
        # Put it in the database
        if sqDb "UPDATE files SET TYPE = '${vidType//\'/\'\'}', UPDATED = $(date +%s) WHERE YTID = '${ytId//\'/\'\'}';"; then
            printOutput "5" "Updated video type [${vidType}] for file ID [${ytId}] in database"
        else
            badExit "38" "Failed to update video type [${vidType}] for file ID [${ytId}] in database"
        fi
        # If it's not a 'normal' video, we don't want it
        if ! [[ "${vidType}" == "normal" ]]; then
            # Put it in the database
            if sqDb "UPDATE files SET STATUS = 'skipped', UPDATED = $(date +%s) WHERE YTID = '${ytId//\'/\'\'}';"; then
                printOutput "5" "Updated video status to [skipped] for file ID [${ytId}] in database"
            else
                badExit "39" "Failed to update video status to [skipped] for file ID [${ytId}] in database"
            fi
            if sqDb "UPDATE files SET ERROR = 'Skipping unwanted video type [${vidType//\'/\'\'}]', UPDATED = $(date +%s) WHERE YTID = '${ytId//\'/\'\'}';"; then
                printOutput "5" "Updated video error for file ID [${ytId}] in database"
            else
                badExit "40" "Failed to update video error for file ID [${ytId}] in database"
            fi
            printOutput "2" "Skipping video type [${vidType}] for file ID [${ytId}]"
            continue
        fi
        
        # Set our path
        filePath="${workDir}/${uploadEpoch}_${ytId}.mp3"
        # Put it in the database
        if sqDb "UPDATE files SET PATH = '${filePath//\'/\'\'}', UPDATED = $(date +%s) WHERE YTID = '${ytId//\'/\'\'}';"; then
            printOutput "5" "Updated file path [${filePath}] for file ID [${ytId}] in database"
        else
            badExit "41" "Failed to update file path [${filePath}] for file ID [${ytId}] in database"
        fi
        
        # Our status will depend on our SponsorBlock requirements, so let's check that first
        # TODO: Standardize the ${requireSponsorBlock} in the config check
        if [[ "${requireSponsorBlock}" == "true" ]]; then
            # It's required
            # Is SponsorBlock data available for the video?
            printOutput "5" "Calling SponsorBlock API for file ID [${ytId}]"
            sponsorApiCall "searchSegments?videoID=${ytId}"
            if [[ "${curlOutput}" == "Not Found" ]]; then
                # It's not available
                printOutput "5" "No SponsorBlock data available for video"
                fileStatus="sb_wait"
                sponsorblockAvailable="Not found [$(date)]"
                vidError="SponsorBlock data required, but not available"
            else
                printOutput "5" "SponsorBlock data found for video"
                fileStatus="queued"
                (( downloadQueue++ ))
                sponsorblockAvailable="Found [$(date)]"
            fi
            # Update the SponsorBlock availability
            if sqDb "UPDATE files SET SB_AVAILABLE = '${sponsorblockAvailable//\'/\'\'}', UPDATED = '$(date +%s)' WHERE YTID = '${ytId//\'/\'\'}';"; then
                printOutput "5" "Updated SponsorBlock availability for file ID [${ytId}]"
            else
                printOutput "1" "Failed to update SponsorBlock availability for file ID [${ytId}]"
            fi
        else
            # It's not required
            fileStatus="queued"
            (( downloadQueue++ ))
        fi

        # Update the item's status
        if sqDb "UPDATE files SET STATUS = '${fileStatus//\'/\'\'}', UPDATED = '$(date +%s)' WHERE YTID = '${ytId//\'/\'\'}';"; then
            printOutput "5" "Updated status to [${fileStatus}] for file ID [${ytId}]"
        else
            printOutput "1" "Failed to update status to [${fileStatus}] for file ID [${ytId}]"
        fi

        # Update the error, if needed
        if [[ -n "${vidError}" ]]; then
            # If we have a "NULL", the null it
            if [[ "${vidError,,}" == "null" ]]; then
                if sqDb "UPDATE files SET ERROR = null, UPDATED = '$(date +%s)' WHERE YTID = '${ytId//\'/\'\'}';"; then
                    printOutput "5" "Removed error for file ID [${ytId}]"
                else
                    printOutput "1" "Failed to remove error for file ID [${ytId}]"
                fi
            else
                if sqDb "UPDATE files SET ERROR = '${vidError//\'/\'\'}', UPDATED = '$(date +%s)' WHERE YTID = '${ytId//\'/\'\'}';"; then
                    printOutput "5" "Updated error for file ID [${ytId}]"
                else
                    printOutput "1" "Failed to update error for file ID [${ytId}]"
                fi
            fi
        fi
    elif [[ "${dbCount}" -eq "1" ]]; then
        # It is, do we need to worry about purging it?
        if [[ "${keepLimit}" -ne "0" && "${currentPos}" -gt "${keepLimit}" ]]; then
            # Yes, check and see if it's been purged already
            fileStatus="$(sqDb "SELECT STATUS FROM files WHERE YTID = '${ytId//\'/\'\'}';")"
            if [[ "${fileStatus}" == "downloaded" || "${fileStatus}" == "queued" || "${fileStatus}" == "sb_wait" ]]; then
                printOutput "3" "Processing file ID [${ytId}]"
                # It's currently set to downlaoded or queued (sb_wait, or regular queued).
                if [[ "${fileStatus}" == "downloaded" ]]; then
                    # Get the file path
                    filePath="$(sqDb "SELECT PATH FROM files WHERE YTID = '${ytId//\'/\'\'}';")"
                    # Remove it
                    if rm -f "${filePath}"; then
                        printOutput "3" "Removed expired file ID [${ytId}]"
                        rm -f "${filePath%mp3}jpg"
                    else
                        printOutput "1" "Failed to remove expired file ID [${ytId}]"
                        continue
                    fi
                fi
                # Update the database status
                if sqDb "UPDATE files SET STATUS = 'purged', ERROR = NULL, UPDATED = '$(date +%s)' WHERE YTID = '${ytId//\'/\'\'}';"; then
                    printOutput "5" "Updated database entry for file ID [${ytId}]"
                else
                    printOutput "1" "Failed to update database entry for file ID [${ytId}]"
                fi
            fi
        else
            printOutput "3" "Processing file ID [${ytId}]"
            # No, was it previously skipped due to waiting on SponsorBlock availability?
            fileStatus="$(sqDb "SELECT STATUS FROM files WHERE YTID = '${ytId//\'/\'\'}';")"
            if [[ "${fileStatus}" == "sb_wait" ]]; then
                # Yes, let's check and see if it has SponsorBlock availability now
                printOutput "5" "Calling SponsorBlock API for file ID [${ytId}]"
                sponsorApiCall "searchSegments?videoID=${ytId}"
                if [[ "${curlOutput}" == "Not Found" ]]; then
                    # It's not available
                    printOutput "5" "No SponsorBlock data available for video"
                    sponsorblockAvailable="Not found [$(date)]"
                    vidError="SponsorBlock data required, but not available"
                else
                    # It is available
                    printOutput "5" "SponsorBlock data found for video"
                    sponsorblockAvailable="Found [$(date)]"
                    # Mark it as queued
                    if sqDb "UPDATE files SET STATUS = 'queued', UPDATED = '$(date +%s)' WHERE YTID = '${ytId//\'/\'\'}';"; then
                        printOutput "5" "Updated status to [queued] for file ID [${ytId}]"
                    else
                        printOutput "1" "Failed to update status to [queued] for file ID [${ytId}]"
                    fi
                    (( downloadQueue++ ))
                fi
                # Update the SponsorBlock availability
                if sqDb "UPDATE files SET SB_AVAILABLE = '${sponsorblockAvailable//\'/\'\'}', UPDATED = '$(date +%s)' WHERE YTID = '${ytId//\'/\'\'}';"; then
                    printOutput "5" "Updated SponsorBlock availability for file ID [${ytId}]"
                else
                    printOutput "1" "Failed to update SponsorBlock availability for file ID [${ytId}]"
                fi
            fi
        fi
    else
        printOutput "1" "Unexpected output from sqlite [${dbCount}]"
    fi
done
printOutput "3" "Done [Took $(timeDiff "${startTime}")]"

if [[ "${requireSponsorBlock}" == "true" ]]; then
    dlpOpts+=("--sponsorblock-remove ${sponsorBlockCats}")
fi

# Get a queue list
readarray -t downloadQueue < <(sqDb "SELECT YTID FROM files WHERE STATUS = 'queued' ORDER BY TIMESTAMP ASC;")
n="0"
printOutput "3" "############# Processing queued downloads #############"
for ytId in "${downloadQueue[@]}"; do
    (( n++ ))
    printOutput "3" "Downloading video ID [${ytId}] [Item ${n} of ${#downloadQueue[@]}]"
    # Get the file path it should be written to
    filePath="$(sqDb "SELECT PATH FROM files WHERE YTID = '${ytId//\'/\'\'}';")"
    startTime="$(($(date +%s%N)/1000000))"
    printOutput "5" "Issuing yt-dlp call [yt-dlp -vU ${dlpOpts[*]} --sleep-requests 1.25 -f bestaudio --extract-audio --audio-quality 0 --audio-format mp3 --no-warnings --embed-metadata --embed-thumbnail -o \"${filePath}\" \"https://www.youtube.com/watch?v=${ytId}\"]"
    while read -r z; do
        dlpOutput+=("${z}")
        if [[ "${z}" =~ ^"ERROR: ".*$ ]]; then
            dlpError="${z}"
        fi
    done < <(yt-dlp -vU ${dlpOpts[*]} --sleep-requests 1.25 -f bestaudio --extract-audio --audio-quality 0 --audio-format mp3 --no-warnings --embed-metadata --embed-thumbnail -o "${filePath}" "https://www.youtube.com/watch?v=${ytId}" 2>&1)
    endTime="$(($(date +%s%N)/1000000))"
    
    # Make sure the video downloaded
    if ! [[ -e "${filePath}" ]]; then
        printOutput "1" "Download of file ID [${ytId}] failed"
        if [[ -n "${dlpError}" ]]; then
            printOutput "1" "Found yt-dlp error message [${dlpError}]"
        fi
        printOutput "1" "=========== Begin yt-dlp log ==========="
        for z in "${dlpOutput[@]}"; do
            printOutput "1" "${z}"
        done
        printOutput "1" "============ End yt-dlp log ============"
        printOutput "1" "Skipping file ID [${ytId}]"
        if ! sqDb "UPDATE files SET STATUS = 'failed', UPDATED = '$(date +%s)' WHERE YTID = '${ytId//\'/\'\'}';"; then
            badExit "42" "Unable to update status to [failed] for file ID [${ytId}]"
        fi
        if [[ "${dlpError}" == "ERROR: [youtube] ${ytId}: Join this channel from your computer or Android app to get access to members-only content like this video." ]]; then
            # It's a members-only video. Mark it as 'skipped' rather than 'failed'.
            if ! sqDb "UPDATE files SET TYPE = 'members_only', STATUS = 'skipped', ERROR = 'Video is members only', UPDATED = '$(date +%s)' WHERE YTID = '${ytId//\'/\'\'}';"; then
                badExit "43" "Unable to update status to [skipped] due to being a members only video for file ID [${ytId}]"
            fi
        elif [[ "${dlpError}" == "ERROR: [youtube] ${ytId}: This live stream recording is not available." ]]; then
            # It's a previous live broadcast whose recording is not (and won't) be available
            if ! sqDb "UPDATE files SET TYPE = 'hidden_broadcast', STATUS = 'skipped', ERROR = 'Video is a previous live broadcast with unavailable stream', UPDATED = '$(date +%s)' WHERE YTID = '${ytId//\'/\'\'}';"; then
                badExit "44" "Unable to update status to [skipped] due to being a live broadcast with unavailable stream video for file ID [${ytId}]"
            fi
        else
            # Failed for some other reason
            if ! sqDb "UPDATE files SET STATUS = 'failed', ERROR = '${dlpOutput[*]//\'/\'\'}', UPDATED = '$(date +%s)' WHERE YTID = '${ytId//\'/\'\'}';"; then
                badExit "45" "Unable to update status to [failed] for file ID [${ytId}]"
            fi
        fi
    else
        printOutput "3" "File downloaded [$(timeDiff "${startTime}" "${endTime}")]"
        if ! sqDb "UPDATE files SET STATUS = 'downloaded', ERROR = null, UPDATED = '$(date +%s)' WHERE YTID = '${ytId//\'/\'\'}';"; then
            badExit "46" "Unable to update status to [downloaded] for file ID [${ytId}]"
        fi
        # Grab the thumbnail
        thumbUrl="$(sqDb "SELECT THUMBNAIL FROM files WHERE YTID = '${ytId//\'/\'\'}';")"
        # Make sure it's not blank
        if [[ -z "${thumbUrl}" ]]; then
            badExit "47" "Retrieved blank thumbnail URL for video ID [${ytId}]"
        fi
        callCurlDownload "${thumbUrl}" "${filePath%.mp3}.jpg"
        
        # Get the duration of the file in total number of seconds
        fileDuration="$(ffprobe -i "${filePath}" -show_entries format=duration -v quiet -of csv=p=0)"
        fileDuration="${fileDuration%\.*}"
        if ! [[ "${fileDuration}" =~ ^[0-9]+$ ]]; then
            printOutput "1" "Invalid file duration [${fileDuration}] for file [${filePath}] -- Skipping"
            continue
        else
            printOutput "4" "Found duration [${fileDuration}]"
            if ! sqDb "UPDATE files SET DURATION = ${fileDuration}, UPDATED = '$(date +%s)' WHERE YTID = '${ytId//\'/\'\'}';"; then
                badExit "48" "Unable to update duration to [${fileDuration}] for file ID [${ytId}]"
            fi
        fi
    fi
    # Throttle if it's not the last item
    if [[ "${n}" -lt "${#downloadQueue[@]}" ]]; then
        throttleDlp
    fi
done

# Global variables
podcastArtist="${podName}"
podcastTitle="${podcastArtist}"
podcastUrl="${sourceUrl}"
podcastTagline="${podDesc}"
podcastBaseUrl="${podcastBaseUrl%/}/${podName//[^a-zA-Z0-9._-]/_}/"
podcastGuid="$(generate_uuid "${podcastFeedUrl}")"
podcastSummary="${podcastTagline}"
podcastImage="${podcastBaseUrl%/}/cover.jpg"
podcastFeedUrl="${podcastBaseUrl%/}/feed.xml"

# XML header
xmlHeader="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<rss version=\"2.0\"
xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"
xmlns:podcast=\"https://podcastindex.org/namespace/1.0\"
xmlns:atom=\"http://www.w3.org/2005/Atom\"
xmlns:media=\"http://search.yahoo.com/mrss/\"
xmlns:content=\"http://purl.org/rss/1.0/modules/content/\">
<channel>
<atom:link href=\"${podcastFeedUrl}\" rel=\"self\" type=\"application/rss+xml\" />
<title>$(html_encode "${podcastTitle}")</title>
<link>${podcastUrl}</link>
<description><![CDATA[$(cdata_encode "${podcastSummary}")]]></description>
<generator>goose's bash script</generator>
<copyright>${podcastArtist}</copyright>
<language>${podcastLang}</language>
<media:thumbnail url=\"${podcastImage}\" />
<image>
<url>${podcastImage}</url>
<title>$(html_encode "${podcastTitle}")</title>
<link>${podcastUrl}</link>
</image>
<podcast:guid>${podcastGuid}</podcast:guid>
<podcast:locked>${podcastLock}</podcast:locked>
<itunes:title>$(html_encode "${podcastTitle}")</itunes:title>
<itunes:subtitle><![CDATA[$(cdata_encode "${podcastTagline}")]]></itunes:subtitle>
<itunes:author>$(html_encode "${podcastArtist}")</itunes:author>
<itunes:summary><![CDATA[$(cdata_encode "${podcastSummary}")]]></itunes:summary>
<itunes:block>${podcastBlock}</itunes:block>
<itunes:explicit>${podcastExplicit}</itunes:explicit>
<itunes:image href=\"${podcastImage}\" />
<itunes:category text=\"${podcastCategory}\" />
<itunes:type>episodic</itunes:type>
<lastBuildDate>$(date +"%a, %d %b %Y %H:%M:%S %z")</lastBuildDate>"
xmlFooter="</channel>
</rss>"

force="false"
if [[ "${1,,}" == "--force-generate" || "${1,,}" == "-f" ]]; then
    printOutput "2" "Forcing generation due to positional parameter"
    force="true"
fi
if [[ "${newDb}" == "true" ]]; then
    printOutput "2" "Forcing generation due to initiation of new database"
    force="true"
fi

# If the pre and post counts don't match, generate a new XML file
if [[ "${#downloadQueue[@]}" -ne "0" || "${force}" == "true" ]]; then
printOutput "3" "################# Generating XML feed #################"
    while read -r ytId; do
        printOutput "3" "Generating podcast item entry for file ID [${ytId}]"

        # Define episode specific variables:
        episodeTitle="$(sqDb "SELECT TITLE FROM files WHERE YTID = '${ytId//\'/\'\'}';")"
        #  episodeTitle="$(clean_lf "${episodeTitle}")"
        if [[ -z "${episodeTitle}" ]]; then
            printOutput "1" "Unable to retrieve episode title for file ID [${ytId}]"
            continue
        else
            printOutput "4" "Found episode title [${episodeTitle}]"
        fi

        episodeUrl="https://www.youtube.com/watch?v=${ytId}"
        if [[ -z "${episodeUrl}" ]]; then
            printOutput "1" "Unable to retrieve episode URL for file ID [${ytId}]"
            continue
        else
            printOutput "4" "Found episode URL [${episodeUrl}]"
        fi

        episodeNumber="${epNum[_${ytId}]}"
        if [[ -z "${episodeNumber}" ]]; then
            printOutput "1" "Unable to retrieve episode number for file ID [${ytId}]"
            continue
        else
            printOutput "4" "Found episode number [${episodeNumber}]"
        fi

        episodeDescription="$(sqDb "SELECT DESC FROM files WHERE YTID = '${ytId//\'/\'\'}';")"
        # episodeDescription="$(clean_lf "${episodeDescription}")"
        if [[ -z "${episodeDescription}" ]]; then
            printOutput "1" "Unable to retrieve episode description for file ID [${ytId}]"
            continue
        else
            printOutput "4" "Found episode description [${#episodeDescription} characters]"
        fi

        episodeFilePath="$(sqDb "SELECT PATH FROM files WHERE YTID = '${ytId//\'/\'\'}';")"
        # episodeFilePath="$(clean_lf "${episodeFilePath}")"
        if [[ -z "${episodeFilePath}" ]]; then
            printOutput "1" "Unable to retrieve episode file path for file ID [${ytId}]"
            continue
        else
            episodeImage="${episodeFilePath##*/}"
            episodeImage="${episodeImage%mp3}jpg"
            printOutput "4" "Found episode file path [${episodeFilePath}]"
        fi
        
        episodeFileSize="$(stat --format="%s" "${episodeFilePath}")"
        if [[ -z "${episodeFileSize}" ]]; then
            printOutput "1" "Unable to retrieve episodeFileSize for file ID [${ytId}]"
            continue
        else
            printOutput "4" "Found episode file size [${episodeFileSize} bytes]"
        fi

        episodeMimeType="$(mimetype --output-format %m "${episodeFilePath}")"
        if [[ -z "${episodeMimeType}" ]]; then
            printOutput "1" "Unable to retrieve episodeMimeType for file ID [${ytId}]"
            continue
        else
            printOutput "4" "Found episode MIME type [${episodeMimeType}]"
        fi

        episodeGuid="$(generate_uuid "${podcastBaseUrl%/}/${episodeFilePath}")"
        if [[ -z "${episodeGuid}" ]]; then
            printOutput "1" "Unable to generate GUID for file ID [${ytId}]"
            continue
        else
            printOutput "4" "Generated episode GUID [${episodeGuid}]"
        fi

        episodePublished="$(sqDb "SELECT TIMESTAMP FROM files WHERE YTID = '${ytId//\'/\'\'}';")"
        # episodePublished="$(clean_lf "${episodePublished}")"
        if [[ -z "${episodePublished}" ]]; then
            printOutput "1" "Unable to retrieve episodePublished for file ID [${ytId}]"
            continue
        else
            episodePublished="$(date -d "@${episodePublished}" +"%a, %d %b %Y %H:%M:%S %z")"
            printOutput "4" "Found publication date/time [${episodePublished}]"
        fi

        episodeDuration="$(sqDb "SELECT DURATION FROM files WHERE YTID = '${ytId//\'/\'\'}';")"
        if [[ -z "${episodeDuration}" ]]; then
            printOutput "1" "Unable to retrieve episodeDuration for file ID [${ytId}]"
            continue
        else
            # hours=$((episodeDuration / 3600))
            # minutes=$(( (episodeDuration % 3600) / 60 ))
            # seconds=$((episodeDuration % 60))
            # episodeDuration="$(printf "%02d:%02d:%02d\n" "${hours}" "${minutes}" "${seconds}")"
            printOutput "4" "Found episode duration [${episodeDuration}]"
        fi

        # For each file, generate an <item> tag
        unset arrStr
        arrStr="<item>"
        arrStr="${arrStr}$(printf "\r\n")<title>$(html_encode "${episodeTitle}")</title>"
        arrStr="${arrStr}$(printf "\r\n")<description><![CDATA[$(cdata_encode "${episodeDescription}")]]></description>"
        arrStr="${arrStr}$(printf "\r\n")<pubDate>${episodePublished}</pubDate>"
        arrStr="${arrStr}$(printf "\r\n")<guid isPermaLink=\"false\">${episodeGuid}</guid>"
        arrStr="${arrStr}$(printf "\r\n")<link>${episodeUrl}</link>"
        arrStr="${arrStr}$(printf "\r\n")<itunes:block>${podcastBlock}</itunes:block>"
        arrStr="${arrStr}$(printf "\r\n")<itunes:title>$(html_encode "${episodeTitle}")</itunes:title>"
        arrStr="${arrStr}$(printf "\r\n")<itunes:author>$(html_encode "${podcastArtist}")</itunes:author>"
        arrStr="${arrStr}$(printf "\r\n")<itunes:image href=\"${podcastBaseUrl%/}/$(rawurlencode "${episodeImage}")\" />"
        arrStr="${arrStr}$(printf "\r\n")<media:thumbnail url=\"${podcastBaseUrl%/}/$(rawurlencode "${episodeImage}")\" />"
        arrStr="${arrStr}$(printf "\r\n")<itunes:duration>${episodeDuration}</itunes:duration>"
        arrStr="${arrStr}$(printf "\r\n")<itunes:explicit>${podcastExplicit}</itunes:explicit>"
        arrStr="${arrStr}$(printf "\r\n")<itunes:episodeType>full</itunes:episodeType>"
        arrStr="${arrStr}$(printf "\r\n")<itunes:episode>${episodeNumber}</itunes:episode>"
        arrStr="${arrStr}$(printf "\r\n")<content:encoded><![CDATA[$(cdata_encode "${episodeDescription}")]]></content:encoded>"
        arrStr="${arrStr}$(printf "\r\n")<enclosure length=\"${episodeFileSize}\" type=\"${episodeMimeType}\" url=\"${podcastBaseUrl%/}/$(rawurlencode "${episodeFilePath##*/}")\" />"
        arrStr="${arrStr}$(printf "\r\n")</item>$(printf "\r\n")"
        itemArr+=("${arrStr}")
    done < <(sqDb "SELECT YTID FROM FILES WHERE STATUS = 'downloaded' ORDER BY TIMESTAMP DESC;")

    printOutput "3" "Processed ${#itemArr[@]} episodes"

    # Print the completed XML
    (
    echo "${xmlHeader}"
    echo "${itemArr[@]}"
    echo "${xmlFooter}"
    ) | xmllint --format - > "${workDir}/feed.xml"
    
    printOutput "3" "New feed successfully generated"
    
    if [[ "${newDb}" == "true" ]]; then
        generate_qr "${podcastFeedUrl}"
    fi
else
    printOutput "3" "No new episodes detected"
fi

cleanExit
