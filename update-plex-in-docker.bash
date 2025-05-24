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
# This script serves to update instaces of Plex running in docker containers. If you are using the official Plex image
# then updates are downloaded and installed within the container on each start, rather than by updating the image.
# This script works around that by using API calls, curl, and jq to parse the current version of a Plex server and
# compare it to the latest available versions offered on Plex's website.

#############################
##        Changelog        ##
#############################
# 2025-01-06
# Added Discord messaging (See updated .env file)
# Updated printOutput verbosity levels (See updated .env file)
# Updated some verbiage
# 2024-07-29
# Improved some wording
# 2024-01-27
# Remove codecs from inside the container (Removed from .env)
# Added support for ChuckPA's database repair tool
# Added support for when a container has multiple networks attached (Multiple IP addresses)
# Updated the logic for sending Telegram messages to make sure the bot can authenticate to each channel
# Added support for super groups, silent messages (See updated .env file)
# Added support for sending error messages via telegram (See updated .env file)
# Added a changelog message for when users update
# 2023-10-15
# Fixed the lockfile logic
# 2023-10-13
# Updated some spacing, and modified telegram send message command to allow for multiple channels
# Added a disclaimer for where to file issues above the "About" section
# 2023-05-25
# Added functionality to self determine container IP address
# Added config options for verbosity
# Both initiated via PR from @ndoty
# 2023-03-16
# Rewrite of old script, removal of old script, and initial commit of new script

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
depArr=("awk" "curl" "docker" "jq" "md5sum" "printf" "rm" "xmllint")
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
updateURL="https://raw.githubusercontent.com/goose-ws/bash-scripts/main/update-plex-in-docker.bash"
# For ease of printing messages
lineBreak=$'\n\n'

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
    printOutput "4" "Lockfile removed"
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
    printOutput "1" "${2}"
    exit "${1}"
fi
}

function cleanExit {
removeLock
exit 0
}

# Sends a message to Discord using a webhook URL
# Usage: sendDiscordMessage "Your message text here"
function sendDiscordMessage {
    local message="${1}" # Message to send (positional parameter #1)

    # Check if the Discord Webhook URL is configured
    if [[ -z "${discordWebhook}" ]]; then
        printOutput "1" "No Discord Webhook URL provided (discordWebhook variable not set)."
        return 1 # Return non-zero for error
    fi

    # Make sure the message is not blank
    if [[ -z "${message}" ]]; then
        printOutput "1" "No message passed to send to Discord."
        return 1
    fi

    # --- Construct the JSON payload ---
    # Basic method: Escape double quotes and backslashes within the message.
    # This might not cover all edge cases for complex messages.
    local escaped_message
    escaped_message=${message//\\/\\\\} # Escape backslashes first
    escaped_message=${escaped_message//\"/\\\"} # Escape double quotes
    local json_payload="{\"content\": \"${escaped_message}\"}"

    # --- OR: More robust method using jq (if available) ---
    # Uncomment the following lines and ensure 'jq' is installed if you prefer this.
    # if ! command -v jq &> /dev/null; then
    #     printOutput "1" "'jq' command not found, cannot safely construct JSON payload."
    #     # Fallback to basic method or return error
    #     # return 1
    # else
    #     # Use jq to safely create the JSON string
    #     json_payload=$(jq -n --arg msg "$message" '{content: $msg}')
    #     if [[ $? -ne 0 || -z "$json_payload" ]]; then
    #          printOutput "1" "Failed to construct JSON payload using jq."
    #          return 1
    #     fi
    # fi
    # --- End of jq method ---


    printOutput "5" "Attempting to send message to Discord."
    # Send the JSON payload using callCurlPost
    # Pass the webhook URL as ${1} and the JSON payload as ${2}
    callCurlPost "${discordWebhook}" "${json_payload}"
    local curl_exit_code=$? # Capture the exit code from callCurlPost

    if [[ "${curl_exit_code}" -ne "0" ]]; then
        printOutput "1" "Failed to send message to Discord via callCurlPost."
        return 1 # Propagate the error
    else
        printOutput "5" "Message potentially sent to Discord successfully."
        return 0 # Indicate success
    fi
}

# Performs a curl POST request with JSON data
# Usage: callCurlPost "URL" "JSON_DATA_STRING"
function callCurlPost {
    local url="${1}"      # URL to call should be ${1}
    local data="${2}"     # JSON data payload should be ${2}
    local curlOutput
    local curlExitCode

    # Check if URL is provided
    if [[ -z "${url}" ]]; then
        printOutput "1" "No input URL provided for POST."
        return 1
    fi

    # Check if data is provided (optional, but needed for Discord)
    if [[ -z "${data}" ]]; then
        printOutput "1" "No data payload provided for POST."
        return 1
    fi

    # Use -H to set Content-Type header
    # Use -d to send the data payload
    # Use --fail to make curl return non-zero on HTTP errors (4xx, 5xx)
    printOutput "5" "Issuing curl command: curl -skL --fail -X POST -H \"Content-Type: application/json\" -d <data> \"${url}\""
    # Note: We don't print the actual data here for brevity/security

    curlOutput="$(curl -skL --fail -X POST \
                      -H "Content-Type: application/json" \
                      -d "${data}" \
                      "${url}" 2>&1)"
    curlExitCode="${?}"

    if [[ "${curlExitCode}" -ne "0" ]]; then
        printOutput "1" "Curl returned non-zero exit code ${curlExitCode}."
        # Read and print each line of the output for better logging
        while IFS= read -r line; do
            # Avoid printing empty lines if the output ends with newlines
            [[ -n "$line" ]] && printOutput "1" "Output: ${line}"
        done <<< "${curlOutput}"
        return 1 # Return error
    fi

    printOutput "5" "Curl POST request successful."
    # Optionally print successful output if needed
    # printOutput "5" "Curl Output: ${curlOutput}"
    return 0 # Return success
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
        printOutput "4" "Telegram bot API key authenticated: $(jq -M -r ".result.username" <<<"${telegramOutput}")"
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
            elif [[ "$(jq -M -r ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
                printOutput "4" "Telegram channel authenticated: $(jq -M -r ".result.title" <<<"${telegramOutput}")"
                telegramOutput="$(curl -skL --data-urlencode "text=${1}" "https://api.telegram.org/bot${telegramBotId}/sendMessage?chat_id=${chanId}&parse_mode=html" 2>&1)"
                curlExitCode="${?}"
                if [[ "${curlExitCode}" -ne "0" ]]; then
                    printOutput "1" "Curl to Telegram returned a non-zero exit code: ${curlExitCode}"
                elif [[ -z "${telegramOutput}" ]]; then
                    printOutput "1" "Curl to Telegram to send message returned an empty string"
                else
                    printOutput "5" "Curl exit code and null output checks passed"
                    # Check to make sure Telegram returned a true value for ok
                    if ! [[ "$(jq -M -r ".ok" <<<"${telegramOutput}")" == "true" ]]; then
                        printOutput "1" "Failed to send Telegram message:"
                        printOutput "1" ""
                        while read -r i; do
                            printOutput "1" "${i}"
                        done < <(jq . <<<"${telegramOutput}")
                        printOutput "1" ""
                    else
                        printOutput "3" "Telegram message sent successfully"
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
    while read -r i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    badExit "1" "Bad curl output"
fi
}

#############################
##     Unique Functions    ##
#############################
function getNowPlaying {
# TODO: Replace this with a 'yq' function
nowPlaying="$(curl -skL -m 15 "${plexAdd}/status/sessions?X-Plex-Token=${plexAccessToken}" | grep -Eo "size=\"[[:digit:]]+\"")"
nowPlaying="${nowPlaying#*size=\"}"
nowPlaying="${nowPlaying%%\"*}"
printOutput "3" "Now playing count: ${nowPlaying}"
}

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
                printOutput "0" "Update complete"
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

                printOutput "0"  "Changelog:"
                for i in "${changelogArr[@]}"; do
                    printOutput "0"  "${i}"
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
if ! [[ "${outputVerbosity}" =~ ^[1-5]$ ]]; then
    echo "Invalid output verbosity defined. Assuming level 1 (Errors only)"
    outputVerbosity="1"
fi

# Config specific checks
if ! [[ "${repairDatabase,,}" =~ ^(yes|no|true|false)$ ]]; then
    echo "Option to run database repair tool not valid. Assuming no."
    repairDatabase="No"
fi
if [[ -z "${plexAccessToken}" ]]; then
    echo "Please specify a 'plexAccessToken=\"\"'"
    varFail="1"
fi
if [[ -z "${plexPort}" ]]; then
    echo "Please specify a 'plexPort=\"\"'"
    varFail="1"
elif ! [[ "${plexPort}" =~ ^[0-9]+$ ]]; then
    echo "Please specify a numerical 'plexPort=\"\"'"
    varFail="1"
elif ! [[ "${plexPort}" -ge "0" && "${plexPort}" -le "65535" ]]; then
    echo "Please specify a valid 'plexPort=\"\"'"
    varFail="1"
fi
if [[ -z "${plexScheme}" ]]; then
    echo "Please specify a 'plexScheme=\"\"'"
    varFail="1"
elif ! [[ "${plexScheme}" =~ ^https?$ ]]; then
    echo "Please specify a valid 'plexScheme=\"\"'"
    varFail="1"
fi
if [[ -z "${containerName}" ]]; then
    echo "Please specify a 'containerName=\"\"'"
    varFail="1"
fi
if [[ -z "${plexVersion}" ]]; then
    echo "Please specify a 'plexVersion=\"\"'"
    varFail="1"
else
    if ! [[ "${plexVersion}" =~ (plexpass|beta|public) ]]; then
        echo "Please specify a valid 'plexVersion=\"\"'"
        varFail="1"
    fi
fi
# TODO: Automate this variable via 'uname'
if [[ -z "${hostOS}" ]]; then
    echo "Please specify a 'hostOS=\"\"'"
    varFail="1"
else
    case "${hostOS}" in
        "1") hostOS="Windows";;
        "2") hostOS="MacOS";;
        "3") hostOS="Linux";;
        "4") hostOS="FreeBSD";;
        "5") hostOS="nas";;
        "6") hostOS="Netgear";;
        "7") hostOS="QNAP";;
        "8") hostOS="unRAID";;
        "9") hostOS="Drobo";;
        "10") hostOS=" ASUSTOR";;
        "11") hostOS=" Seagate";;
        "12") hostOS=" Western Digital";;
        "13") hostOS=" Western Digital (OS 3)";;
        *) echo "Please specify a valid 'hostOS=\"\"'"; varFail="1";;
    esac
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
        printOutput "0" "A newer version is available"
        # If our ${TERM} is dumb, we're probably running via cron, and should push a message to Telegram, if allowed
        if [[ "${TERM,,}" == "dumb" ]]; then
            if [[ "${telegramErrorMessages}" =~ ^(yes|true)$ ]]; then
                sendTelegramMessage "[${0##*/}] An update is available" "${telegramErrorChannel}"
            fi
        fi
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

# If using docker, we should ensure we have permissions to do so
if ! docker version > /dev/null 2>&1; then
    badExit "6" "Do not appear to have permission to run on the docker socket (\`docker version\` returned non-zero exit code)"
fi

# Get the IP address of the Plex container
if [[ -z "${containerIp}" ]]; then
    printOutput "3" "Attempting to automatically determine container IP address"
    # Find the type of networking the container is using
    unset containerNetworking
    while read i; do
        if [[ -n "${i}" ]]; then
            containerNetworking+=("${i}")
        fi
    done < <(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "${containerName}")
    printOutput "4" "Container is utilizing ${#containerNetworking[@]} network type(s): ${containerNetworking[*]}"
    for i in "${containerNetworking[@]}"; do
        if [[ -z "${i}" ]]; then
            printOutput "3" "No network type defined. Checking to see if networking is through another container."
            # IP address returned blank. Is it being networked through another container?
            containerIp="$(docker inspect "${containerName}" | jq -M -r ".[].HostConfig.NetworkMode")"
            containerIp="${containerIp#\"}"
            containerIp="${containerIp%\"}"
            printOutput "4" "Network mode: ${containerIp%%:*}"
            if [[ "${containerIp%%:*}" == "container" ]]; then
                # Networking is being run through another container. So we need that container's IP address.
                printOutput "4" "Networking routed through another container. Retrieving IP address."
                containerIp="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${containerIp#container:}")"
            else
                printOutput "1" "Unable to determine networking type"
                unset containerIp
            fi
        elif [[ "${i}" == "host" ]]; then
            # Host networking, so we can probably use localhost
            printOutput "4" "Networking type: ${i}"
            containerIp="127.0.0.1"
        else
            # Something else. Let's see if we can get it via inspect.
            printOutput "4" "Other networking type: ${i}"
            containerIp="$(docker inspect "${containerName}" | jq -M -r ".[] | .NetworkSettings.Networks.${i}.IPAddress")"
        fi
        if [[ -z "${containerIp}" ]] || ! [[ "${containerIp}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
            printOutput "1" "Unable to determine IP address via networking mode: ${i}"
        else
            printOutput "3" "Container IP address: ${containerIp}"
            break
        fi
    done
    if [[ -z "${containerIp}" ]] || ! [[ "${containerIp}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
        badExit "7" "Unable to determine IP address"
    fi
fi

# Build our address
plexAdd="${plexScheme}://${containerIp}:${plexPort}"
printOutput "5" "Server address: ${plexAdd}"

# Make sure our server is reachable, and we can check our version
callCurl "${plexAdd}/servers?X-Plex-Token=${plexAccessToken}"
myVer="$(grep -Ev "^<\?xml" <<<"${curlOutput}" | grep -Eo "version=\"([[:alnum:]]|\.|-)+\"")"
myVer="${myVer#*version=\"}"
myVer="${myVer%%\"*}"
if [[ "${myVer}" == "null" ]] || [[ -z "${myVer}" ]]; then
    badExit "8" "Unable to parse local version"
else
    printOutput "3" "Detected local version: ${myVer}"
fi

# Make sure we can check the latest version
callCurl "https://plex.tv/api/downloads/1.json?channel=${plexVersion}"
currVer="$(jq ".computer.${hostOS}.version" <<<"${curlOutput}")"
currVer="${currVer#\"}"
currVer="${currVer%\"}"
if [[ "${currVer}" == "null" ]] || [[ -z "${currVer}" ]]; then
    badExit "9" "Unable to parse latest version"
else
    printOutput "3" "Detected current version: ${currVer}"
fi

if [[ "${myVer}" == "${currVer}" ]]; then
    printOutput "3" "Versions match, no update needed"
    cleanExit;
fi

# If we've gotten this far, version strings do not match
myVer2="${myVer%-*}"
myVer2="${myVer2//./}"
currVer2="${currVer%-*}"
currVer2="${currVer2//./}"
if [[ "${myVer2}" -gt "${currVer2}" ]]; then
    # We already have a version more recent than the current, probably a beta/Plex Pass version
    printOutput "3" "Local version newer than current stable version."
    cleanExit;
fi

# Is anyone playing anything?
getNowPlaying;

if [[ "${nowPlaying}" -ne "0" ]]; then
    # At least one person is watching something
    # We'll try again at the next cron run
    printOutput "3" "Detected ${nowPlaying} users currently using Plex"
    cleanExit;
fi

# Nobody is watching anything. Maybe someone was between episodes? Let's wait 1 minute and check.
printOutput "4" "Sleeping for 60 seconds before re-checking play status"
sleep 60

# Is anyone playing anything?
getNowPlaying;

if [[ "${nowPlaying}" -ne "0" ]]; then
    # At least one person is watching something
    # We'll try again at the next cron run
    printOutput "3" "Detected ${nowPlaying} users currently using Plex"
    cleanExit;
fi

# Nice, nobody's watching anything. 

# Are we allowed to run the DB repair tool?
if [[ "${repairDatabase,,}" =~ ^(yes|true)$ ]]; then
    printOutput "3" "Pulling newest copy of DB Repair Tool into container"
    if docker exec "${containerName}" curl -skL "https://raw.githubusercontent.com/ChuckPa/PlexDBRepair/master/DBRepair.sh" -o "/root/db_repair_new.sh" > /dev/null 2>&1; then
        toolVersion="$(docker exec "${containerName}" grep -m 1 "# Version:" "/root/db_repair_new.sh" 2>/dev/null | awk '{print $3}')"
        toolDate="$(docker exec "${containerName}" grep -m 1 "# Date:" "/root/db_repair_new.sh" 2>/dev/null | awk '{print $3}')"
        if [[ -n "${toolDate}" && -n "${toolVersion}" ]]; then
            printOutput "4" "Newest copy of repair tool pulled"
            printOutput "5" "Tool Version: ${toolVersion} | Tool Date: ${toolDate}"
            if docker exec "${containerName}" chmod +x "/root/db_repair_new.sh" > /dev/null 2>&1; then
                printOutput "5" "Tool set as executable successfully"
                if [[ -n "${telegramBotId}" && -n "${telegramChannelId[0]}" ]]; then
                    dockerHost="$(</etc/hostname)"
                    printOutput "4" "Got hostname: ${dockerHost}"
                    eventText="<b>Plex Server Update for ${dockerHost%%.*}</b>${lineBreak}Stopping Plex Media Server for database maintenance and repair, and server upgrade"
                    printOutput "4" "Telegram messaging enabled -- Passing message to function"
                    sendTelegramMessage "${eventText}"
                fi
                if [[ -n "${discordWebhook}" ]]; then
                    dockerHost="$(</etc/hostname)"
                    printOutput "4" "Got hostname: ${dockerHost}"
                    eventText="**Plex Server Update for ${dockerHost%%.*}**${lineBreak}Stopping Plex Media Server for database maintenance and repair, and server upgrade"
                    printOutput "4" "Discord messaging enabled -- Passing message to function"
                    sendDiscordMessage "${eventText}"
                fi
                printOutput "3" "Initiating database repair -- This may take some time"
                printOutput "4" "Begin repair tool output"
                printOutput "4" "============================"
                while read -r i; do
                    printOutput "4" "${i}"
                done < <(docker exec "${containerName}" /root/db_repair_new.sh stop check auto exit 2>&1)
                printOutput "4" "============================"
                printOutput "4" "End of repair tool output"
            else
                printOutput "1" "Unable to set tool as executable -- Skipping database repair"
            fi
        else
            printOutput "1" "Unable to validate tool version/date -- Skipping database repair"
        fi
    else
        printOutput "1" "Unable to pull newest copy of repair tool -- Skipping database repair"
    fi
else
	if [[ -n "${telegramBotId}" && -n "${telegramChannelId[0]}" ]]; then
		dockerHost="$(</etc/hostname)"
		printOutput "4" "Got hostname: ${dockerHost}"
		eventText="<b>Plex Server Update for ${dockerHost%%.*}</b>${lineBreak}Stopping Plex Media Server for server upgrade"
		printOutput "4" "Telegram messaging enabled -- Passing message to function"
		sendTelegramMessage "${eventText}"
	fi
    if [[ -n "${discordWebhook}" ]]; then
        dockerHost="$(</etc/hostname)"
        printOutput "4" "Got hostname: ${dockerHost}"
        eventText="**Plex Server Update for ${dockerHost%%.*}**${lineBreak}Stopping Plex Media Server for server upgrade"
        printOutput "4" "Discord messaging enabled -- Passing message to function"
        sendDiscordMessage "${eventText}"
    fi
fi

# Clean out the Codecs folder, because apparently that sometimes breaks things between upgrades if you don't
# https://old.reddit.com/r/PleX/comments/lzwkyc/eae_timeout/gq4xcat/
printOutput "2" "Cleaning out Codecs directory"
if docker exec "${containerName}" rm -rf "/config/Library/Application Support/Plex Media Server/Codecs" > /dev/null 2>&1; then
    printOutput "3" "Codecs directory cleared successfully"
else
    badExit "10" "Unable to clear Codecs directory"
fi

# Restart the Docker container.
printOutput "3" "Restarting container"
if docker restart "${containerName}" > /dev/null 2>&1; then
    printOutput "3" "Container restarted successfully"
else
    badExit "11" "Unable restart the container"
fi

if [[ -n "${telegramBotId}" && -n "${telegramChannelId[0]}" ]]; then
    dockerHost="$(</etc/hostname)"
    eventText="<b>Plex Server Update for ${dockerHost%%.*}</b>${lineBreak}Plex Media Server restarted for update from version <i>${myVer}</i> to version <i>${currVer}</i>"
    printOutput "4" "Got hostname: ${dockerHost}"
    printOutput "4" "Telegram messaging enabled -- Passing message to function"
    sendTelegramMessage "${eventText}"
fi
if [[ -n "${discordWebhook}" ]]; then
    dockerHost="$(</etc/hostname)"
    eventText="**Plex Server Update for ${dockerHost%%.*}**${lineBreak}Plex Media Server restarted for update from version *${myVer}* to version *${currVer}*"
    printOutput "4" "Got hostname: ${dockerHost}"
    printOutput "4" "Discord messaging enabled -- Passing message to function"
    sendDiscordMessage "${eventText}"
fi

#############################
##       End of file       ##
#############################
cleanExit
