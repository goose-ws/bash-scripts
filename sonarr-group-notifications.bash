#!/usr/bin/env bash

#############################
##          About          ##
#############################
# This script serves to group notifications when passed from Sonarr, so that if an entire series is
# being grabbed, it will send you one notification of everything instead of a thousand notifications
# of individual files.

# If you run into any problems with me, create an issue on GitHub, or reach out via IRC in #goose
# on Libera -- My response time should be less than 24 hours, and I'll help as best I can.

#############################
##        Changelog        ##
#############################
# 2023-03-12
# Initial commit

#############################
##       Installation      ##
#############################
# This script was only built to work with the LinuxServer Docker image of Sonarr.

# 1. Download the script .bash file to a persistently mounted directory within the container (/config/ is good)
# 2. Download the script .env file to a persistently mounted directory within the container (/config/ is good)
# 2. Set the script  as executable (chmod +x) and chown the script and .env files to the same UID/GID that Sonarr runs as
# 4. Edit the .env file to your liking
# 5. Set up a connection in Sonarr for a custom script:
# 5a. You can name is whatever you want
# 5b. The only box you can use for "Notification Triggers" would be "On Import"
# 5c. Path is going to be docker relative (/config/sonarr-group-notifications.bash)
# 5d. Test/Save/Close

###################################################
### Begin source, please don't edit below here. ###
###################################################

if [[ -z "${BASH_VERSINFO}" || -z "${BASH_VERSINFO[0]}" || "${BASH_VERSINFO[0]}" -lt "4" ]]; then
    echo "This script requires Bash version 4 or greater"
    exit 255
fi
depArr=("curl" "jq" "mkdir" "printf" "rm" "sort")
if ! [[ -e "/.dockerenv" ]]; then
    depArr+=("docker")
fi
depFail="0"
for i in "${depArr[@]}"; do
    if [[ "${i:0:1}" == "/" ]]; then
        if ! [[ -e "${i}" ]]; then
            echo "${i}\\tnot found"
            depFail="1"
        fi
    else
        if ! command -v ${i} > /dev/null 2>&1; then
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

# Used internally for debugging
debugDir="${realPath%/*}/.${scriptName}.debug"
mkdir -p "${debugDir}"
exec 2> "${debugDir}/${$} $(date).debug"
env
set -x
if [[ "${1}" == "-s" ]] && [[ -e "${2}" ]]; then
    source "${2}"
    # Can pass test data with the -s flag (-s /path/to/file)
fi

# We can run the positional parameter options without worrying about lockFile
case "${1,,}" in
    "-h"|"--help")
        echo "-h  --help      Displays this help message"
        echo ""
        echo "-u  --update    Self update to the most recent version"
        exit 0
    ;;
    "-u"|"--update")
        curl -skL "https://raw.githubusercontent.com/goose-ws/bash-scripts/main/sonarr-group-notifications.bash" -o "${0}"
        chmod +x "${0}"
        exit 0
    ;;
esac

echo "${$}" >> "${lockFile}"

read -ra pidLine < <(sort -n "${lockFile}")
while [[ "${$}" -ne "${pidLine[0]}" ]]; do
    echo "Not my turn yet...trying again at $(date -d @$(( $(date +%s) + 5)) +%H:%M:%S)"
    sleep 5
    read -ra pidLine < <(sort -n "${lockFile}")
done

# Define some functions
badExit () {
echo "${2}"
firstLine="1"
for i in "${arr[@]}"; do
    if [[ "${i}" -ne "${n}" ]] && [[ "${firstLine}" -eq "1" ]]; then
        newLock="${i}"
        firstLine="0"
    elif [[ "${i}" -ne "${n}" ]] && [[ "${firstLine}" -eq "0" ]]; then
        newLock="${newLock}$(printf "\r\n\r\n")${i}"
    fi
done
if [[ "${#newLock}" -ne "0" ]]; then
    echo "${newLock}" > "${lockFile}"
else
    rm -f "${lockFile}"
fi
exit "${1}"
}

cleanExit () {
firstLine="1"
for i in "${arr[@]}"; do
    if [[ "${i}" -ne "${n}" ]] && [[ "${firstLine}" -eq "1" ]]; then
        newLock="${i}"
        firstLine="0"
    elif [[ "${i}" -ne "${n}" ]] && [[ "${firstLine}" -eq "0" ]]; then
        newLock="${newLock}$(printf "\r\n\r\n")${i}"
    fi
done
if [[ "${#newLock}" -ne "0" ]]; then
    echo "${newLock}" > "${lockFile}"
else
    rm -f "${lockFile}"
fi
exit 0
}

list2range() {
# Borrowed from https://stackoverflow.com/questions/13708705/in-bash-how-to-convert-number-list-into-ranges-of-numbers
local first a b string IFS
local -a array
local endofrange=0
while [[ "${#}" -ge "1" ]]; do  
    a="${1}"; shift; b="${1}"
    if [[ "$(( a + 1))" -eq "${b}" ]]; then
        if [[ "${endofrange}" -eq "0" ]]; then
            first="${a}"
            endofrange="1"
        fi
    else
        if [[ "${endofrange}" -eq "1" ]]; then
            if [[ "${first}" -lt "10" ]]; then
                first="0${first}"
            fi
            if [[ "${a}" -lt "10" ]]; then
                a="0${a}"
            fi
            array+=("${first}-${a}")
        else
            if [[ "${a}" -lt "10" ]]; then
                a="0${a}"
            fi
            array+=("${a}")
        fi
        endofrange="0"
    fi
done
IFS=","; epOut="$(echo "${array[*]}")"
unset array
}

spoolText () {
inArray="0"
for ii in "${uniq_qualityArr[@]}"; do
    if [[ "${ii}" == "${qualityArr[${n}]}" ]]; then
        inArray="1"
    fi
done
qualLine="${uniq_qualityArr[@]}"
qualLine="${qualLine// / & }"
if [[ "${inArray}" -eq "0" ]]; then
    uniq_qualityArr+=("${qualityArr[${n}]}")
fi
# I am a bad human for passing a variable to a function without quoting it.
# A very bad human. And I repent for my sins committed here.
# TODO: Find a way to quote this variable but still pass each item of the array as a separate positional parameter
list2range ${numArr[@]};
if [[ "${prevSeason}" -lt "10" ]]; then
    if [[ "${n}" -eq "$(( ${#seasonArr[@]} - 1 ))" ]]; then
        prevSeason="${i}"
    fi
    # Pad with zero
    prevSeason="0${prevSeason}"
fi
# If this is our first line out, we should name the show
if [[ -z "${eventText}" ]]; then
    eventText="<b>Multiple Episodes Downloaded</b>$(printf "\r\n\r\n")${sonarr_series_title}$(printf "\r\n\r\n")S${prevSeason} E${epOut} [${qualLine}]"
else
    eventText="${eventText}$(printf "\r\n\r\n")S${prevSeason} E${epOut} [${qualLine}]"
fi
unset numArr
}
buildArray () {
numArr+=("${episodeArr[${n}]}")
inArray="0"
for ii in "${uniq_qualityArr[@]}"; do
    if [[ "${ii}" == "${qualityArr[${n}]}" ]]; then
        inArray="1"
    fi
done
if [[ "${inArray}" -eq "0" ]]; then
    uniq_qualityArr+=("${qualityArr[${n}]}")
fi
}

addGroupedNotification () {
echo "${4}|${5}|${6}" >> "${notesFile}"
}

sendGroupNotification () {
# Let's read our data into arrays we can work with
readarray -t notes < <(sort -n -k 1,1 -k 2,2 -t "|" "${notesFile}")
for i in "${notes[@]}"; do
    season="${i%%|*}"
    episode="${i#*|}"
    episode="${episode%|*}"
    quality="${i##*|}"
    seasonArr+=("${season}")
    episodeArr+=("${episode}")
    qualityArr+=("${quality}")
done
# Now let's manipulate our arrays to format the data the way we want it
n=0
for i in "${seasonArr[@]}"; do
    echo "${i}: ${n} - ${#seasonArr[@]}"
    if [[ "${n}" -eq "0" ]] || [[ "${i}" -eq "${prevSeason}" ]]; then
        if [[ "${n}" -ne "$(( ${#seasonArr[@]} - 1 ))" ]]; then
            buildArray;
        else
            # This is the final itemnumArr+=("${episodeArr[${n}]}")
            # If our current season is different than our previous season, go ahead and spool those notifications
            spoolText;
            buildArray;
            spoolText;
        fi
    else
        if [[ "${n}" -ne "$(( ${#seasonArr[@]} - 1 ))" ]]; then
            # We're into a new season, so let's process the completed data
            spoolText;
        else
            # This is the final itemnumArr+=("${episodeArr[${n}]}")
            # If our current season is different than our previous season, go ahead and spool those notifications
            spoolText;
            buildArray;
            spoolText;
        fi
    fi
    prevSeason="${i}"
    (( n++ ))
done
# We should now be able to send our notification
telegramOutput="$(curl -skL --data-urlencode "text=${eventText}" "https://api.telegram.org/bot${telegramBotId}/sendMessage?chat_id=${telegramChannelId}&parse_mode=html" 2>&1)"
if [[ "${?}" -ne "0" ]]; then
    echo "API call to Telegram failed"
else
    # Check to make sure Telegram returned a true value for ok
    if ! [[ "$(jq ".ok" <<<"${telegramOutput}")" == "true" ]]; then
        echo "Failed to send Telegram message:"
        echo ""
        echo "${telegramOutput}" | jq
        echo ""
    fi
fi
# And finally, clean out that old notes file
rm -f "${notesFile}"
}

sendSingleNotification () {
# 1 - Debug code
# 2 - Series Title
# 3 - Episode Title
# 4 - Season digit
# 5 - Episode digit
# 6 - Quality
# Pad the episode with a zero if necessary
if [[ "${4}" -le "0" ]] && [[ "${4:0:1}" ]]; then
    set 4="0${4}"
fi
if [[ "${5}" -le "0" ]] && [[ "${5:0:1}" ]]; then
    set 5="0${5}"
fi
eventText="<b>Episode Downloaded</b>$(printf "\r\n\r\n")${2} - S${4} E${5}: ${3} [${6}]"
telegramOutput="$(curl -skL --data-urlencode "text=${eventText}" "https://api.telegram.org/bot${telegramBotId}/sendMessage?chat_id=${telegramChannelId}&parse_mode=html" 2>&1)"
if [[ "${?}" -ne "0" ]]; then
    echo "API call to Telegram failed"
else
    # Check to make sure Telegram returned a true value for ok
    if ! [[ "$(jq ".ok" <<<"${telegramOutput}")" == "true" ]]; then
        echo "Failed to send Telegram message:"
        echo ""
        echo "${telegramOutput}" | jq
        echo ""
    fi
fi
}

# Get config options
source "${realPath%/*}/${scriptName%.bash}.env"

# Sanity checks
# First let's get the IP address of the container so we can interface with its API
# If we're inside of docker, we can use localhost
if [[ -e "/.dockerenv" ]]; then
    sonarrIp="127.0.0.1"
else
    sonarrIp="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${sonarrContainerName}")"
    if [[ -z "${sonarrIp}" ]]; then
        # IP address returned blank. Is it being networked through another container?
        sonarrIp="$(docker inspect "${sonarrContainerName}" | jq ".[].HostConfig.NetworkMode")"
        sonarrIp="${sonarrIp#\"}"
        sonarrIp="${sonarrIp%\"}"
        if [[ "${sonarrIp%%:*}" == "container" ]]; then
            # Networking is being run through another container. So we need that container's IP address.
            sonarrIp="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${sonarrIp#container:}")"
        else
            unset sonarrIp
        fi
    fi
fi
if [[ -z "${sonarrIp}" ]]; then
    badExit "1" "Unable to determine sonarr IP address";
fi

# Now let's get some values from the config file
if [[ -e "/.dockerenv" ]]; then
    while read -r i; do
        configArr+=("${i}")
    done < "/config/config.xml"
else
    while read -r i; do
        configArr+=("${i}")
    done < <(docker exec "${sonarrContainerName}" cat /config/config.xml)
fi
if [[ "${#configArr[@]}" -eq "0" ]]; then
    badExit "2" "Unable to read Sonarr config file";
fi

# Now let's iterate through the array to extract what we want
for i in "${configArr[@]}"; do
    type="${i#*<}"
    type="${type%%>*}"
    case "${type}" in
        Port)
            sonarrPort="${i#*<Port>}"
            sonarrPort="${sonarrPort%</Port>}"
        ;;
        UrlBase)
            sonarrBase="${i#*<UrlBase>}"
            sonarrBase="${sonarrBase%</UrlBase>}"
        ;;
        SslPort)
            sonarrSslPort="${i#*<SslPort>}"
            sonarrSslPort="${sonarrSslPort%</SslPort>}"
        ;;
        EnableSsl)
            sonarrUseSsl="${i#*<EnableSsl>}"
            sonarrUseSsl="${sonarrUseSsl%</EnableSsl>}"
        ;;
        ApiKey)
            sonarrApiKey="${i#*<ApiKey>}"
            sonarrApiKey="${sonarrApiKey%</ApiKey>}"
        ;;
    esac
done
if ! [[ "${sonarrPort}" =~ ^[0-9]+$ ]]; then
    badExit "3" "Unable to determine Sonarr port";
fi
if [[ "${sonarrUseSsl}" == "True" ]]; then 
    sonarrScheme="https"
    if ! [[ "${sonarrPort}" =~ ^[0-9]+$ ]]; then
        badExit "4" "Unable to determine Sonarr SSL port";
    fi
elif [[ "${sonarrUseSsl}" == "False" ]]; then
    sonarrScheme="http"
else
    badExit "5" "Unable to determine if SSL is in use or not";
fi
if [[ -z "${sonarrApiKey}" ]]; then
    badExit "6" "Unable to determine Sonarr API key";
fi
sonarrAddress="${sonarrScheme}://${sonarrIp}:${sonarrPort}${sonarrBase}"

# Can we check for updates?
if ! [[ "${updateCheck,,}" =~ ^(yes|no|true|false)$ ]]; then
    echo "Option to check for updates not valid. Assuming no."
    updateCheck="No"
fi

# Let's make sure we have a directory where we can keep our notes.
scriptPath="$(realpath "${0}")"
scriptName="${0##*/}"
notesDir="${scriptPath%/*}/.${scriptName%.bash}-notes"
mkdir -p "${notesDir}"
if ! [[ -d "${notesDir}" ]]; then
    badExit "7" "Unable to create ${notesDir}";
fi
if ! [[ -w "${notesDir}" ]]; then
    badExit "8" "Unable to write to ${notesDir}";
fi
notesFile="${notesDir}/${sonarr_series_id}"

# Check our first parameter to see if this is a test run
if [[ "${1,,}" == "--test" ]] || [[ "${1,,}" == "-t" ]] || [[ "${sonarr_eventtype}" == "Test" ]]; then
    # Let's check to make sure our messaging credentials are valid
    telegramOutput="$(curl -skL "https://api.telegram.org/bot${telegramBotId}/getMe" 2>&1)"
    curlExitCode="${?}"
    if [[ "${curlExitCode}" -ne "0" ]]; then
        badExit "9" "Curl to Telegram to check Bot ID returned a non-zero exit code";
    elif [[ -z "${telegramOutput}" ]]; then
        badExit "10" "Curl to Telegram to check Bot ID returned an empty string";
    else
        echo "Curl returned good exit code"
    fi
    if ! [[ "$(jq ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
        badExit "11" "Telegram bot API check failed";
    else
        echo "Telegram Bot API check succeded"
        telegramOutput="$(curl -skL "https://api.telegram.org/bot${telegramBotId}/getChat?chat_id=${telegramChannelId}")"
        curlExitCode="${?}"
        if [[ "${curlExitCode}" -ne "0" ]]; then
            badExit "12" "Curl to Telegram to check channel returned a non-zero exit code";
        elif [[ -z "${telegramOutput}" ]]; then
            badExit "13" "Curl to Telegram to check channel returned an empty string";
        else
            echo "Curl returned good exit code"
        fi
        if ! [[ "$(jq ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
            badExit "14" "Telegram channel API check failed";
        else
            echo "Telegram channel API check succeded"
        fi
    fi
    # Let's test to make sure our API is working

    apiTest="$(curl -skL -H "X-Api-Key: ${sonarrApiKey}" "${sonarrAddress}/api/v3/system/status" | jq ".appName")"
    apiTest="${apiTest//\"/}"
    if ! [[ "${apiTest}" == "Sonarr" ]]; then
        badExit "15" "API test failed";
    else
        echo "Sonarr API check succeded"
    fi
    # Because everything is health checked before this point, we can simply quit here
    cleanExit;
fi

if [[ "${updateCheck,,}" =~ ^(yes|true)$ ]]; then
    newest="$(curl -skL "https://raw.githubusercontent.com/goose-ws/bash-scripts/main/sonarr-group-notifications.bash" | md5sum | awk '{print $1}')"
    current="$(md5sum "${0}" | awk '{print $1}')"
    if ! [[ "${newest}" == "${current}" ]]; then
        echo "A newer version is available"
    fi
fi

# Now that we're finally through our sanity checks, let's find out what we're doing.
# Presumably we were activated to process a notification. How many episodes were we passed?
if [[ "${sonarr_episodefile_episodecount}" -gt "1" ]]; then
    # It was multiple, so let's split them into our array
    IFS="," read -ra seriesEpNum <<< "${sonarr_episodefile_episodenumbers}"
    IFS="|" read -ra seriesEpTitle <<< "${sonarr_episodefile_episodetitles}"
elif [[ "${sonarr_episodefile_episodecount}" -eq "1" ]]; then
    seriesEpNum+=("${sonarr_episodefile_episodenumbers}")
    seriesEpTitle+=("${sonarr_episodefile_episodetitles}")
else
    badExit "16" "Unexpected input from Sonarr"
fi

# Number of episodes and episode titles should all contain equal values.
if ! [[ "${#seriesEpNum[@]}" -eq "${#seriesEpTitle[@]}" ]]; then
    badExit "17" "Error when parsing input from sonarr"
fi

# Our data looks good, so let's finally process it.
# Given the above debug information, we should check the queue to see if anything else of this series ID is downloading
# Load the details of the queue into a variable
queueDetails="$(curl -skL -H "X-Api-Key: ${sonarrApiKey}" "${sonarrAddress}/api/v3/queue/details")"
numSeriesItems="0"
numItems="$(( "$(jq length <<<"${queueDetails}")" - 1 ))"
i="0"
while [[ "${i}" -lt "${numItems}" ]]; do
    # First check to make sure the download ID isn't the same as ours, we don't need to consider the download we were activated for as still being in the queue
    if ! [[ "$(jq ".[${i}].downloadId" <<<"${queueDetails}")" == "\"${sonarr_download_id}\"" ]]; then
        if [[ "$(jq ".[${i}].seriesId" <<<"${queueDetails}")" == "${sonarr_series_id}" ]]; then
            # It is not our current download, but the series number matches. Therefore, it is another item for the series.
            numSeriesItems="$(( numSeriesItems + 1 ))"
        fi
    fi
    (( i++ ))
done

if [[ -e "${notesFile}" ]]; then
    if [[ "${numSeriesItems}" -ne "0" ]]; then    
        for i in "${seriesEpNum[@]}"; do
            addGroupedNotification "1" "${sonarr_series_title}" "${seriesEpTitle[${n}]}" "${sonarr_episodefile_seasonnumber}" "${seriesEpNum[${n}]}" "${sonarr_episodefile_quality}";
            (( n++ ))
        done
    elif [[ "${numSeriesItems}" -eq "0" ]]; then    
        for i in "${seriesEpNum[@]}"; do
            addGroupedNotification "1" "${sonarr_series_title}" "${seriesEpTitle[${n}]}" "${sonarr_episodefile_seasonnumber}" "${seriesEpNum[${n}]}" "${sonarr_episodefile_quality}";
            (( n++ ))
        done
        sendGroupNotification;
    else
        badExit "18" "Unable to determine number of items in queue"
    fi
elif ! [[ -e "${notesFile}" ]]; then
    if [[ "${numSeriesItems}" -ne "0" ]]; then    
        for i in "${seriesEpNum[@]}"; do
            addGroupedNotification "1" "${sonarr_series_title}" "${seriesEpTitle[${n}]}" "${sonarr_episodefile_seasonnumber}" "${seriesEpNum[${n}]}" "${sonarr_episodefile_quality}";
            (( n++ ))
        done
    elif [[ "${numSeriesItems}" -eq "0" ]]; then
        if [[ "${sonarr_episodefile_episodecount}" -gt "${maxConcurrent}" ]]; then
            for i in "${seriesEpNum[@]}"; do
                addGroupedNotification "1" "${sonarr_series_title}" "${seriesEpTitle[${n}]}" "${sonarr_episodefile_seasonnumber}" "${seriesEpNum[${n}]}" "${sonarr_episodefile_quality}";
                (( n++ ))
            done
            sendGroupNotification;
        elif [[ "${sonarr_episodefile_episodecount}" -le "${maxConcurrent}" ]]; then
            n=0
            for i in "${seriesEpNum[@]}"; do
                sendSingleNotification "4" "${sonarr_series_title}" "${seriesEpTitle[${n}]}" "${sonarr_episodefile_seasonnumber}" "${seriesEpNum[${n}]}" "${sonarr_episodefile_quality}";
                (( n++ ))
            done
        else
            badExit "19" "Unable to count episodes passed against max concurrent"
        fi
    else
        badExit "20" "Unable to determine number of items in queue"
    fi
else
    badExit "21" "Unable to determine if notes file exists"
fi

cleanExit;
