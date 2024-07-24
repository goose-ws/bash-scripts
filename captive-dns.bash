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
# This script serves to manage captive DNS on a UDM Pro. Captive DNS meaning it will *force*
# all clients to use a specific DNS server via iptables if they are not querying the DNS servers
# set by the ${allowedDNS} range. Useful for forcing devices with hard coded DNS to use your PiHole
# (For example, a Google Home) while being flexible enough to change that captive DNS destination
# if the host that *should* be serving it is not, for some reason.

# For reference, in my setup, my PiHole IP addresses are:
# - 10.10.10.10
# - 10.10.10.11
# They are the only two devices in that 10.10.10.0/24 CIDR range (other than the gateway, of course).

#############################
##        Changelog        ##
#############################
# 2024-07-24
# Rolled back the changes from the 2024-07-13 commit, as it appears the version of iptables used by
# the UDM-P does not support multiple comma-separated addresses when using the ! inverter
# Also added the '-w 30' flag to let iptables wait if it needs to
# 2024-07-13
# Added support for multiple allowed lookup ranges (See updated .env)
# 2024-01-27
# Improved some sanity checks and logic for escape scenarioes
# Added support for when a container has multiple networks attached (Multiple IP addresses)
# Updated the logic for sending Telegram messages to make sure the bot can authenticate to each channel
# Added support for super groups, silent messages (See updated .env file)
# Added support for sending error messages via telegram (See updated .env file)
# 2023-12-30
# Defined some paths, as iptables isn't in the default ${PATH} for sh
# Fixed some logic regarding persisting across restarts
# 2023-12-15
# Updated formatting and output to my "new standard"
# 2023-02-16
# Updated to work with Unifi 2.4.27, which is now based on Debian
# Greatly improved and simplified the logic of the script, now that we can use proper bash rather than sh

#############################
##       Installation      ##
#############################
# This script is meant for Unifi v2.4+, which is based on Debian. It will not work on older versions.
# It also depends on BoostChicken's Unifi Utilities: https://github.com/unifi-utilities/unifios-utilities
# This is so that you can run scripts in the '/data/on_boot.d/' directory on each boot.

# 0. Install BoostChicken's on-boot functionality to preserve across reboots.
# 1. Place this script at '/data/scripts/captive-dns.bash'
# 2. Set the script as executable (chmod +x).
# 3. Copy 'captive-dns.env.example' to 'captive-dns.env' and edit it to your liking
# 4. Run the command '/data/scripts/captive-dns.bash --install' to install it to cron and on_boot.d

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
# Define the ${PATH} for cron
PATH="/root/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
depArr=("awk" "cp" "curl" "date" "echo" "grep" "host" "md5sum" "realpath" "basename" "rm" "iptables" "sort")
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
updateURL="https://raw.githubusercontent.com/goose-ws/bash-scripts/main/captive-dns.bash"
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
if [[ "${1}" == "silent" ]]; then
    outputVerbosity="0"
fi
removeLock
exit 0
}

function sendTelegramMessage {
if [[ -n "${telegramBotId}" && -n "${telegramChannelId[0]}" ]]; then
    # Message to send should be passed as function positional parameter #1
    # We can pass an "Admin channel" as positional parameter #2 for the case of sending error messages
    # Let's check to make sure our messaging credentials are valid
    skipTelegram="0"
    telegramOutput="$(curl -skL -H "Host: api.telegram.org" "https://${telegramAddr}/bot${telegramBotId}/getMe" 2>&1)"
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
                telegramOutput="$(curl -skL -H "Host: api.telegram.org" "https://${telegramAddr}/bot${telegramBotId}/getChat?chat_id=${telegramChannelId}")"
                curlExitCode="${?}"
                if [[ "${curlExitCode}" -ne "0" ]]; then
                    printOutput "1" "Curl to Telegram to check channel returned a non-zero exit code: ${curlExitCode}"
                elif [[ -z "${telegramOutput}" ]]; then
                    printOutput "1" "Curl to Telegram to check channel returned an empty string"
                elif [[ "$(jq -M -r ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
                    printOutput "3" "Curl exit code and null output checks passed"
                    printOutput "2" "Telegram channel authenticated: $(jq -M -r ".result.title" <<<"${telegramOutput}")"
                    telegramOutput="$(curl -skL -H "Host: api.telegram.org" --data-urlencode "text=${1}" "https://${telegramAddr}/bot${telegramBotId}/sendMessage?chat_id=${chanId}&parse_mode=html" 2>&1)"
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
fi
}

#############################
##     Unique Functions    ##
#############################
removeRules () {
printOutput "3" "Initiating rule removal"
while read -r i; do
    printOutput "2" "Removing iptables NAT rule ${i}"
    iptables -w 30 -t nat -D PREROUTING "${i}"
done < <(iptables -w 30 -n -t nat -L PREROUTING --line-numbers | grep -E "to:([0-9]{1,3}[\.]){3}[0-9]{1,3}:53" | awk '{print $1}' | sort -nr)
printOutput "3" "Rule removal complete"
}

addRules () {
printOutput "3" "Initiating rule adding"
if ! [[ "${1}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    badExit "1" "${1} is not a valid IP address"
fi
if ! [[ "${2}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
    badExit "2" "${2} is not a valid IP address or CIDR range"
fi
# Should be passed as: addRules "IP address you want redirected to" "IP address or CIDR range allowed"
for intfc in "${vlanInterfaces[@]}"; do
    printOutput "2" "Forcing interface ${intfc} to ${1}:${dnsPort}"
    iptables -t nat -A PREROUTING -i "${intfc}" -p udp ! -s "${2}" ! -d "${2}" --dport "${dnsPort}" -j DNAT --to "${1}:${dnsPort}"
done
printOutput "3" "Rule adding complete"
}

testDNS () {
printOutput "3" "Initiating DNS test"
if ! host -W 5 "${testDomain}" "${1}" > /dev/null 2>&1; then
    # Wait 5 seconds and try again, in case of timeout
    printOutput "1" "DNS test attempt 1 failed: ${1}"
    sleep 5
    if ! host -W 5 "${testDomain}" "${1}" > /dev/null 2>&1; then
        printOutput "1" "DNS test attempt 2 failed: ${1}"
        printOutput "3" "DNS testing complete"
        return 1
    else
        printOutput "2" "DNS test attempt 2 succeded: ${1}"
        printOutput "3" "DNS testing complete"
        return 0
    fi
else
    printOutput "2" "DNS test attempt 1 succeded: ${1}"
    printOutput "3" "DNS testing complete"
    return 0
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
        echo "-u  --Update    Self Update to the most recent version"
        echo ""
        echo "-r  --rules     Displays current captive DNS rules"
        echo ""
        echo "-d  --delete    Deletes current captive DNS rules,"
        echo "                and does not replace them with anything"
        echo ""
        echo "-s  --set       Removes any rules which may exist, and"
        echo "                then sets new rules for captive DNS"
        echo "                Usage: -s <1> <2>"
        echo "                Where <1> is the captive DNS IP address"
        echo "                and <2> is the allowed DNS CIDR/IP"
        echo ""
        echo "--install       Installs script to cron, executing it"
        echo "                once every minute. Also installs it to"
        echo "                the on_boot.d/ directory, to persist"
        echo "                across reboots"
        echo ""
        echo "--uninstall     Removes the script from cron"
        cleanExit "silent"
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
    "-r"|"--rules")
        iptables -w 30 -n -t nat -L PREROUTING --line-numbers | grep -E "to:([0-9]{1,3}[\.]){3}[0-9]{1,3}:53"
        cleanExit "silent"
    ;;
    "-d"|"--delete")
        removeRules;
        cleanExit
    ;;
    "-s"|"--set")
        shift
        removeRules;
        addRules "${1}" "${2}";
        cleanExit
    ;;
    "--install")
        echo "* * * * * root ${realPath%/*}/${scriptName}" > "/etc/cron.d/${scriptName%.bash}"
        /etc/init.d/cron restart
        echo "#!/bin/sh" > "/data/on_boot.d/10-captive-dns.sh"
        echo "echo \"* * * * * root ${realPath%/*}/${scriptName}\" > \"/etc/cron.d/${scriptName%.bash}" >> "/data/on_boot.d/10-captive-dns.sh"
        echo "/etc/init.d/cron restart" >> "/data/on_boot.d/10-captive-dns.sh"
        chmod +x "/data/on_boot.d/10-captive-dns.sh"
        cleanExit "silent"
    ;;
    "--uninstall")
        rm -f "/etc/cron.d/${scriptName%.bash}" "/data/on_boot.d/10-captive-dns.sh"
        /etc/init.d/cron restart
        cleanExit "silent"
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
if ! [[ "${outputVerbosity}" =~ ^[1-3]$ ]]; then
    echo "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   [1] Invalid output verbosity defined. Assuming level 1 (Errors only)"
    outputVerbosity="1"
fi

# Config specific checks
if ! [[ "${allowedDNS}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
    printOutput "1" "Allowed DNS (${allowedDNS}) is not a valid IP address or CIDR range"
    varFail="1"
fi
if ! [[ "${primaryDNS}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    printOutput "1" "Primary DNS (${primaryDNS}) is not a valid IP address"
    varFail="1"
fi
if [[ -z "${secondaryDNS}" ]]; then
    printOutput "1" "No Secondary DNS defined, falling back to Tertiary DNS"
    secondaryDNS="${tertiaryDNS}"
elif ! [[ "${secondaryDNS}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    printOutput "1" "Secondary DNS (${secondaryDNS}) is not a valid IP address"
    varFail="1"
fi
if ! [[ "${tertiaryDNS}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    printOutput "1" "Tertiary DNS (${tertiaryDNS}) is not a valid IP address"
    varFail="1"
fi
if ! [[ "${dnsPort}" =~ ^[0-9]{1,5}$ ]]; then
    printOutput "1" "DNS Port (${dnsPort}) is not a valid port number"
    varFail="1"
fi
if ! [[ "${testDomain}" =~ ^([a-z0-9]{1,60}\.)+[a-z]{2,3}$ ]]; then
    printOutput "1" "Address to test DNS (${testDomain}) is not a valid domain"
    varFail="1"
fi
if [[ "${#vlanInterfaces[@]}" -eq "0" ]]; then
    printOutput "1" "No VLAN interfaces defined"
    varFail="1"
else
    for i in "${vlanInterfaces[@]}"; do
        if ! [[ "${i}" =~ ^br[0-9]+$ ]]; then
            printOutput "1" "${i} does not appear to be a valid VLAN interface"
            varFail="1"
        fi
    done
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
printOutput "2" "Verifying internet connectivity"
if ! ping -w 5 -c 1 "${tertiaryDNS}" > /dev/null 2>&1; then
    # It appears that it is not
    badExit "7" "Internet appears to be offline"
else
    printOutput "3" "Internet connectivity verified"
fi

# We read this into an array as a cheap way of counting the number of results. It should only be zero or one.
readarray -t captiveDNS < <(iptables -w 30 -n -t nat --list PREROUTING | grep -Eo "to:([0-9]{1,3}[\.]){3}[0-9]{1,3}:53" | grep -Eo "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | sort -u)
if [[ "${#captiveDNS[@]}" -eq "0" ]]; then
    # No rules are set
    printOutput "3" "No DNS rules detected"
    if testDNS "${primaryDNS}"; then
        # Primary test succeded
        addRules "${primaryDNS}" "${allowedDNS}";
        eventText="<b>Captive DNS Status Change</b>${lineBreak}Captive DNS switched from null [None set] to primary [${primaryDNS}]"
        sendTelegramMessage "${eventText}"
    else
        # Primary test failed. Test secondary.
        if testDNS "${secondaryDNS}"; then
            # Secondary test succeded
            addRules "${secondaryDNS}" "${secondaryDNS}";
            eventText="<b>Captive DNS Status Change</b>${lineBreak}Captive DNS switched from null [None set] to secondary [${secondaryDNS}]"
            sendTelegramMessage "${eventText}"
        else
            # Secondary test failed
            addRules "${tertiaryDNS}" "${tertiaryDNS}";
            eventText="<b>Captive DNS Status Change</b>${lineBreak}Captive DNS switched from null [None set] to tertiary [${tertiaryDNS}]"
            sendTelegramMessage "${eventText}"
        fi
    fi
elif [[ "${#captiveDNS[@]}" -ge "2" ]]; then
    # There is more than one result. This should not happen.
    badExit "0" "More than one captive DNS entry found";
elif [[ "${captiveDNS[0]}" == "${primaryDNS}" ]]; then
    # Captive DNS is Primary
    printOutput "3" "Captive DNS is Primary DNS: ${primaryDNS}"
    printOutput "2" "Testing Primary DNS server: ${primaryDNS}"
    if testDNS "${primaryDNS}"; then
        # Primary test succeded
        printOutput "2" "Primary DNS check succeeded"
        cleanExit
    else
        # Primary test failed. Test secondary.
        printOutput "1" "Primary DNS check failed"
        printOutput "2" "Testing Secondary DNS server: ${secondaryDNS}"
        if testDNS "${secondaryDNS}"; then
            # Secondary test succeded
            printOutput "2" "Secondary DNS check succeeded"
            removeRules;
            addRules "${secondaryDNS}" "${secondaryDNS}";
            eventText="<b>Captive DNS Status Change</b>${lineBreak}Captive DNS switched from primary [${primaryDNS}] to secondary [${secondaryDNS}]"
            sendTelegramMessage "${eventText}"
        else
            # Secondary test failed
            printOutput "1" "Secondary DNS check failed"
            removeRules;
            addRules "${tertiaryDNS}" "${tertiaryDNS}";
            eventText="<b>Captive DNS Status Change</b>${lineBreak}Captive DNS switched from primary [${primaryDNS}] to tertiary [${tertiaryDNS}]"
            sendTelegramMessage "${eventText}"
        fi
    fi
elif [[ "${captiveDNS[0]}" == "${secondaryDNS}" ]]; then
    # Captive DNS is Secondary
    printOutput "3" "Captive DNS is Secondary DNS: ${secondaryDNS}"
    printOutput "2" "Testing Primary DNS server: ${primaryDNS}"
    if testDNS "${primaryDNS}"; then
        # Primary test succeded
        printOutput "2" "Primary DNS check succeeded"
        removeRules;
        addRules "${primaryDNS}" "${allowedDNS}";
        eventText="<b>Captive DNS Status Change</b>${lineBreak}Captive DNS switched from secondary [${secondaryDNS}] to primary [${primaryDNS}]"
        sendTelegramMessage "${eventText}"
    else
        # Primary test failed. Test secondary.
        printOutput "1" "Primary DNS check failed"
        printOutput "2" "Testing Secondary DNS server: ${secondaryDNS}"
        if testDNS "${secondaryDNS}"; then
            # Secondary test succeded
            printOutput "2" "Secondary DNS check succeeded"
            cleanExit
        else
            # Secondary test failed
            printOutput "1" "Secondary DNS check failed"
            removeRules;
            addRules "${tertiaryDNS}" "${tertiaryDNS}";
            eventText="<b>Captive DNS Status Change</b>${lineBreak}Captive DNS switched from secondary [${secondaryDNS}] to tertiary [${tertiaryDNS}]"
            sendTelegramMessage "${eventText}"
        fi
    fi
elif [[ "${captiveDNS[0]}" == "${tertiaryDNS}" ]]; then
    # Captive DNS is Tertiary
    printOutput "3" "Captive DNS is Tertiary DNS: ${tertiaryDNS}"
    printOutput "2" "Testing Primary DNS server: ${primaryDNS}"
    if testDNS "${primaryDNS}"; then
        # Primary test succeded
        printOutput "2" "Primary DNS check succeeded"
        removeRules;
        addRules "${primaryDNS}" "${allowedDNS}";
        eventText="<b>Captive DNS Status Change</b>${lineBreak}Captive DNS switched from tertiary [${tertiaryDNS}] to primary [${primaryDNS}]"
        sendTelegramMessage "${eventText}"
    else
        # Primary test failed. Test secondary.
        printOutput "1" "Primary DNS check failed"
        printOutput "2" "Testing Secondary DNS server: ${secondaryDNS}"
        if testDNS "${secondaryDNS}"; then
            # Secondary test succeded
            printOutput "2" "Secondary DNS check succeeded"
            removeRules;
            addRules "${secondaryDNS}" "${secondaryDNS}";
            eventText="<b>Captive DNS Status Change</b>${lineBreak}Captive DNS switched from tertiary [${tertiaryDNS}] to secondary [${secondaryDNS}]"
            sendTelegramMessage "${eventText}"
        else
            # Secondary test failed
            printOutput "1" "Secondary DNS check failed"
            cleanExit
        fi
    fi
else
    # One set of rules exist, but it's not Primary, Secondary, or Tertiary - We should never reach this
    badExit "0" "Rules do not match any known DNS server: ${captiveDNS[0]}";
fi

#############################
##       End of file       ##
#############################
cleanExit
