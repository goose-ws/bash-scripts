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

# Next, this script relies on finding TBA files with the search patthern: "* TBA *"
# I suggest having the Episode Clean Title in the "Episode Format". This means that at a minimum,
# you must have: {Episode CleanTitle}
# in your "Episode Format" fields. I use the Episode Formats:
# Standard Episode Format: {Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Preferred Words }{Quality Full}]{[MediaInfo VideoDynamicRange]}[{MediaInfo VideoBitDepth}bit]{[MediaInfo VideoCodec]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{MediaInfo AudioLanguages}{-Release Group}
# Daily Episode Format: {Series TitleYear} - {Air-Date} - {Episode CleanTitle} [{Preferred Words }{Quality Full}]{[MediaInfo VideoDynamicRange]}[{MediaInfo VideoBitDepth}bit]{[MediaInfo VideoCodec]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{MediaInfo AudioLanguages}{-Release Group}
# Anime Episode Format: {Series TitleYear} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle} [{Preferred Words }{Quality Full}]{[MediaInfo VideoDynamicRange]}[{MediaInfo VideoBitDepth}bit]{[MediaInfo VideoCodec]}[{Mediainfo AudioCodec} { Mediainfo AudioChannels}]{MediaInfo AudioLanguages}{-Release Group}

# Thanks to Trash Guides ( https://trash-guides.info/Sonarr/Sonarr-recommended-naming-scheme/ ) for these naming schemes.

#############################
##        Changelog        ##
#############################
# 2023-10-13
# Rewrite of old script, removal of old script, and initial commit of new script

#############################
##       Installation      ##
#############################
# 1. Download the script .bash file somewhere safe
# 2. Download the script .env file somewhere safe
# 3. Edit the .env file to your liking
# 4. Set the script to run on an hourly cron job, or whatever your preference is

###################################################
### Begin source, please don't edit below here. ###
###################################################

if [[ -z "${BASH_VERSINFO[0]}" || "${BASH_VERSINFO[0]}" -lt "4" ]]; then
    echo "This script requires Bash version 4 or greater"
    exit 255
fi
depArr=("awk" "curl" "docker" "jq" "md5sum" "printf" "rm")
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

## Used internally for debugging
# debugDir="${realPath%/*}/.${scriptName}.debug"
# mkdir -p "${debugDir}"
# exec 2> "${debugDir}/$(date).debug"
# printenv
# PS4='Line ${LINENO}: '
# set -x
# if [[ "${1}" == "-s" ]] && [[ -e "${2}" ]]; then
    # source "${2}"
    # # Can pass test data with the -s flag (-s /path/to/file)
# fi

# We can run the positional parameter options without worrying about lockFile
case "${1,,}" in
    "-h"|"--help")
        echo "-h  --help      Displays this help message"
        echo ""
        echo "-u  --update    Self update to the most recent version"
        exit 0
    ;;
    "-u"|"--update")
        curl -skL "https://raw.githubusercontent.com/goose-ws/bash-scripts/main/sonarr-update-tba.bash" -o "${0}"
        chmod +x "${0}"
        exit 0
    ;;
esac

echo "${$}" >> "${lockFile}"

# Define some functions
function printOutput {
if [[ "${1}" -le "${outputVerbosity}" ]]; then
    echo "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   [${1}] ${2}"
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
printOutput "1" "${2}"
removeLock
exit "${1}"
}

function cleanExit {
removeLock
exit 0
}

function sendTelegramMessage {
# Let's check to make sure our messaging credentials are valid
telegramOutput="$(curl -skL "https://api.telegram.org/bot${telegramBotId}/getMe" 2>&1)"
curlExitCode="${?}"
if [[ "${curlExitCode}" -ne "0" ]]; then
    badExit "1" "Curl to Telegram to check Bot ID returned a non-zero exit code: ${curlExitCode}"
elif [[ -z "${telegramOutput}" ]]; then
    badExit "2" "Curl to Telegram to check Bot ID returned an empty string"
else
    printOutput "3" "Curl exit code and null output checks passed"
fi
if ! [[ "$(jq -M -r ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
    badExit "3" "Telegram bot API check failed"
else
    printOutput "2" "Telegram bot API key authenticated"
    telegramOutput="$(curl -skL "https://api.telegram.org/bot${telegramBotId}/getChat?chat_id=${telegramChannelId}")"
    curlExitCode="${?}"
    if [[ "${curlExitCode}" -ne "0" ]]; then
        badExit "4" "Curl to Telegram to check channel returned a non-zero exit code: ${curlExitCode}"
    elif [[ -z "${telegramOutput}" ]]; then
        badExit "5" "Curl to Telegram to check channel returned an empty string"
    else
        printOutput "3" "Curl exit code and null output checks passed"
    fi
    if ! [[ "$(jq -M -r ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
        badExit "6" "Telegram channel check failed"
    else
        printOutput "2" "Telegram channel authenticated"
    fi
fi
eventText="<b>Sonarr file rename for ${dockerHost%%.*}</b>$(printf "\r\n\r\n")$(printf '%s\n' "${msgArr[@]}")"
for chanId in "${telegramChannelId[@]}"; do
    telegramOutput="$(curl -skL --data-urlencode "text=${eventText}" "https://api.telegram.org/bot${telegramBotId}/sendMessage?chat_id=${chanId}&parse_mode=html" 2>&1)"
    curlExitCode="${?}"
    if [[ "${curlExitCode}" -ne "0" ]]; then
        badExit "7" "Curl to Telegram returned a non-zero exit code: ${curlExitCode}"
    else
        printOutput "3" "Curl returned zero exit code"
        # Check to make sure Telegram returned a true value for ok
        if ! [[ "$(jq -M -r ".ok" <<<"${telegramOutput}")" == "true" ]]; then
            printOutput "1" "Failed to send Telegram message:"
            printOutput "1" ""
            printOutput "1" "$(jq . <<<"${telegramOutput}")"
            printOutput "1" ""
        else
            printOutput "2" "Telegram message sent to channel ${chanId} successfully"
        fi
    fi
done
}

# Get config options
source "${realPath%/*}/${scriptName%.bash}.env"
varFail="0"
if ! [[ "${updateCheck,,}" =~ ^(yes|no|true|false)$ ]]; then
    echo "Option to check for updates not valid. Assuming no."
    updateCheck="No"
fi
if ! [[ "${outputVerbosity}" =~ ^[1-3]$ ]]; then
    echo "Invalid output verbosity defined. Assuming level 1 (Errors only)"
    outputVerbosity="1"
fi
if [[ "${varFail}" -eq "1" ]]; then
    badExit "8" "Please fix above errors"
fi

# Can we check for updates?
if [[ "${updateCheck,,}" =~ ^(yes|true)$ ]]; then
    newest="$(curl -skL "https://raw.githubusercontent.com/goose-ws/bash-scripts/main/sonarr-update-tba.bash" | md5sum | awk '{print $1}')"
    current="$(md5sum "${0}" | awk '{print $1}')"
    if ! [[ "${newest}" == "${current}" ]]; then
        # Although it's not an error, we should always be allowed to print this message if update checks are allowed, so giving it priority 1
        printOutput "1" "A newer version is available"
    else
        printOutput "2" "No new updates available"
    fi
fi

# Get Sonarr IP address
if [[ -z "${containerIp}" ]]; then
    printOutput "2" "Attempting to automatically determine container IP address"
    # Find the type of networking the container is using
    containerNetworking="$(docker container inspect --format '{{range $net,$v := .NetworkSettings.Networks}}{{printf "%s" $net}}{{end}}' "${containerName}")"
    printOutput "3" "Networking type: ${containerNetworking}"
    if [[ -z "${containerNetworking}" ]]; then
        printOutput "2" "No network type defined. Checking to see if networking is through another container."
        # IP address returned blank. Is it being networked through another container?
        containerIp="$(docker inspect "${containerName}" | jq -M -r ".[].HostConfig.NetworkMode")"
        containerIp="${containerIp#\"}"
        containerIp="${containerIp%\"}"
        printOutput "3" "Network mode: ${containerIp%%:*}"
        if [[ "${containerIp%%:*}" == "container" ]]; then
            # Networking is being run through another container. So we need that container's IP address.
            printOutput "2" "Networking routed through another container. Retrieving IP address."
            containerIp="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${containerIp#container:}")"
        else
            printOutput "1" "Unable to determine networking type"
            unset containerIp
        fi
    elif [[ "${containerNetworking}" == "host" ]]; then
        # Host networking, so we can probably use localhost
        containerIp="127.0.0.1"
    else
        # Something else. Let's see if we can get it via inspect.
        containerIp="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${containerName}")"
    fi
    if [[ -z "${containerIp}" ]] || ! [[ "${containerIp}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
        badExit "9" "Unable to determine IP address"
    else
        printOutput "2" "Container IP address: ${containerIp}"
    fi
fi

# Read Sonarr config file
sonarrConfig="$(docker exec "${containerName}" cat /config/config.xml)"
if [[ -z "${sonarrConfig}" ]]; then
    badExit "10" "Failed to read Sonarr config file"
else
    printOutput "2" "Configuration file retrieved"
    #printOutput "3" "File contents:$(printf "\r\n\r\n")${sonarrConfig}"
fi

# Get Sonarr port from config file
sonarrPort="$(grep -Eo "<Port>.*</Port>" <<<"${sonarrConfig}")"
sonarrPort="${sonarrPort#<Port>}"
sonarrPort="${sonarrPort%</Port>}"
if ! [[ "${sonarrPort}" =~ ^[0-9]+$ ]]; then
    badExit "11" "Failed to obtain port"
else
    printOutput "2" "Port retrieved from config file"
    printOutput "3" "Port: ${sonarrPort}"
fi

# Get Sonarr API key from config file
sonarrApiKey="$(grep -Eo "<ApiKey>.*</ApiKey>" <<<"${sonarrConfig}")"
sonarrApiKey="${sonarrApiKey#<ApiKey>}"
sonarrApiKey="${sonarrApiKey%</ApiKey>}"
if [[ -z "${sonarrApiKey}" ]]; then
    badExit "12" "Failed to obtain API key"
else
    printOutput "2" "API key retrieved from config file"
    printOutput "3" "API key: ${sonarrPort}"
fi

# Get Sonarr URL base from config file
sonarrUrlBase="$(grep -Eo "<UrlBase>.*</UrlBase>" <<<"${sonarrConfig}")"
sonarrUrlBase="${sonarrUrlBase#<UrlBase>}"
sonarrUrlBase="${sonarrUrlBase%</UrlBase>}"
if [[ -z "${sonarrApiKey}" ]]; then
    printOutput "2" "No URL base detected"
else
    printOutput "2" "URL base detected"
    printOutput "3" "URL base: ${sonarrUrlBase}"
fi

# Test Sonarr API
printOutput "3" "Built Sonarr URL: ${containerIp}:${sonarrPort}${sonarrUrlBase}/api/system/status?apikey=${sonarrApiKey}"
printOutput "2" "Checking API functionality"
apiCheck="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}/api/v3/system/status?apikey=${sonarrApiKey}")"
if [[ "${?}" -ne "0" ]]; then
    badExit "13" "Curl failed"
elif grep -q '"error": "Unauthorized"' <<<"${apiCheck}"; then
    badExit "14" "Authorization failure: ${apiCheck}"
else
    printOutput "2" "API authorization succeded"
fi

# Determine which version of the API we need to use
apiVersion="$(jq -M -r ".version" <<<"${apiCheck}")"
if [[ "${apiVersion:0:1}" -eq "3" ]]; then
    printOutput "3" "Detected API version 3"
    apiRootFolder="/api/v3/rootfolder"
    apiSeries="/api/v3/series"
    apiCommand="/api/v3/command"
else
    printOutput "1" "Detected API version ${apiVersion:0:1}"
    printOutput "1" "Currently only API version 3 is supported"
    badExit "15" "Please create an issue for support with over API versions"
fi

# Retrieve Sonarr libraries via API
libraries="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiRootFolder}?apikey=${sonarrApiKey}")"
numLibraries="$(jq -M length <<<"${libraries}")"
for i in $(seq 0 $(( numLibraries - 1 ))); do
    item="$(jq -M -r ".[${i}].path" <<<"${libraries}")"
    item="${item#\"}"
    item="${item%\"}"
    libraryArr+=("${item}")
done
printOutput "2" "Detected ${#libraryArr[@]} libraries"
if [[ "${outputVerbosity}" -ge "3" ]]; then
    for i in "${libraryArr[@]}"; do
        printOutput "3" "- ${i}"
    done
fi

# Search each library for files containing "* TBA *" in the title
for i in "${libraryArr[@]}"; do
    printOutput "2" "Checking for TBA items in ${i}"
    while read -r ii; do
        printOutput "3" "Found item: ${ii}"
        files+=("${ii}")
    done < <(docker exec "${containerName}" find "${i}" -type f -name "* TBA *" | tr -d '\r')
done
printOutput "2" "Detected ${#files[@]} TBA items"

# If the array of files matching the search pattern is not empty, iterate through them
for file in "${files[@]}"; do
    printOutput "3" "Verifying file has not already been renamed"
    if [[ "${#file}" -ne "0" ]]; then
        # Quick check to ensure that we actually need to do this. Perhaps there were multiple TBA's in a series, and we got all of them on the first run?
        readarray -t dirContents < <(docker exec "${containerName}" ls "${file%/*}" | tr -d '\r')
        fileExists="0"
        for i in "${dirContents[@]}"; do
            i="${i#\'}"
            i="${i%\'}"
            if [[ "${i}" == "${file##*/}" ]]; then
                printOutput "3" "Filename unchanged"
                fileExists="1"
            fi
        done
        if [[ "${fileExists}" -eq "1" ]]; then
            printOutput "2" "Initiating series rename command"
            # Find the series ID by searching for a series with the matching path
            # First we have to extract ${seriesPath} from ${file}
            # Get the root folder
            rootFolder="${file#/}"
            rootFolder="${rootFolder%%/*}"
            printOutput "3" "Determined root folder: ${rootFolder}"
            # Next get the series folder
            seriesFolder="${file#/"${rootFolder}"/}"
            seriesFolder="${seriesFolder%%/*}"
            printOutput "3" "Determined series folder: ${seriesFolder}"
            # Build the series path
            seriesPath="/${rootFolder}/${seriesFolder}"
            printOutput "3" "Built series path: ${seriesPath}"
            # Find the series which matches the path
            series="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiSeries}?apikey=${sonarrApiKey}" | jq -M -r ".[] | select(.path==\"${seriesPath}\")")"
            printOutput "3" "Determined series: $(jq -M -r ".title" <<<"${series}")"
            
            # Get the title of the series
            seriesTitle="$(jq -M -r ".title" <<<"${series}")"
            
            # Get the series ID for the series
            seriesId="$(jq -M -r ".id" <<<"${series}")"
            printOutput "3" "Determined series ID: ${seriesId}"

            # Ensure we only matched one series
            if [[ "$(wc -l <<<"${seriesId}")" -eq "0" ]]; then
                badExit "16" "Failed to match series ID for file: ${file}"
            elif [[ "$(wc -l <<<"${seriesId}")" -gt "1" ]]; then
                badExit "17" "More than one matched series ID for file: ${file}"
            else
                printOutput "3" "Matched series ID for file"
            fi

            # Refresh the series
            printOutput "2" "Issuing refresh command for: ${seriesTitle}"
            commandOutput="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiCommand}?apikey=${sonarrApiKey}" -d "{name: \"RefreshSeries\", seriesId: \"${seriesId}\"}" -H "Content-Type: application/json" -X POST 2>&1)"
            commandId="$(jq -M -r ".id" <<< "${commandOutput}")"
            printOutput "3" "Command status: $(jq -M -r ".status" <<<"${commandOutput}")"
            printOutput "3" "Command ID: ${commandId}"

            # Give refresh a second to process
            sleep 1
            
            # Check the command status queue to see if the command is done
            printOutput "3" "Getting command status queue"
            commandStatus="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiCommand}?apikey=${sonarrApiKey}" | jq -M -r ".[] | select(.id == ${commandId}) | .status")"
            while [[ -n "${commandStatus}" ]]; do
                printOutput "2" "Command status ${debug}: ${commandStatus,,}"
                if [[ "${commandStatus,,}" == "completed" ]]; then
                    break
                fi
                sleep 1
                commandStatus="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiCommand}?apikey=${sonarrApiKey}" | jq -M -r ".[] | select(.id == ${commandId}) | .status")"
            done
            if [[ -z "${commandStatus}" ]]; then
                printOutput "1" "Unable to retrieve command ID ${commandId} from command log"
                printOutput "3" "Sleeping 15 seconds to attempt to ensure system has time to process command"
                sleep 15
            fi

            # Rename the series
            printOutput "2" "Issuing rename command for: ${seriesTitle}"
            commandOutput="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiCommand}?apikey=${sonarrApiKey}" -d "{name: \"RenameSeries\", seriesIds: [${seriesId}]}" -H "Content-Type: application/json" -X POST 2>&1)"
            commandId="$(jq -M -r ".id" <<< "${commandOutput}")"
            printOutput "3" "Command status: $(jq -M -r ".status" <<<"${commandOutput}")"
            printOutput "3" "Command ID: ${commandId}"

            # Give rename a second to process
            sleep 1
            
            # Check the command status queue to see if the command is done
            printOutput "3" "Getting command status queue"
            commandStatus="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiCommand}?apikey=${sonarrApiKey}" | jq -M -r ".[] | select(.id == ${commandId}) | .status")"
            while [[ -n "${commandStatus}" ]]; do
                printOutput "2" "Command status: ${commandStatus,,}"
                if [[ "${commandStatus,,}" == "completed" ]]; then
                    break
                fi
                sleep 1
                commandStatus="$(curl -skL "${containerIp}:${sonarrPort}${sonarrUrlBase}${apiCommand}?apikey=${sonarrApiKey}" | jq -M -r ".[] | select(.id == ${commandId}) | .status")"
            done
            if [[ -z "${commandStatus}" ]]; then
                printOutput "1" "Unable to retrieve command ID ${commandId} from command log"
                printOutput "3" "Sleeping 15 seconds to attempt to ensure system has time to process command"
                sleep 15
            fi
            
        fi
        # Check to see if rename happenedreadarray -t dirContents < <(docker exec "${containerName}" ls "${file%/*}")
        printOutput "3" "Verifying file rename status"
        readarray -t dirContents < <(docker exec "${containerName}" ls "${file%/*}" | tr -d '\r')
        fileExists="0"
        for i in "${dirContents[@]}"; do
            i="${i#\'}"
            i="${i%\'}"
            if [[ "${i}" == "${file##*/}" ]]; then
                printOutput "3" "Matched '${i}' to '${file##*/}'"
                fileExists="1"
            fi
        done
        epCode="$(grep -Eo " - S[[:digit:]]+E[[:digit:]]+ - " <<<"${file}")"
        epCode="${epCode// - /}"
        if [[ "${fileExists}" -eq "0" ]]; then
            newEpName="$(docker exec "${containerName}" ls "${file%/*}" | tr -d '\r' | grep -F "${epCode}")"
            newEpName="${newEpName##${seriesPath} - ${epCode} - }"
            newEpName="${newEpName%%[*}"
            newEpName="${newEpName%% }"
            # In case the episode name is an illegal file name, such as The Changeling S01E03.
            if [[ -z "${newEpName}" ]]; then
                newEpName="[null]"
            fi
            msgArr+=("Renamed ${epCode} to: <i>${newEpName}</i>")
            printOutput "2" "Renamed ${epCode} to: ${newEpName}"
        else
            printOutput "2" "File name unchanged, new title unavailable for: ${seriesTitle} ${epCode}"
        fi
    fi
done

if [[ -n "${telegramBotId}" && -n "${telegramChannelId}" && "${#msgArr[@]}" -ne "0" ]]; then
    dockerHost="$(</etc/hostname)"
    if [[ "${outputVerbosity}" -ge "3" ]]; then
    printOutput "3" "Counted ${#msgArr[@]} messages to send:"
        for i in "${msgArr[@]}"; do
            printOutput "3" "- ${i}"
        done
    fi
    printOutput "3" "Got hostname: ${dockerHost}"
    printOutput "2" "Telegram messaging enabled -- Checking credentials"
    sendTelegramMessage
fi