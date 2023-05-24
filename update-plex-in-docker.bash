#!/usr/bin/env bash

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
# 2023-03-16
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

if [[ -z "${BASH_VERSINFO}" || -z "${BASH_VERSINFO[0]}" || "${BASH_VERSINFO[0]}" -lt "4" ]]; then
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

# # Used internally for debugging
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
        curl -skL "https://raw.githubusercontent.com/goose-ws/bash-scripts/main/update-plex-in-docker.bash" -o "${0}"
        chmod +x "${0}"
        exit 0
    ;;
esac

echo "${$}" >> "${lockFile}"

# Define some functions
badExit () {
echo "${2}"
rm -f "${lockFile}"
exit "${1}"
}

cleanExit () {
rm -f "${lockFile}"
exit 0
}

sendTelegramMessage () {
eventText="<b>Episode Downloaded</b>$(printf "\r\n\r\n")${@}"
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

getNowPlaying () {
nowPlaying="$(curl -skL -m 15 "${plexAdd}/status/sessions?X-Plex-Token=${plexAccessToken}" | grep -Eo "size=\"[[:digit:]]+\"")"
nowPlaying="${nowPlaying#*size=\"}"
nowPlaying="${nowPlaying%%\"*}"
}

# Get config options
source "${realPath%/*}/${scriptName%.bash}.env"
if [[ -z "${plexAccessToken}" ]]; then
    echo "Please specify a 'plexAccessToken=\"\"'"
    varFail="1"
fi
if [[ -z "${plexContainerName}" ]]; then
    echo "Please specify a 'plexContainerName=\"\"'"
    varFail="1"
fi
if [[ -z "${plexIp}" ]]; then
    if [[ ${verboseLogging} == "True" ]]; then echo "plexIp ENV not supplied, will attempt retrieving from Docker Container ${plexContainerName}"; fi
    getIpFromDocker="True"
elif ! [[ "${plexIp}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
    echo "Please specify a valid plexIp x.x.x.x, or leave blank 'plexIP=\"${plexIp}\"'"
    varFail="1"
elif [[ $(ping -c 1 ${plexIp}; echo $?) == 1 ]]; then
    echo "${plexIp} is unreachable, please specify a reachable Plex IP"
    varFail="1"
else
    if [[ ${verboseLogging} == "True" ]]; then echo "${plexIp} is reachable on your network"; fi
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
if [[ "${varFail}" -eq "1" ]]; then
    badExit "1" "Please fix above errors";
fi

### Source
# Can we check for updates?
if ! [[ "${updateCheck,,}" =~ ^(yes|no|true|false)$ ]]; then
    echo "Option to check for updates not valid. Assuming no."
    updateCheck="No"
fi
if [[ "${updateCheck,,}" =~ ^(yes|true)$ ]]; then
    newest="$(curl -skL "https://raw.githubusercontent.com/goose-ws/bash-scripts/main/update-plex-in-docker.bash" | md5sum | awk '{print $1}')"
    current="$(md5sum "${0}" | awk '{print $1}')"
    if ! [[ "${newest}" == "${current}" ]]; then
        echo "A newer version is available"
    fi
fi

### Build variable ${plexServerAddress} here
# Get the IP address of the Plex container
if [[ "${getIpFromDocker}" == "True" ]]; then
	dockerIp="$(docker inspect "${plexContainerName}" | jq ".[].HostConfig.NetworkMode")"
	dockerIp="${dockerIp#\"}"
	dockerIp="${dockerIp%\"}"
	if [[ "${dockerIp%%:*}" == "container" ]]; then
                # Networking is being run through another container. So we need that container's IP address.
		dockerIp="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${dockerIp#container:}")"
	else
		unset dockerIp
		dockerIp="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${plexContainerName}")"
	fi
        if ! [[ "${dockerIp}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
            echo "Got Bad Plex IP Docker inspect: ${dockerIp}"
            badExit "2" "Unable to determine PMS IP address, try specifying directly in .env with plexIp=\"x.x.x.x.\"";
        else
	    if [[ ${verboseLogging} == "True" ]]; then echo "Successfully grabed the IP ${dockerIp} from Docker"; fi
            plexIp=dockerIp
        fi
fi

# We can assume the scheme is http and port is 32400 unless someone reports otherwise
plexScheme="${plexScheme:=http}"
plexPort="${plexPort:=32400}"

# Build our address
plexAdd="${plexScheme}://${plexIp}:${plexPort}"

# Make sure we can check our version
myVer="$(curl -skL -m 15 "${plexAdd}/servers?X-Plex-Token=${plexAccessToken}")"
if [[ "${?}" -ne "0" ]]; then
    badExit "3" "Unable to check local version";
fi

# Make sure we can check the latest version
currVer="$(curl -skL -m 15 "https://plex.tv/api/downloads/1.json?channel=${plexVersion}")"
if [[ "${?}" -ne "0" ]]; then
    badExit "4" "Unable to check latest version";
fi

myVer="$(grep -Ev "^<\?xml" <<<"${myVer}" | grep -Eo "version=\"([[:alnum:]]|\.|-)+\"")"
myVer="${myVer#*version=\"}"
myVer="${myVer%%\"*}"
if [[ "${myVer}" == "null" ]] || [[ -z "${myVer}" ]]; then
    badExit "5" "Unable to parse local version";
fi

currVer="$(jq ".computer.${hostOS}.version" <<<"${currVer}")"
currVer="${currVer#\"}"
currVer="${currVer%\"}"
if [[ "${currVer}" == "null" ]] || [[ -z "${currVer}" ]]; then
    badExit "6" "Unable to parse latest version";
fi

if [[ ${verboseLogging} == "True" ]]; then echo "My Version: ${myVer} <> Current Version: ${currVer}"; fi

if [[ "${myVer}" == "${currVer}" ]]; then
	if [[ ${verboseLogging} == "True" ]]; then echo "Versions match, no need for update"; fi
        cleanExit;
fi

# If we've gotten this far, version strings do not match
myVer2="${myVer%-*}"
myVer2="${myVer2//./}"
currVer2="${currVer%-*}"
currVer2="${currVer2//./}"
if [[ "${myVer2}" -gt "${currVer2}" ]]; then
    if [[ ${verboseLogging} == "True" ]]; then echo "We already have a version more recent (${myVer}) than the current (${currVer}), probably a beta/Plex Pass version"; fi
    cleanExit;
fi

# Is anyone playing anything?
getNowPlaying;

if [[ "${nowPlaying}" -ne "0" ]]; then
    if [[ ${verboseLogging} == "True" ]]; then echo "At least one person is watching something"; fi
    if [[ ${verboseLogging} == "True" ]]; then echo "We'll try again at the next cron run"; fi
	cleanExit;
fi

# Nobody is watching anything. Maybe someone was between episodes? Let's wait 1 minute and check.
sleep 60

# Is anyone playing anything?
getNowPlaying;

if [[ "${nowPlaying}" -ne "0" ]]; then
    if [[ ${verboseLogging} == "True" ]]; then echo "At least one person is still watching something"; fi
    if [[ ${verboseLogging} == "True" ]]; then echo "We'll try again at the next cron run"; fi
	cleanExit;
fi

if [[ ${verboseLogging} == "True" ]]; then echo "Nice, nobody's watching anything. Let's restart the Docker container."; fi
# Get the Docker container ID
docker stop "${plexContainerName}"

# Clean out the Codecs folder, because apparently that sometimes breaks things between upgrades if you don't
# https://old.reddit.com/r/PleX/comments/lzwkyc/eae_timeout/gq4xcat/
rm -rf "${hostCodecPath%/}"/*

docker start "${plexContainerName}"
dockerHost="$(</etc/hostname)"
if [[ -n "${telegramBotId}" && -n "${telegramChannelId}" ]]; then
	# Let's check to make sure our messaging credentials are valid
    telegramOutput="$(curl -skL "https://api.telegram.org/bot${telegramBotId}/getMe" 2>&1)"
    curlExitCode="${?}"
    if [[ "${curlExitCode}" -ne "0" ]]; then
        badExit "7" "Curl to Telegram to check Bot ID returned a non-zero exit code";
    elif [[ -z "${telegramOutput}" ]]; then
        badExit "8" "Curl to Telegram to check Bot ID returned an empty string";
    fi
    if ! [[ "$(jq ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
        badExit "9" "Telegram bot API check failed";
    else
        telegramOutput="$(curl -skL "https://api.telegram.org/bot${telegramBotId}/getChat?chat_id=${telegramChannelId}")"
        curlExitCode="${?}"
        if [[ "${curlExitCode}" -ne "0" ]]; then
            badExit "10" "Curl to Telegram to check channel returned a non-zero exit code";
        elif [[ -z "${telegramOutput}" ]]; then
            badExit "11" "Curl to Telegram to check channel returned an empty string";
        fi
        if ! [[ "$(jq ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
            badExit "12" "Telegram channel API check failed";
        fi
    fi
    eventText="$(printf "<b>Plex Update for ${dockerHost%%.*}</b>\r\n\r\nPlex Media Server restarted for update from version <i>${myVer}</i> to version <i>${currVer}</i>")"
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
fi

cleanExit;
