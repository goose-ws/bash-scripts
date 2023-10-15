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
# 2023-10-15
# Fixed the lockfile logic
# 2023-10-13
# Updated some spacing, and modified telegram send message command to allow for multiple channels
# Added a disclaimer for where to file issues above the "About" section
# 2023-05-25
# Added functionality to self determine container IP address
# Added config options for verbosity
# Both initiated via PR from ndoty
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
        curl -skL "https://raw.githubusercontent.com/goose-ws/bash-scripts/main/update-plex-in-docker.bash" -o "${0}"
        chmod +x "${0}"
        exit 0
    ;;
esac

#############################
##         Lockfile        ##
#############################
if [[ -e "${lockFile}" ]]; then
exit 0
else
echo "PID: ${$}
PWD: $(/bin/pwd)
Date: $(/bin/date)
RealPath: ${realPath}
\${@}: ${@}
\${#@}: ${#@}" > "${lockFile}"
fi

#############################
##    Standard Functions   ##
#############################
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
if ! [[ "$(jq ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
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
    if ! [[ "$(jq ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
        badExit "6" "Telegram channel check failed"
    else
        printOutput "2" "Telegram channel authenticated"
    fi
fi
for chanId in "${telegramChannelId[@]}"; do
    telegramOutput="$(curl -skL --data-urlencode "text=${eventText}" "https://api.telegram.org/bot${telegramBotId}/sendMessage?chat_id=${chanId}&parse_mode=html" 2>&1)"
    curlExitCode="${?}"
    if [[ "${curlExitCode}" -ne "0" ]]; then
        badExit "7" "Curl to Telegram returned a non-zero exit code: ${curlExitCode}"
    else
        printOutput "3" "Curl returned zero exit code"
        # Check to make sure Telegram returned a true value for ok
        if ! [[ "$(jq ".ok" <<<"${telegramOutput}")" == "true" ]]; then
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

#############################
##     Unique Functions    ##
#############################
function getNowPlaying {
nowPlaying="$(curl -skL -m 15 "${plexAdd}/status/sessions?X-Plex-Token=${plexAccessToken}" | grep -Eo "size=\"[[:digit:]]+\"")"
nowPlaying="${nowPlaying#*size=\"}"
nowPlaying="${nowPlaying%%\"*}"
printOutput "3" "Now playing count: ${nowPlaying}"
}

#############################
##   Initiate .env file    ##
#############################
source "${realPath%/*}/${scriptName%.bash}.env"
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
if [[ -z "${hostCodecPath}" ]] || ! [[ -d "${hostCodecPath%/}" ]]; then
    echo "Please specify a 'hostCodecPath=\"\"'"
    varFail="1"
fi
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

#############################
##       Update check      ##
#############################
if [[ "${updateCheck,,}" =~ ^(yes|true)$ ]]; then
    newest="$(curl -skL "https://raw.githubusercontent.com/goose-ws/bash-scripts/main/update-plex-in-docker.bash" | md5sum | awk '{print $1}')"
    current="$(md5sum "${0}" | awk '{print $1}')"
    if ! [[ "${newest}" == "${current}" ]]; then
        # Although it's not an error, we should always be allowed to print this message if update checks are allowed, so giving it priority 1
        printOutput "1" "A newer version is available"
    else
        printOutput "2" "No new updates available"
    fi
fi

#############################
##         Payload         ##
#############################
# Get the IP address of the Plex container
if ! docker version > /dev/null 2>&1; then
    badExit "9" "Do not appear to have permission to run on the docker socket (`docker version` returned non-zero exit code)"
fi

if [[ -z "${containerIp}" ]]; then
    printOutput "2" "Attempting to automatically determine container IP address"
    # Find the type of networking the container is using
    containerNetworking="$(docker container inspect --format '{{range $net,$v := .NetworkSettings.Networks}}{{printf "%s" $net}}{{end}}' "${containerName}")"
    printOutput "3" "Networking type: ${containerNetworking}"
    if [[ -z "${containerNetworking}" ]]; then
        printOutput "2" "No network type defined. Checking to see if networking is through another container."
        # IP address returned blank. Is it being networked through another container?
        containerIp="$(docker inspect "${containerName}" | jq ".[].HostConfig.NetworkMode")"
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

# Build our address
plexAdd="${plexScheme}://${containerIp}:${plexPort}"
printOutput "3" "Server address: ${plexAdd}"

# Make sure our server is reachable, and we can check our version
myVer="$(curl -skL -m 15 "${plexAdd}/servers?X-Plex-Token=${plexAccessToken}")"
curlExitCode="${?}"
if [[ "${curlExitCode}" -ne "0" ]]; then
    badExit "10" "Unable to check local version, curl returned non-zero exit code: ${curlExitCode}"
fi
myVer="$(grep -Ev "^<\?xml" <<<"${myVer}" | grep -Eo "version=\"([[:alnum:]]|\.|-)+\"")"
myVer="${myVer#*version=\"}"
myVer="${myVer%%\"*}"
if [[ "${myVer}" == "null" ]] || [[ -z "${myVer}" ]]; then
    badExit "11" "Unable to parse local version"
else
    printOutput "2" "Detected local version: ${myVer}"
fi

# Make sure we can check the latest version
currVer="$(curl -skL -m 15 "https://plex.tv/api/downloads/1.json?channel=${plexVersion}")"
curlExitCode="${?}"
if [[ "${curlExitCode}" -ne "0" ]]; then
    badExit "12" "Unable to check latest version, curl returned non-zero exit code: ${curlExitCode}"
fi
currVer="$(jq ".computer.${hostOS}.version" <<<"${currVer}")"
currVer="${currVer#\"}"
currVer="${currVer%\"}"
if [[ "${currVer}" == "null" ]] || [[ -z "${currVer}" ]]; then
    badExit "13" "Unable to parse latest version"
else
    printOutput "2" "Detected current version: ${currVer}"
fi

if [[ "${myVer}" == "${currVer}" ]]; then
    printOutput "2" "Versions match, no update needed"
    cleanExit;
fi

# If we've gotten this far, version strings do not match
myVer2="${myVer%-*}"
myVer2="${myVer2//./}"
currVer2="${currVer%-*}"
currVer2="${currVer2//./}"
if [[ "${myVer2}" -gt "${currVer2}" ]]; then
    # We already have a version more recent than the current, probably a beta/Plex Pass version
    printOutput "2" "Local version newer than current stable version."
    cleanExit;
fi

# Is anyone playing anything?
getNowPlaying;

if [[ "${nowPlaying}" -ne "0" ]]; then
    # At least one person is watching something
    # We'll try again at the next cron run
    printOutput "2" "Detected ${nowPlaying} users currently using Plex"
    cleanExit;
fi

# Nobody is watching anything. Maybe someone was between episodes? Let's wait 1 minute and check.
printOutput "3" "Sleeping for 60 seconds before re-checking play status"
sleep 60

# Is anyone playing anything?
getNowPlaying;

if [[ "${nowPlaying}" -ne "0" ]]; then
    # At least one person is watching something
    # We'll try again at the next cron run
    printOutput "2" "Detected ${nowPlaying} users currently using Plex"
    cleanExit;
fi

# Nice, nobody's watching anything. Let's restart the Docker container.
# Get the Docker container ID
printOutput "2" "Stopping container"
if docker stop "${containerName}"; then
    printOutput "3" "Container stopped successfully"
else
    badExit "14" "Unable to stop container"
fi

# Clean out the Codecs folder, because apparently that sometimes breaks things between upgrades if you don't
# https://old.reddit.com/r/PleX/comments/lzwkyc/eae_timeout/gq4xcat/
printOutput "2" "Cleaning out Codecs directory"
if rm -rf "${hostCodecPath%/}"/*; then
    printOutput "3" "Codecs directory cleared successfully"
else
    badExit "15" "Unable to clear Codecs directory"
fi

printOutput "2" "Starting container"
if docker start "${containerName}"; then
    printOutput "3" "Container started successfully"
else
    badExit "16" "Unable to start container"
fi

if [[ -n "${telegramBotId}" && -n "${telegramChannelId}" && "${#msgArr[@]}" -ne "0" ]]; then
    dockerHost="$(</etc/hostname)"
    if [[ "${outputVerbosity}" -ge "3" ]]; then
    printOutput "3" "Counted ${#msgArr[@]} messages to send:"
        for i in "${msgArr[@]}"; do
            printOutput "3" "- ${i}"
        done
    fi
    eventText="$(printf "<b>Plex Update for ${dockerHost%%.*}</b>\r\n\r\nPlex Media Server restarted for update from version <i>${myVer}</i> to version <i>${currVer}</i>")"
    printOutput "3" "Got hostname: ${dockerHost}"
    printOutput "2" "Telegram messaging enabled -- Checking credentials"
    sendTelegramMessage
fi

#############################
##       End of file       ##
#############################
cleanExit
