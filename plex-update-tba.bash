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
# This script will search your Plex Media Server for any items titled "TBA" or "TBD", and attempt to
# refresh their metadata.

#############################
##        Changelog        ##
#############################
# 2024-07-24
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
depArr=("awk" "chmod" "curl" "echo" "md5sum" "printf" "yq")
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
updateURL="https://raw.githubusercontent.com/goose-ws/bash-scripts/main/plex-update-tba.bash"
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
if [[ -z "${1}" ]]; then
    printOutput "1" "No input URL provided for GET"
    return 1
fi
printOutput "5" "Issuing curl command [curl -skL \"${1}\"]"
curlOutput="$(curl -skL "${1}" 2>&1)"
curlExitCode="${?}"
if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    while read -r i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    return 1
fi
}

function callCurlPut {
# URL to call should be $1
if [[ -z "${1}" ]]; then
    printOutput "1" "No input URL provided for PUT"
    return 1
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
        badExit "1" "Unknown container daemon: ${1%%:*}"
    fi
else
    containerIp="${1}"
fi

if [[ -z "${containerIp}" ]] || ! [[ "${containerIp}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
    badExit "2" "Unable to determine IP address via networking mode: ${i}"
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
                badExit "3" "Update downloaded, but unable to \`chmod +x\`"
            fi
        else
            badExit "4" "Unable to download Update"
        fi
    ;;
esac

#############################
##   Initiate .env file    ##
#############################
if [[ -e "${realPath%/*}/${scriptName%.bash}.env" ]]; then
    source "${realPath%/*}/${scriptName%.bash}.env"
else
    badExit "5" "Error: \"${realPath%/*}/${scriptName%.bash}.env\" does not appear to exist"
fi
varFail="0"
# Standard checks
if ! [[ "${updateCheck,,}" =~ ^(yes|no|true|false)$ ]]; then
    echo "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   [1] Option to check for updates not valid. Assuming no."
    updateCheck="No"
fi
if ! [[ "${outputVerbosity}" =~ ^[1-4]$ ]]; then
    echo "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   [1] Invalid output verbosity defined. Assuming level 1 (Errors only)"
    outputVerbosity="1"
fi

# Config specific checks
# Check Plex for TBA items, and update their metadata too
if [[ -z "${plexContainerIp}" ]]; then
    printOutput "1" "Please define a container name or IP address for Plex"
    varFail="1"
fi
if [[ -z "${plexScheme}" ]]; then
    printOutput "1" "Please define an HTTP scheme for Plex"
    varFail="1"
fi
if [[ -z "${plexPort}" ]]; then
    printOutput "1" "Please define a port for Plex"
    varFail="1"
fi
if [[ -z "${plexToken}" ]]; then
    printOutput "1" "Please define your Plex access token"
    varFail="1"
fi

# Quit if failures
if [[ "${varFail}" -eq "1" ]]; then
    badExit "6" "Please fix above errors"
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
# Get the address to PMS
getContainerIp "${plexContainerIp}"

# Build our full address
plexAdd="${plexScheme}://${containerIp}:${plexPort}"
if ! callCurl "${plexAdd}/servers?X-Plex-Token=${plexToken}"; then
    badExit "7" "Unable to intiate connection to the Plex Media Server"
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
    badExit "8" "No Plex Media Servers found."
fi
if [[ -z "${serverName}" || -z "${serverVersion}" || -z "${serverMachineId}" ]]; then
    badExit "9" "Unable to validate Plex Media Server"
fi

# Get the library ID for our video output directory
# Count how many libraries we have
if ! callCurl "${plexAdd}/library/sections/?X-Plex-Token=${plexToken}"; then
    badExit "10" "Unable to retrieve list of libraries from the Plex Media Server"
fi
numLibraries="$(yq -p xml ".MediaContainer.Directory | length" <<<"${curlOutput}")"
if [[ "${numLibraries}" -eq "0" ]]; then
    badExit "11" "No libraries detected in the Plex Media Server"
fi
z="0"
while [[ "${z}" -lt "${numLibraries}" ]]; do
    # Get the path for our library ID
    libraryPath="$(yq -p xml ".MediaContainer.Directory[${z}].Location.\"+@path\"" <<<"${curlOutput}")"
    libraryName="$(yq -p xml ".MediaContainer.Directory[${z}].\"+@title\"" <<<"${curlOutput}")"
    libraryId="$(yq -p xml ".MediaContainer.Directory[${z}].\"+@key\"" <<<"${curlOutput}")"
    printOutput "4" "Found library [${libraryName}] at path [${libraryPath}] with ID [${libraryId}]"
    (( z++ ))
done
printOutput "3" "Validated Plex Media Server: ${serverName} [Version: ${serverVersion}] [Machine ID: ${serverMachineId}]"

searchPatterns=("TBA" "TBD")

for pattern in "${searchPatterns[@]}"; do
    # Get a list of matching items
    printOutput "3" "Checking for matching ${pattern} items in the Plex library"
    if ! callCurl "${plexAdd}/search?query=${pattern}&X-Plex-Token=${plexToken}"; then
        printOutput "1" "Unable to preform search for pattern [${pattern}] within the Plex Media Server"
        continue
    fi

    # Get a list of matching items
    while read -r i; do
        # ${i} is the episode rating key
        # Get the item's parent library ID
        itemLibraryId="$(yq -p xml ".MediaContainer.Video  | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${i}\" ) .\"+@librarySectionID\"" <<<"${curlOutput}")"
        # Get the item's parent series rating key
        itemSeriesId="$(yq -p xml ".MediaContainer.Video  | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${i}\" ) .\"+@grandparentRatingKey\"" <<<"${curlOutput}")"
        # Get the item's parent season rating key
        itemSeasonId="$(yq -p xml ".MediaContainer.Video  | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${i}\" ) .\"+@parentRatingKey\"" <<<"${curlOutput}")"
        # Get the item's series title
        itemSeriesTitle="$(yq -p xml ".MediaContainer.Video  | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${i}\" ) .\"+@grandparentTitle\"" <<<"${curlOutput}")"
        # Get the item's season index
        itemSeasonIndex="$(yq -p xml ".MediaContainer.Video  | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${i}\" ) .\"+@parentIndex\"" <<<"${curlOutput}")"
        # Get the item's episode index
        itemEpisodeIndex="$(yq -p xml ".MediaContainer.Video  | ([] + .) | .[] | select ( .\"+@ratingKey\" == \"${i}\" ) .\"+@index\"" <<<"${curlOutput}")"
        
        # Print some useful information
        printOutput "3" "Found ${pattern} item in series: [${itemSeriesTitle}] - S$(printf '%02d' "${itemSeasonIndex}")E$(printf '%02d' "${itemEpisodeIndex}")"
        printOutput "4" "Item Library ID [${itemLibraryId}] | Series rating key [${itemSeriesId}] | Season rating key [${itemSeasonId}] | Episode rating key [${i}]"
        
        # Verify that we're not ignore the library ID
        for ii in "${ignoreLibraries[@]}"; do
            if [[ "${itemLibraryId}" == "${ii}" ]]; then
                # It matches, ignore this item
                printOutput "3" "Matched library ID to ignored library ID [${ii}] -- Skipping"
                continue 2
            fi
        done
        # Verify that we're not ignore the series ID
        for ii in "${ignoreSeries[@]}"; do
            if [[ "${itemSeriesId}" == "${ii}" ]]; then
                # It matches, ignore this item
                printOutput "3" "Matched series ID to ignored series ID [${ii}] -- Skipping"
                continue 2
            fi
        done
        # Verify that we're not ignore the season ID
        for ii in "${ignoreSeasons[@]}"; do
            if [[ "${itemSeasonId}" == "${ii}" ]]; then
                # It matches, ignore this item
                printOutput "3" "Matched season ID to ignored season ID [${ii}] -- Skipping"
                continue 2
            fi
        done
        # Verify that we're not ignore the file ID
        for ii in "${ignoreEpisodes[@]}"; do
            if [[ "${i}" == "${ii}" ]]; then
                # It matches, ignore this item
                printOutput "3" "Matched file ID to ignored file ID [${ii}] -- Skipping"
                continue 2
            fi
        done
        
        # If we've gotten this far, we can safely add the file rating key to our refresh array
        plexArr+=("${i}")
        
        # Store the pretty-title for later
        
        titleArr["${i}"]="${itemSeriesTitle} - S$(printf '%02d' "${itemSeasonIndex}")E$(printf '%02d' "${itemEpisodeIndex}")"
        printOutput "4" "Added item to metadata refresh queue"
    done < <(yq -p xml ".MediaContainer.Video  | ([] + .) | .[] | .\"+@ratingKey\"" <<<"${curlOutput}")
done

if [[ "${#plexArr[@]}" -ge "1" ]]; then
    printOutput "3" "Detected ${#plexArr[@]} items in Plex under a \"TBA/TBD\" title"
    for ratingKey in "${plexArr[@]}"; do
        printOutput "3" "Processing: ${titleArr[${ratingKey}]}"
        if ! callCurlPut "${plexAdd}/library/metadata/${ratingKey}/refresh?X-Plex-Token=${plexToken}"; then
            printOutput "1" "Unable to issue a 'refresh' command for rating key [${ratingKey}]"
            continue
        fi
        
        # Because there's no "command queue" we can check like with Sonarr, we'll just sleep for 5 seconds and hope for the best
        sleep 5
        
        # Check the file metadata to see if there's a new title
        if ! callCurl "${plexAdd}/library/metadata/${ratingKey}?X-Plex-Token=${plexToken}"; then
            printOutput "1" "Unable to retrieve metadata for rating key [${ratingKey}]"
            continue
        fi
        newTitle="$(yq -p xml ".MediaContainer.Video.\"+@title\"" <<<"${curlOutput}")"
        if ! [[ "${newTitle}" =~ ^TB[AD]$ ]]; then
            printOutput "3" "Successful rename to [${newTitle}]"
            msgArr+=("Renamed ${titleArr[${ratingKey}]} to: ${newTitle}")
        else
            printOutput "4" "No new title available"
        fi
    done
else
    printOutput "4" "No items in queue to process"
fi

if [[ -n "${telegramBotId}" && -n "${telegramChannelId[0]}" && "${#msgArr[@]}" -ne "0" ]]; then
    printOutput "4" "Counted ${#msgArr[@]} messages to send:"
    for i in "${msgArr[@]}"; do
        printOutput "4" "- ${i}"
    done
    eventText="<b>Plex metadata update for ${serverName}</b>${lineBreak}$(printf '%s\n' "${msgArr[@]}")"
    printOutput "3" "Sending telegram messages"
    sendTelegramMessage "${eventText}"
fi

#############################
##       End of file       ##
#############################
cleanExit
