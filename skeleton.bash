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
# URL of where the most updated version of the script is
updateURL="https://raw.githubusercontent.com/goose-ws/bash-scripts/main/skeleton.bash"

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
        if curl -skL "${updateURL}" -o "${0}"; then
            if chmod +x "${0}"; then
                echo "Update complete"
                exit 0
            else
                echo "Update downloaded, but unable to `chmod +x`"
                exit 255
            fi
        else
            echo "Unable to download update"
            exit 255
        fi
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
    badExit "0" "Curl to Telegram to check Bot ID returned a non-zero exit code: ${curlExitCode}"
elif [[ -z "${telegramOutput}" ]]; then
    badExit "0" "Curl to Telegram to check Bot ID returned an empty string"
else
    printOutput "3" "Curl exit code and null output checks passed"
fi
if ! [[ "$(jq ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
    badExit "0" "Telegram bot API check failed"
else
    printOutput "2" "Telegram bot API key authenticated"
    telegramOutput="$(curl -skL "https://api.telegram.org/bot${telegramBotId}/getChat?chat_id=${telegramChannelId}")"
    curlExitCode="${?}"
    if [[ "${curlExitCode}" -ne "0" ]]; then
        badExit "0" "Curl to Telegram to check channel returned a non-zero exit code: ${curlExitCode}"
    elif [[ -z "${telegramOutput}" ]]; then
        badExit "0" "Curl to Telegram to check channel returned an empty string"
    else
        printOutput "3" "Curl exit code and null output checks passed"
    fi
    if ! [[ "$(jq ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
        badExit "0" "Telegram channel check failed"
    else
        printOutput "2" "Telegram channel authenticated"
    fi
fi
for chanId in "${telegramChannelId[@]}"; do
    telegramOutput="$(curl -skL --data-urlencode "text=${eventText}" "https://api.telegram.org/bot${telegramBotId}/sendMessage?chat_id=${chanId}&parse_mode=html" 2>&1)"
    curlExitCode="${?}"
    if [[ "${curlExitCode}" -ne "0" ]]; then
        badExit "0" "Curl to Telegram returned a non-zero exit code: ${curlExitCode}"
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


#############################
##   Initiate .env file    ##
#############################
source "${realPath%/*}/${scriptName%.bash}.env"
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

# Quit if failures
if [[ "${varFail}" -eq "1" ]]; then
    badExit "0" "Please fix above errors"
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
    else
        printOutput "2" "No new updates available"
    fi
fi

#############################
##         Payload         ##
#############################
# If using docker, we should ensure we have permissions to do so
if ! docker version > /dev/null 2>&1; then
    badExit "0" "Do not appear to have permission to run on the docker socket (`docker version` returned non-zero exit code)"
fi


#############################
##       End of file       ##
#############################
cleanExit
