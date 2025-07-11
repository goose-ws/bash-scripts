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
# Are you a person who sometimes has to manually import episodes because they don't yet have actual titles in
# their metadata, and their title shows as "TBA" in Sonarr? And then once you import the files, they live in
# your library under their "TBA" titles until you go through the effort of manually renaming them? Then perhaps
# this script is for you.

# The purpose of this script is to check for any files in your Sonarr library which have the title "TBA",
# and rename them to their actual name, if that metadata is available. It assumes you are using Sonarr in
# Docker, that the user running this script can access the Docker socket, and that you are using either the
# linuxserver/sonarr image or the hotio/sonarr image. This script is meant to be run on the bare metal of
# the system, not inside the docker container. This script works by:
# 1. Searching for any files that have TBA in the title
# 2. Finding the Series ID for that series in Sonarr
# 3. Preforming a metadata refresh for that series in Sonarr
# 4. Preforming a rename for that series in Sonarr
# I use this on an hourly cron script, which is probably fine for what I'm trying to accomplish.

# There are a few requirements for this script to work correctly. Firstly, it may help for you to set Sonarr
# to allow automatic import of files under their TBA title.
# This can be done under: Settings > Media Management > Episode Title Requires > (Only for Bulk Season Releases / Never)
# I use "Only for Bulk Season Releases". Either of these settings will allow Sonarr to import files if their
# title is TBA due to metadata not yet being updated for the episode.

#############################
##        Changelog        ##
#############################
# 2025-07-06
# Allow for Upper or Lowercase S and E.
# 2025-07-04
# Removed 'docker' from the dependency array, in addition to the previous edit
# 2025-05-24
# Removed the check for docker socket permission, if docker is not required
# Added support for Discord messages
# 2025-03-25
# Added a safety check to verify the file names match the S#E# pattern, as other formats (Daily shows)
# will not parse correctly. Added a TODO to address daily shows...eventually.
# 2024-12-12
# Small verbiage update
# 2024-11-18
# Small verbiage update
# 2024-08-15
# Updated the 'getContainerIp' function to handle networking types which have dashes in their name.
# While sonarr currently only returns JSON in API calls, I may still move away from 'jq' in the future,
# in favor of 'yq', which does not experience this dash-breaking behavior.
# 2024-07-24
# Removed the function to refresh Plex's metadata. Because Plex now has its own metadata service,
# it is no longer reliable to assume that if we successfully update metadata in Sonarr, we will
# also be able to update metadata in Plex. Instead, I have added a new standalone script to handle
# metadata refreshes within Plex, see 'plex-update-tba.bash' in the GitHub repositry.
# 2024-06-17
# Removed case sensitivity when detected the season and episode of a file
# Removed the use of egrep when obtaining the season and episode of a file
# 2024-06-16
# Added a safety check to validate the lookup of the file season/episode number
# 2024-06-07
# Fixed a typo breaking non-docker finds
# 2024-05-31
# Fixed a parameter expansion that caused titles to be incorrectly considered false positives
# 2024-05-28
# Improved the logic for finding TBA/TBD files, so that TRaSH's naming scheme is no longer needed
# Cleaned up and consolidated a lot of redundant/excessive verbose logging
# Removed some old unused variables
# Changed the way we check for files on the file system to be more sane
# 2024-05-20
# Expanded the "Ignore" function, so that entire libraries, series, or specific episodes can be ignored
# on an individual basis. Due to this, I have done something I hate doing, and renamed the 'ignoreArr'
# array from the previous update to 'ignoreEpisodes', to better reflect what is being ignored. Please
# accept my sincerest apologies for this variable rename. I plan to rename no other variables in the future.
# Also updated some verbiage and some error codes
# 2024-05-16
# Added an "Ignore" function, so that specific files/episodes can be ignored on an individual basis
# See updated .env.example for the 'ignoreArr' array item
# 2024-05-02
# Fixed a small typo with a sanity check
# 2024-04-27
# Added support for host-based instances of Sonarr, in addition to Docker-based instances.
# Notable, only one host-based instance can be supported, while multiple Docker-based instances can.
# See updated .env file for updated config options
# 2024-03-11
# Added support for "TBD" files in addition to "TBA" files
# 2024-01-28
# Moved the function to find a container's IP address to a standalone function, and made it more durable
# to finding the IP address across various network configurations
# 2024-01-27
# Improved some sanity checks and logic for escape scenarioes
# Added support for when a container has multiple networks attached (Multiple IP addresses)
# Updated the logic for sending Telegram messages to make sure the bot can authenticate to each channel
# Added support for super groups, silent messages (See updated .env file)
# Added support for sending error messages via telegram (See updated .env file)
# 2023-12-29
# Added a sort to TBA items that are found, because I like it when the output is sorted.
# Also fixed a bug causing files already renamed to not have their correct new name called for the Telegram annoucement/script output
# 2023-11-27
# Fleshed out support for Sonarr v4 due to requests being malformed in the POST command API calls (HUGE thanks to @StevieTV helping me with the fix)
# Narrowed the 'find' command to only find video formats supported by Plex
# Improved lockfile behavior and added a warning if a lockfile exists
# Added traps for SIGINT, SIGQUIT, SIGKILL
# Fixed some typos and improved some verbiage
# Improved the way new titles for renamed items are obtained
# Moved the Sonarr API key in 'curl' calls from the URL to a header
# Removed any sensitive information from the 'verbose' output
# 2023-11-24
# Added support for Sonarr v4, which also uses API v3 (Thanks for the issue @schumi4)
# 2023-11-13
# Added support for updating metadata for TBA items in Plex
#   If using an older version of the .env file with the newer version of the script, you may want to
#   look at the updated .env.example file for the added config items required to enable this function.
# 2023-10-15
# Added support for multiple Sonarr instances
#   If using an older version of the .env file with the newer version of the script, it will Failed
#   with an error that the .env file needs to be updated. Take a look at the new one, but essentially,
#   the `containerName=` string just needs to be changed to a `conatiners=()` array.
# 2023-10-15
# Better logic for how to determine root folder and series folder (Thanks for the issue @Hannah-GBS)
# Added the check for lockfile to prevent concurrent runs
# Added a few stops to make sure we should continue along the way
# 2023-10-13
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
depArr=("awk" "curl" "jq" "md5sum" "printf" "rm")
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
updateURL="https://raw.githubusercontent.com/goose-ws/bash-scripts/main/sonarr-update-tba.bash"
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
    5) logLevel="[DEBUG]";; # Debug
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

function sendDiscordMessage {
    # Message to send should be passed as functional positional parameter #1
    if [[ -z "${discordWebhook}" ]]; then
        printOutput "5" "No Discord Webhook URL provided, unable to send Discord message"
        return 0
    fi

    # Make sure our message is not blank
    if [[ -z "${1}" ]]; then
        printOutput "1" "No message passed to send to Discord"
        return 1
    fi

    # Send the plain text message
    # Positional parameter 2 is the URL
    # Positional parameter 3 is the text
    callCurlPost "${discordWebhook}" "${1}"
}

function callCurlPost {
# URL to call should be ${1}
if [[ -z "${1}" ]]; then
    printOutput "1" "No input URL provided for POST"
    return 1
fi

printOutput "5" "Issuing curl command [curl -skL -X POST \"${1}\"]"
curlOutput="$(curl -skL -X POST "${1}" 2>&1)"
curlExitCode="${?}"
if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    while read -r i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    return 1
fi
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
            elif [[ "$(jq -M -r ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
                printOutput "3" "Curl exit code and null output checks passed"
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
                        while read -r i; do
                            printOutput "1" "${i}"
                        done < <(jq . <<<"${telegramOutput}")
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
    while read -r i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    badExit "1" "Bad curl output"
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
            containerIp="$(docker inspect "${1#*:}" | jq -M -r ".[].HostConfig.NetworkMode")"
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
                    containerIp="$(docker inspect "${1#*:}" | jq -M -r ".[] | .NetworkSettings.Networks.\"${i}\".IPAddress")"
                    if [[ "${containerIp}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
                        break
                    fi
                fi
            done
        fi
    else
        badExit "2" "Unknown container daemon: ${1%%:*}"
    fi
else
    containerIp="${1}"
fi

if [[ -z "${containerIp}" ]] || ! [[ "${containerIp}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
    badExit "3" "Unable to determine IP address via networking mode: ${i}"
else
    printOutput "3" "Container IP address: ${containerIp}"
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
                badExit "4" "Update downloaded, but unable to \`chmod +x\`"
            fi
        else
            badExit "5" "Unable to download Update"
        fi
    ;;
esac

#############################
##   Initiate .env file    ##
#############################
if [[ -e "${realPath%/*}/${scriptName%.bash}.env" ]]; then
    source "${realPath%/*}/${scriptName%.bash}.env"
else
    badExit "6" "Error: \"${realPath%/*}/${scriptName%.bash}.env\" does not appear to exist"
fi
varFail="0"
# Standard checks
if ! [[ "${updateCheck,,}" =~ ^(yes|no|true|false)$ ]]; then
    echo "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   [1] Option to check for updates not valid. Assuming no."
    updateCheck="No"
fi
if ! [[ "${outputVerbosity}" =~ ^[1-3]$ ]]; then
    echo "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   [1] Invalid output verbosity defined. Assuming level 1 (Errors only)"
    outputVerbosity="1"
fi

# Config specific checks
if [[ "${#containerIp[@]}" -eq "0" ]]; then
    echo "No container names defined"
    echo "###"
    echo "If using an older version of this script, the .env file has been updated"
    echo "to support multiple instances of Sonarr -- Please update your .env file:"
    echo "https://github.com/goose-ws/bash-scripts/blob/main/sonarr-update-tba.env.example"
    varFail="1"
fi

# Quit if failures
if [[ "${varFail}" -eq "1" ]]; then
    badExit "7" "Please fix above errors"
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
for containerName in "${containerIp[@]}"; do
    printOutput "2" "Processing instance: ${containerName}"
    if [[ "${containerName%%:*}" == "docker" ]]; then
        # If using docker, we should ensure we have permissions to do so
        if ! docker version > /dev/null 2>&1; then
            badExit "8" "Do not appear to have permission to run on the docker socket ('docker version' returned non-zero exit code)"
        fi
    fi
    getContainerIp "${containerName}"

    # Read Sonarr config file
    if [[ "${containerName%%:*}" == "docker" ]]; then
        sonarrConfig="$(docker exec "${containerName#docker:}" cat /config/config.xml | tr -d '\r')"
    else
        if [[ "${#containerIp[@]}" -ne "1" ]]; then
            badExit "9" "Unable to process more than one instance of Sonarr if not using Docker [Counted ${#containerIp[@]} instances: ${containerIp[*]}]"
        fi
        if [[ -z "${sonarrConfig}" ]]; then
            badExit "10" "The \${sonarrConfig} variable MUST be defined for non-Docker instances of Sonarr"
        elif ! [[ -e "${sonarrConfig}" ]]; then
            badExit "11" "Sonarr config file does not appear to exist at: ${sonarrConfig}"
        fi
        sonarrConfig="$(<"${sonarrConfig}")"
    fi
    if [[ -z "${sonarrConfig}" ]]; then
        badExit "12" "Failed to read Sonarr config file"
    else
        printOutput "2" "Configuration file retrieved"
    fi

    # Get Sonarr port from config file
    sonarrPort="$(grep -Eo "<Port>.*</Port>" <<<"${sonarrConfig}")"
    sonarrPort="${sonarrPort#<Port>}"
    sonarrPort="${sonarrPort%</Port>}"
    if ! [[ "${sonarrPort}" =~ ^[0-9]+$ ]]; then
        badExit "13" "Failed to obtain port"
    else
        printOutput "2" "Port retrieved from config file"
        printOutput "3" "Port: ${sonarrPort}"
    fi

    # Get Sonarr API key from config file
    sonarrApiKey="$(grep -Eo "<ApiKey>.*</ApiKey>" <<<"${sonarrConfig}")"
    sonarrApiKey="${sonarrApiKey#<ApiKey>}"
    sonarrApiKey="${sonarrApiKey%</ApiKey>}"
    if [[ -z "${sonarrApiKey}" ]]; then
        badExit "14" "Failed to obtain API key"
    else
        printOutput "2" "API key retrieved from config file"
        printOutput "3" "API key: ${sonarrApiKey}"
    fi

    # Get Sonarr URL base from config file
    sonarrUrlBase="$(grep -Eo "<UrlBase>.*</UrlBase>" <<<"${sonarrConfig}")"
    sonarrUrlBase="${sonarrUrlBase#<UrlBase>}"
    sonarrUrlBase="${sonarrUrlBase%</UrlBase>}"
    if [[ -z "${sonarrUrlBase}" ]]; then
        printOutput "2" "No URL base detected"
    else
        printOutput "2" "URL base detected"
        printOutput "3" "URL base: ${sonarrUrlBase}"
    fi

    # Test Sonarr API
    printOutput "3" "Built Sonarr URL: ${containerIp}:${sonarrPort}${sonarrUrlBase}/api/system/status"
    printOutput "2" "Checking API functionality"
    apiCheck="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}/api/v3/system/status" -H "X-api-key: ${sonarrApiKey}" -H "Content-Type: application/json" -H "Accept: application/json")"
    curlExitCode="${?}"
    if [[ "${curlExitCode}" -ne "0" ]]; then
        badExit "15" "Curl returned non-zero exit code: ${curlExitCode}"
    elif grep -q '"error": "Unauthorized"' <<<"${apiCheck}"; then
        badExit "16" "Authorization failure: ${apiCheck}"
    else
        printOutput "2" "API authorization succeded"
    fi

    # Determine which version of the API we need to use
    # Sonarr v3 and v4 use API v3
    sonarrVersion="$(jq -M -r ".version" <<<"${apiCheck}")"
    if [[ "${sonarrVersion:0:1}" -eq "3" || "${sonarrVersion:0:1}" -eq "4" ]]; then
        printOutput "3" "Detected Sonarr v${sonarrVersion:0:1}, API v3"
        apiRootFolder="/api/v3/rootfolder"
        apiSeries="/api/v3/series"
        apiCommand="/api/v3/command"
        apiEpisode="/api/v3/episode"
        apiRename="/api/v3/rename"
    else
        printOutput "1" "Detected Sonarr version ${sonarrVersion:0:1}"
        printOutput "1" "Currently only API version 3 (Sonarr v3/v4) is supported"
        badExit "17" "Please create an issue for support with other API versions"
    fi
    
    # Leaving this as an undocumented but configurable option for users who may need to alter their find regex
    if [[ -z "${findRegex}" ]]; then
        findRegex=".*TB[AD].*\.([Aa][Ss][Ff]|[Aa][Vv][Ii]|[Mm][Oo][Vv]|[Mm][Pp]4|([Mm][Pp][Ee][Gg])?[Tt][Ss]|[Mm][Kk][Vv]|[Ww][Mm][Vv])$"
    fi

    # Retrieve Sonarr libraries via API
    libraries="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiRootFolder}" -H "X-api-key: ${sonarrApiKey}" -H "Content-Type: application/json" -H "Accept: application/json")"
    numLibraries="$(jq -M length <<<"${libraries}")"
    printOutput "2" "Detected ${numLibraries} libraries"
    unset libraryArr
    for i in $(seq 0 $(( numLibraries - 1 ))); do
        libraryPath="$(jq -M -r ".[${i}].path" <<<"${libraries}")"
        libraryId="$(jq -M -r ".[${i}].id" <<<"${libraries}")"
        
        # Check to see if we should ignore the found library
        for ignoreId in "${ignoreLibrary[@]}"; do
            if [[ "${#containerIp[@]}" -eq "1" ]]; then
                if [[ "${ignoreId}" == "${libraryId}" ]]; then
                    printOutput "2" "Library ID [${libraryId}] set to be ignored in config -- Skipping"
                    continue 2
                fi
            else
                if ! [[ "${ignoreId}" =~ ^docker:.*:[0-9]+$ ]]; then
                    printOutput "1" "Invalid format for ignore ID with multiple containers [${ignoreId}]"
                    continue
                fi
                if [[ "${containerName}" == "${ignoreId%:*}" ]]; then
                    if [[ "${ignoreId##*:}" == "${libraryId}" ]]; then
                        printOutput "2" "Library ID [${libraryId}] set to be ignored in config -- Skipping"
                        continue 2
                    fi
                fi
            fi
        done
        
        libraryArr+=("${libraryPath}")
        if [[ "${outputVerbosity}" -ge "3" ]]; then
            printOutput "3" "- ${libraryPath} [Library ID: ${libraryId}]"
        fi
    done

    # Search each library for files containing "* TBA *" in the title
    # Supported media types per https://www.plexopedia.com/plex-media-server/general/file-formats-supported-plex/#video
    # ASF, AVI, MOV, MP4, MPEGTS, TS, MKV, wmv
    # Have to use 'grep' as the busybox version of the Sonarr v4 container does not support '-iregex'
    # Can add support for others by modifying the 'grep' line below
    unset files
    for i in "${libraryArr[@]}"; do
        printOutput "2" "Checking for TBA/TBD items in ${i}"
        matches="0"
        if [[ "${containerName%%:*}" == "docker" ]]; then
            if ! docker exec "${containerName#docker:}" test -d "${i}"; then
                printOutput "1" "Directory does not appear to exist: ${i} -- Skipping"
                continue
            fi
            while read -r ii; do
                printOutput "3" "Found TBA/TBD item: ${ii}"
                files+=("${i}:${ii}")
                (( matches++ ))
            done < <(docker exec "${containerName#docker:}" find "${i}" -type f -regextype egrep -regex "${findRegex}" | tr -d '\r' | sort)
        else
            # Make sure our find directory actually exists
            if ! [[ -d "${i}" ]]; then
                printOutput "1" "Directory does not appear to exist: ${i} -- Skipping"
                continue
            fi
            while read -r ii; do
                printOutput "3" "Found TBA/TBD item: ${ii}"
                files+=("${i}:${ii}")
                (( matches++ ))
            done < <(find "${i}" -type f -regextype egrep -regex "${findRegex}" | tr -d '\r' | sort)
        fi
    done
    
    printOutput "2" "Located ${#files[@]} files to process"

    # If the array of files matching the search pattern is not empty, iterate through them
    for file in "${files[@]}"; do
        rootFolder="${file%%:*}"
        file="${file#*:}"
        printOutput "3" "Library: ${rootFolder} | File: ${file#${rootFolder}}"
        printOutput "2" "Processing ${file##*/}"
        printOutput "3" "Verifying file has not already been renamed"
        # Quick check to ensure that we actually need to do this. Perhaps there were multiple TBA's in a series, and we got all of them on the first run?
        fileExists="0"
        if [[ "${containerName%%:*}" == "docker" ]]; then
            if docker exec "${containerName#docker:}" stat "${file}" > /dev/null 2>&1; then
                fileExists="1"
            fi
        else
            if stat "${file}" > /dev/null 2>&1; then
                fileExists="1"
            fi
        fi
        
        # Make sure we're dealing with a file that has a S#E# pattern, and not another pattern (Daily)
        # TODO: Add support for shows with a "Daily" episode code pattern
        if [[ "${file}" =~ ^.*[Ss][0-9]+[Ee][0-9]+.*$ ]]; then
            printOutput "5" "Validated Season/Episode code formatting in file name"
        else
            printOutput "1" "Unable to validate Season/Episode code formatting for [${file}] -- Skipping"
            continue
        fi
        
        # Define the season and episode numbers  
        unset epCode
        storeCode="0"
        for (( i=0; i<"${#file}"; i++ )); do
            char="${file:${i}:1}"
            char="${char^}"
            if [[ "${char}" == "S" ]]; then
                # Store it, if the next character is a digit, string them together
                storeCode="1"
                epCode="${char}"
            elif [[ "${storeCode}" -eq "1" ]]; then
                # We're storing the code.
                # If it's a digit, or the letter 'E' add it
                if [[ "${char}" =~ [0-9] || "${char}" == "E" ]]; then
                    epCode="${epCode}${char}"
                else
                    # If it's something else, our string should be built
                    if [[ "${epCode}" =~ ^S[0-9]+E[0-9]+$ ]]; then
                        # Matches, we're good, break the loop
                        break
                    else
                        # Doesn't match the pattern, scrap it and start over
                        unset epCode
                        storeCode="0"
                    fi
                fi
            fi
        done
        
        # Extract what we want
        fileSeasonNum="${epCode%E*}"
        fileSeasonNum="${fileSeasonNum#S}"
        fileEpisodeNum="${epCode#*E}"
        
        # Check it for sanity
        if [[ -z "${fileSeasonNum}" || -z "${fileEpisodeNum}" ]]; then
            badExit "18" "Unable to parse season/episode number from file [${file}] [Season ${fileSeasonNum}][Episode ${fileEpisodeNum}]"
        fi
        if ! [[ "${fileSeasonNum}" =~ ^[0-9]+ ]]; then
            badExit "19" "File [${file}] season lookup returned non-interger [${fileSeasonNum}]"
        fi
        if ! [[ "${fileEpisodeNum}" =~ ^[0-9]+ ]]; then
            badExit "20" "File [${file}] episode lookup returned non-interger [${fileEpisodeNum}]"
        fi
        
        if [[ "${fileExists}" -eq "1" ]]; then
            # Find the series ID by searching for a series with the matching path
            seriesFolder="${file#${rootFolder}/}"
            seriesFolder="${seriesFolder%%/*}"
            printOutput "3" "Root folder: ${rootFolder} | Series folder: ${seriesFolder}"
            # Build the series path
            seriesPath="${rootFolder}/${seriesFolder}"
            # Find the series which matches the path
            series="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiSeries}" -H "X-api-key: ${sonarrApiKey}" -H "Content-Type: application/json" -H "Accept: application/json" | jq -M -r ".[] | select(.path==\"${seriesPath}\")")"
            if [[ -n "${series}" ]]; then
                printOutput "3" "Found series: $(jq -M -r ".title" <<<"${series}")"
            else
                badExit "21" "Unable to find series"
            fi
            # Get the title of the series
            seriesTitle="$(jq -M -r ".title" <<<"${series}")"
            
            # Get the series ID for the series
            readarray -t seriesId < <(jq -M -r ".id" <<<"${series}")
            # Ensure we only matched one series
            if [[ "${#seriesId[@]}" -eq "0" ]]; then
                badExit "22" "Failed to match series ID for file: ${file} [${#seriesId[@]}]"
            elif [[ "${#seriesId[@]}" -ge "2" ]]; then
                badExit "23" "More than one matched series ID for file: ${file} [${#seriesId[@]}]"
            elif [[ -z "${seriesId[0]}" ]]; then
                badExit "24" "Series ID lookup returned blank string"
            elif ! [[ "${seriesId[0]}" =~ ^[0-9]+$ ]]; then
                badExit "25" "Bad series ID lookup [${#seriesId[@]}]"
            else
                printOutput "3" "Found series ID: ${seriesId[0]}"
            fi
            
            # Check to see if we should ignore the found series
            for ignoreId in "${ignoreSeries[@]}"; do
                if [[ "${#containerIp[@]}" -eq "1" ]]; then
                    if [[ "${ignoreId}" == "${seriesId[0]}" ]]; then
                        printOutput "2" "Series ID [${seriesId[0]}] set to be ignored in config -- Skipping"
                        continue 2
                    fi
                else
                    if ! [[ "${ignoreId}" =~ ^docker:.*:[0-9]+$ ]]; then
                        printOutput "1" "Invalid format for ignore ID with multiple containers [${ignoreId}]"
                        continue
                    fi
                    if [[ "${containerName}" == "${ignoreId%:*}" ]]; then
                        if [[ "${ignoreId##*:}" == "${seriesId[0]}" ]]; then
                            printOutput "2" "Series ID [${seriesId[0]}] set to be ignored in config -- Skipping"
                            continue 2
                        fi
                    fi
                fi
            done
            
            # Get the ID of the relevant episode file
            epId="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiEpisode}?seriesId=${seriesId[0]}&seasonNumber=${fileSeasonNum}" -H "X-api-key: ${sonarrApiKey}" -H 'Content-Type: application/json' -H 'Accept: application/json' | jq -M -r ".[] | select(.episodeNumber==${fileEpisodeNum}) .episodeFileId")"
            if [[ -z "${epId}" ]]; then
                badExit "26" "Unable to obtain episode ID"
            elif ! [[ "${epId}" =~ ^[0-9]+$ ]]; then
                badExit "27" "Episode ID does not appear to be valid: ${epId}"
            elif [[ "${epId}" =~ ^[0-9]+$ ]]; then
                printOutput "3" "Found episode ID: ${epId}"
            else
                badExit "28" "Impossible condition"
            fi
            
            # Check to see if we should ignore the found file
            for ignoreId in "${ignoreEpisodes[@]}"; do
                if [[ "${#containerIp[@]}" -eq "1" ]]; then
                    if [[ "${ignoreId}" == "${epId}" ]]; then
                        printOutput "2" "Episode ID [${epId}] set to be ignored in config -- Skipping"
                        continue 2
                    fi
                else
                    if ! [[ "${ignoreId}" =~ ^docker:.*:[0-9]+$ ]]; then
                        printOutput "1" "Invalid format for ignore ID with multiple containers [${ignoreId}]"
                        continue
                    fi
                    if [[ "${containerName}" == "${ignoreId%:*}" ]]; then
                        if [[ "${ignoreId##*:}" == "${epId}" ]]; then
                            printOutput "2" "Episode ID [${epId}] set to be ignored in config -- Skipping"
                            continue 2
                        fi
                    fi
                fi
            done
            
            # Refresh the series
            skipRefresh="0"
            for checkId in "${refreshedSeries[@]}"; do
                if [[ "${checkId}" == "${seriesId[0]}" ]]; then
                    printOutput "3" "Series ID [${seriesId[0]}] has already been refreshed"
                    skipRefresh="1"
                    break
                fi
            done
            
            if [[ "${skipRefresh}" -eq "0" ]]; then
                printOutput "2" "Issuing refresh command for: ${seriesTitle}"
                commandOutput="$(curl -skL -X POST "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiCommand}" -H "X-api-key: ${sonarrApiKey}" -H "Content-Type: application/json" -H "Accept: application/json" -d "{\"name\": \"RefreshSeries\", \"seriesId\": ${seriesId[0]}}" 2>&1)"
                commandId="$(jq -M -r ".id" <<< "${commandOutput}")"
                refreshedSeries+=("${seriesId[0]}")

                # Give refresh a second to process
                sleep 1
                
                # Check the command status queue to see if the command is done
                commandStatus="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiCommand}" -H "X-api-key: ${sonarrApiKey}" -H "Content-Type: application/json" -H "Accept: application/json" | jq -M -r ".[] | select(.id == ${commandId}) | .status")"
                printOutput "2" "Command status [${commandId}]: ${commandStatus,,}"
                if ! [[ "${commandStatus,,}" == "completed" ]]; then
                    while [[ -n "${commandStatus}" ]]; do
                        if [[ "${commandStatus,,}" == "completed" ]]; then
                            printOutput "2" "Command status [${commandId}]: ${commandStatus,,}"
                            break
                        else
                            printOutput "3" "Command status [${commandId}]: ${commandStatus,,}"
                        fi
                        sleep 1
                        commandStatus="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiCommand}" -H "X-api-key: ${sonarrApiKey}" -H "Content-Type: application/json" -H "Accept: application/json" | jq -M -r ".[] | select(.id == ${commandId}) | .status")"
                    done
                fi
                if [[ -z "${commandStatus}" ]]; then
                    printOutput "1" "Unable to retrieve command ID ${commandId} from command log"
                    printOutput "3" "Sleeping 15 seconds to attempt to ensure system has time to process command"
                    sleep 15
                fi
            fi

            # Rename the specific episode
            printOutput "2" "Issuing rename command for: ${seriesTitle} [S${fileSeasonNum}E${fileEpisodeNum}]"
            commandOutput="$(curl -skL -X POST "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiCommand}" -H "X-api-key: ${sonarrApiKey}" -H "Content-Type: application/json" -H "Accept: application/json" -d "{\"name\":\"RenameFiles\", \"seriesId\":${seriesId[0]}, \"files\":[${epId}]}" 2>&1)"
            commandId="$(jq -M -r ".id" <<< "${commandOutput}")"

            # Give rename a second to process
            sleep 1
            
            # Check the command status queue to see if the command is done
            commandStatus="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiCommand}" -H "X-api-key: ${sonarrApiKey}" -H "Content-Type: application/json" -H "Accept: application/json" | jq -M -r ".[] | select(.id == ${commandId}) | .status")"
            printOutput "2" "Command status [${commandId}]: ${commandStatus,,}"
            if ! [[ "${commandStatus,,}" == "completed" ]]; then
                while [[ -n "${commandStatus}" ]]; do
                    if [[ "${commandStatus,,}" == "completed" ]]; then
                        printOutput "2" "Command status [${commandId}]: ${commandStatus,,}"
                        break
                    else
                        printOutput "3" "Command status [${commandId}]: ${commandStatus,,}"
                    fi
                    sleep 1
                    commandStatus="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiCommand}" -H "X-api-key: ${sonarrApiKey}" -H "Content-Type: application/json" -H "Accept: application/json" | jq -M -r ".[] | select(.id == ${commandId}) | .status")"
                done
            fi
            if [[ -z "${commandStatus}" ]]; then
                printOutput "1" "Unable to retrieve command ID ${commandId} from command log"
                printOutput "3" "Sleeping 15 seconds to attempt to ensure system has time to process command"
                sleep 15
            fi
        else
            printOutput "3" "File does not exist at same path, appears to have been renamed"
        fi
        # Check to see if rename happened
        printOutput "3" "Checking to see if file was renamed"
        fileExists="0"
        if [[ "${containerName%%:*}" == "docker" ]]; then
            if docker exec "${containerName#docker:}" stat "${file}" > /dev/null 2>&1; then
                fileExists="1"
            fi
        else
            if stat "${file}" > /dev/null 2>&1; then
                fileExists="1"
            fi
        fi
        if [[ "${fileExists}" -eq "0" ]]; then
            printOutput "3" "File appears to have been renamed -- Requesting new file name from Sonarr"
            episodeName="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiEpisode}?seriesId=${seriesId[0]}&seasonNumber=${fileSeasonNum}" -H "X-api-key: ${sonarrApiKey}" -H "Content-Type: application/json" -H "Accept: application/json")"
            episodeName="$(jq -M -r ".[] | select (.episodeNumber==${fileEpisodeNum}) | .title" <<<"${episodeName}")"
            # In case the episode name is an illegal file name, such as The Changeling S01E03.
            # Probably no longer necessary since moving to asking Sonarr for the title, instead of the file system
            if [[ -z "${episodeName}" ]]; then
                episodeName="[Unable to retrieve]"
            fi
            msgArr+=("[${containerName}] Renamed file ${seriesTitle} - ${epCode} to: <i>${episodeName}</i>")
            printOutput "2" "Renamed file ${seriesTitle} - ${epCode} to: ${episodeName}"
        else
            printOutput "2" "File name unchanged, new title unavailable for: ${seriesTitle} ${epCode}"
        fi
    done
done

if [[ -n "${telegramBotId}" && -n "${telegramChannelId[0]}" && "${#msgArr[@]}" -ne "0" ]]; then
    dockerHost="$(</etc/hostname)"
    if [[ "${outputVerbosity}" -ge "3" ]]; then
        printOutput "3" "Counted ${#msgArr[@]} messages to send:"
        for i in "${msgArr[@]}"; do
            printOutput "3" "- ${i}"
        done
    fi
    eventText="<b>Sonarr file rename for ${dockerHost%%.*}</b>${lineBreak}$(printf '%s\n' "${msgArr[@]}")"
    printOutput "3" "Got hostname: ${dockerHost}"
    printOutput "2" "Telegram messaging enabled -- Passing message to function"
    sendTelegramMessage "${eventText}"
fi
if [[ -n "${discordWebhook}" ]]; then
    printOutput "4" "Counted ${#msgArr[@]} Discord messages to send:"
    for i in "${msgArr[@]}"; do
        printOutput "4" "- ${i}"
    done
    eventText="**Plex metadata update for ${serverName}**${lineBreak}$(printf '%s\n' "${msgArr[@]}")"
    printOutput "3" "Sending Discord messages"
    sendDiscordMessage "${eventText}"
fi

#############################
##       End of file       ##
#############################
cleanExit
