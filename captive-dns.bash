#!/usr/bin/env bash

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

# Of note, I tried to build some "debug" functionality into it. If anything fails, it should
# leave the lock file in place with some debug information, as well as the stderr/stdout.
# Assuming you follow the installation instructions, you can find these at:
# - /data/scripts/.captive-dns.sh.lock.${PID}
# - /data/scripts/.captive-dns.sh.stderr.${PID}
# - /data/scripts/.captive-dns.sh.stdout.${PID}
# If you run into any problems with me, create an issue on GitHub, or reach out via IRC in #goose
# on Libera -- My response time should be less than 24 hours, and I'll help as best I can.

#############################
##        Changelog        ##
#############################
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

###################################################
### Begin source, please don't edit below here. ###
###################################################

# Sanity and dependency check
if [[ -z "${BASH_VERSINFO}" || -z "${BASH_VERSINFO[0]}" || "${BASH_VERSINFO[0]}" -lt "4" ]]; then
    /bin/echo "This script requires Bash version 4 or greater"
    exit 255
fi
depArr=("/usr/bin/awk" "/bin/cp" "/usr/bin/curl" "/bin/date" "/bin/echo" "/bin/grep" "/usr/bin/host" "/usr/bin/md5sum" "/bin/mv" "/bin/pwd" "/bin/rm" "/sbin/iptables" "/usr/bin/sort")
depFail="0"
for i in "${depArr[@]}"; do
    if [[ "${i:0:1}" == "/" ]]; then
        if ! [[ -e "${i}" ]]; then
            /bin/echo "${i}\\tnot found"
            depFail="1"
        fi
    else
        if ! command -v ${i} > /dev/null 2>&1; then
            /bin/echo "${i}\\tnot found"
            depFail="1"
        fi
    fi
done
if [[ "${depFail}" -eq "1" ]]; then
    /bin/echo "Dependency check failed"
    exit 255
fi

# Included for debug purposes
PS4='Line ${LINENO}: '
realPath="$(realpath "${0}")"
scriptName="$(basename "${0}")"
lockFile="${realPath%/*}/.${scriptName}.lock"
exec 2>"${realPath%/*}/.${scriptName}.stderr"
set -x

if [[ -e "${lockFile}" ]]; then
    exit 0
else
    /bin/echo "PID: ${$}
PWD: $(/bin/pwd)
Date: $(/bin/date)
RealPath: ${realPath}
\${@}: ${@}
\${#@}: ${#@}" > "${lockFile}"
fi

# Define functions
removeRules () {
while read -r i; do
    /bin/echo "Removing iptables NAT rule ${i}"
    /sbin/iptables -t nat -D PREROUTING "${i}"
done < <(/sbin/iptables -t nat -L PREROUTING --line-numbers | /bin/grep -E "to:([0-9]{1,3}[\.]){3}[0-9]{1,3}:53" | /usr/bin/awk '{print $1}' | /usr/bin/sort -nr)
}

addRules () {
if ! [[ "${1}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    /bin/echo "${1} is not a valid IP address"
    /bin/rm -f "${lockFile}"
    exit 1
fi
if ! [[ "${2}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
    /bin/echo "${2} is not a valid IP address or CIDR range"
    /bin/rm -f "${lockFile}"
    exit 1
fi
# Should be passed as: addRules "IP address you want redirected to" "IP address or CIDR range allowed"
for intfc in "${vlanInterfaces[@]}"; do
    /bin/echo "Forcing interface ${intfc} to ${1}:${dnsPort}"
    /sbin/iptables -t nat -A PREROUTING -i "${intfc}" -p udp ! -s "${2}" ! -d "${2}" --dport "${dnsPort}" -j DNAT --to "${1}:${dnsPort}"
done
}

testDNS () {
/bin/echo "Testing DNS via ${1}"
if ! /usr/bin/host -W 5 "${testDomain}" "${1}" > /dev/null 2>&1; then
    # Wait 5 seconds and try again, in case of timeout
    sleep 5
    if ! /usr/bin/host -W 5 "${testDomain}" "${1}" > /dev/null 2>&1; then
        /bin/echo "DNS test via ${1} failed"
        return 1
    else
        /bin/echo "DNS test via ${1} succeded"
        return 0
    fi
else
    /bin/echo "DNS test via ${1} succeded"
    return 0
fi
}

tgMsg () {
# example:
# $1 = Primary [${primaryDNS}]
# $2 = Tertiary/Failover [${tertiaryDNS}]
if [[ -n "${telegramBotId}" && -n "${telegramChannelId}" ]]; then
    eventText="<b>Captive DNS Status Change</b>$(printf "\r\n\r\n\r\n")Captive DNS switched from ${1} to ${2}"
    sendMsg="$(/usr/bin/curl -skL --header "Host: api.telegram.org" --data-urlencode "text=${eventText}" "https://${telegramAddr}/bot${telegramBotId}/sendMessage?chat_id=${telegramChannelId}&parse_mode=html" 2>&1)"
    if [[ "${?}" -ne "0" ]]; then
        /bin/echo "API call to Telegram failed"
    else
        # Check to make sure Telegram returned a true value for ok
        msgStatus="$(/bin/echo "${sendMsg}" | /usr/bin/jq ".ok")"
        if ! [[ "${msgStatus}" == "true" ]]; then
            /bin/echo "Failed to send Telegram message:"
            /bin/echo ""
            /bin/echo "${sendMsg}" | /usr/bin/jq
            /bin/echo ""
        fi
    fi
fi
}

panicExit () {
/bin/echo "Panic code: ${1}" >> "${lockFile}"
/bin/echo "Captive DNS is: ${captiveDNS}" >> "${lockFile}"
set >> "${lockFile}"
eventText="<b>$(</etc/hostname) Captive DNS Script</b>$(printf "\r\n\r\n\r\n")Unexpected output from ${0}$(printf "\r\n\r\n\r\n")Reference ${lockFile}$(printf "\r\n\r\n")Debug code: ${1}"
if [[ -n "${telegramBotId}" && -n "${telegramChannelId}" ]]; then
    sendMsg="$(/usr/bin/curl -skL --header "Host: api.telegram.org" --data-urlencode "text=${eventText}" "https://${telegramAddr}/bot${telegramBotId}/sendMessage?chat_id=${telegramChannelId}&parse_mode=html" 2>&1)"
    if [[ "${?}" -ne "0" ]]; then
        /bin/echo "API call to Telegram failed"
    else
        # Check to make sure Telegram returned a true value for ok
        msgStatus="$(/bin/echo "${sendMsg}" | /usr/bin/jq ".ok")"
        if ! [[ "${msgStatus}" == "true" ]]; then
            /bin/echo "Failed to send Telegram message:"
            /bin/echo ""
            /bin/echo "${sendMsg}" | /usr/bin/jq
            /bin/echo ""
        fi
    fi
fi
# Panic set DNS to Tertiary so internet can still work if DNS is down
removeRules;
addRules "${tertiaryDNS}" "${tertiaryDNS}";
/bin/cp "${lockFile}" "${lockFile}.${$}"
/bin/mv "${realPath%/*}/.${scriptName}.stdout" "${realPath%/*}/.${scriptName}.stdout.${$}"
/bin/mv "${realPath%/*}/.${scriptName}.stderr" "${realPath%/*}/.${scriptName}.stderr.${$}"
exit "${1}"
}

case "${1,,}" in
    "-h"|"--help")
        /bin/echo "-h  --help      Displays this help message"
        /bin/echo ""
        /bin/echo "-u  --update    Self update to the most recent version"
        /bin/echo ""
        /bin/echo "-r  --rules     Displays current captive DNS rules"
        /bin/echo ""
        /bin/echo "-d  --delete    Deletes current captive DNS rules,"
        /bin/echo "                and does not replace them with anything"
        /bin/echo ""
        /bin/echo "-s  --set       Removes any rules which may exist, and"
        /bin/echo "                then sets new rules for captive DNS"
        /bin/echo "                Usage: -s <1> <2>"
        /bin/echo "                Where <1> is the captive DNS IP address"
        /bin/echo "                and <2> is the allowed DNS CIDR/IP"
        /bin/echo ""
        /bin/echo "--install       Installs script to cron, executing it"
        /bin/echo "                once every minute. Also installs it to"
        /bin/echo "                the on_boot.d/ directory, to persist"
        /bin/echo "                across reboots"
        /bin/echo ""
        /bin/echo "--uninstall     Removes the script from cron"
        /bin/rm -f "${lockFile}"
        exit 0
    ;;
    "-u"|"--update")
        /usr/bin/curl -skL "https://raw.githubusercontent.com/goose-ws/bash-scripts/main/captive-dns.bash" -o "${0}"
        chmod +x "${0}"
        /bin/rm -f "${lockFile}"
        exit 0
    ;;
    "-r"|"--rules")
        /sbin/iptables -t nat -L PREROUTING --line-numbers | /bin/grep -E "to:([0-9]{1,3}[\.]){3}[0-9]{1,3}:53"
        /bin/rm -f "${lockFile}"
        exit 0
    ;;
    "-d"|"--delete")
        removeRules;
        /bin/rm -f "${lockFile}"
        exit 0
    ;;
    "-s"|"--set")
        shift
        removeRules;
        addRules "${1}" "${2}";
        /bin/rm -f "${lockFile}"
        exit 0
    ;;
    "--install")
        /bin/echo "* * * * * root ${realPath%/*}/${scriptName} > ${realPath%/*}/.${scriptName}.stdout" > "/etc/cron.d/${scriptName%.bash}"
        /etc/init.d/cron restart
        /bin/echo "#!/bin/sh" > "/data/on_boot.d/10-captive-dns.sh"
        /bin/echo "/bin/echo \"* * * * * root ${realPath%/*}/${scriptName} > ${realPath%/*}/.${scriptName}.stdout\" > \"/etc/cron.d/${scriptName%.bash}\"" >> "/data/on_boot.d/10-captive-dns.sh"
        chmod +x "/data/on_boot.d/10-captive-dns.sh"
        /bin/rm -f "${lockFile}"
        exit 0
    ;;
    "--uninstall")
        /bin/rm -f "/etc/cron.d/${scriptName%.bash}" "/data/on_boot.d/10-captive-dns.sh"
        /etc/init.d/cron restart
        /bin/rm -f "${lockFile}"
        exit 0
    ;;
esac

## General source begins here

# Get config options
source "${realPath%/*}/${scriptName%.bash}.env"

configFail="0"
# Are our config options valid?
if ! [[ "${allowedDNS}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
    /bin/echo "Allowed DNS (${allowedDNS}) is not a valid IP address or CIDR range"
    configFail="1"
fi
if ! [[ "${primaryDNS}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    /bin/echo "Primary DNS (${primaryDNS}) is not a valid IP address"
    configFail="1"
fi
if ! [[ "${secondaryDNS}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    /bin/echo "Secondary DNS (${secondaryDNS}) is not a valid IP address"
    configFail="1"
fi
if ! [[ "${tertiaryDNS}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    /bin/echo "Tertiary DNS (${tertiaryDNS}) is not a valid IP address"
    configFail="1"
fi
if ! [[ "${dnsPort}" =~ ^[0-9]{1,5}$ ]]; then
    /bin/echo "DNS Port (${dnsPort}) is not a valid port number"
    configFail="1"
fi
if ! [[ "${testDNS}" =~ ^([a-z0-9]{1,60}\.)+[a-z]{2,3}$ ]]; then
    /bin/echo "Address to test DNS (${testDNS}) is not a valid top level domain"
    configFail="1"
fi
if [[ "${#vlanInterfaces[@]}" -eq "0" ]]; then
    /bin/echo "No VLAN interfaces defined"
    configFail="1"
else
    for i in "${vlanInterfaces[@]}"; do
        if ! [[ "${i}" =~ ^br[0-9]+$ ]]; then
            /bin/echo "${i} does not appear to be a valid VLAN interface"
            configFail="1"
        fi
    done
fi
if ! [[ "${updateCheck,,}" =~ ^(yes|no|true|false)$ ]]; then
    /bin/echo "Option to check for updates not valid. Assuming no."
    updateCheck="No"
fi
if [[ -n "${telegramBotId}" && -n "${telegramChannelId}" ]]; then
    telegramOutput="$(/usr/bin/curl -skL "https://api.telegram.org/bot${telegramBotId}/getMe" 2>&1)"
    curlExitCode="${?}"
    if [[ "${curlExitCode}" -ne "0" ]]; then
        /bin/echo "Curl to Telegram to check Bot ID returned a non-zero exit code"
        configFail="1"
    elif [[ -z "${telegramOutput}" ]]; then
        /bin/echo "Curl to Telegram to check Bot ID returned an empty string"
        configFail="1"
    fi
    if ! [[ "$(jq ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
        /bin/echo "Telegram API check for bot failed"
        configFail="1"
    else
        telegramOutput="$(/usr/bin/curl -skL "https://api.telegram.org/bot${telegramBotId}/getChat?chat_id=${telegramChannelId}")"
        curlExitCode="${?}"
        if [[ "${curlExitCode}" -ne "0" ]]; then
            /bin/echo "Curl to Telegram to check channel returned a non-zero exit code"
            configFail="1"
        elif [[ -z "${telegramOutput}" ]]; then
            /bin/echo "Curl to Telegram to check channel returned an empty string"
            configFail="1"
        fi
        if ! [[ "$(jq ".ok" <<<"${telegramOutput,,}")" == "true" ]]; then
            /bin/echo "Telegram API check for channel failed"
            configFail="1"
        fi
    fi
fi
if [[ "${configFail}" -eq "1" ]]; then
    /bin/echo "Please fix config file: ${realPath%/*}/${scriptName%.bash}.env"
    /bin/rm -f "${lockFile}"
    exit 1
fi

# Is the internet reachable?
/bin/echo "Verifying internet connectivity"
if ! /bin/ping -w 5 -c 1 ${tertiaryDNS} > /dev/null 2>&1; then
    /bin/echo "Internet appears to be offline"
    # It appears that it is not
    /bin/rm -f "${lockFile}"
    exit 0
fi

# Are we allowed to check for updates?
if [[ "${updateCheck,,}" =~ ^(yes|true)$ ]]; then
    newest="$(/usr/bin/curl -skL "https://raw.githubusercontent.com/goose-ws/bash-scripts/main/captive-dns.bash" | /usr/bin/md5sum | /usr/bin/awk '{print $1}')"
    current="$(/usr/bin/md5sum "${0}" | /usr/bin/awk '{print $1}')"
    if ! [[ "${newest}" == "${current}" ]]; then
        /bin/echo "A newer version is available"
    fi
fi

# We read this into an array as a cheap way of counting the number of results. It should only be zero or one.
readarray -t captiveDNS < <(/sbin/iptables -n -t nat --list PREROUTING | /bin/grep -Eo "to:([0-9]{1,3}[\.]){3}[0-9]{1,3}:53" | /bin/grep -Eo "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | /usr/bin/sort -u)
if [[ "${#captiveDNS[@]}" -eq "0" ]]; then
    # No rules are set
    if testDNS "${primaryDNS}"; then
        # Primary test succeded
        addRules "${primaryDNS}" "${allowedDNS}";
        tgMsg "null [None set]" "primary [${primaryDNS}]";
    else
        # Primary test failed. Test secondary.
        if testDNS "${secondaryDNS}"; then
            # Secondary test succeded
            addRules "${secondaryDNS}" "${secondaryDNS}";
            tgMsg "null [None set]" "secondary [${secondaryDNS}]";
        else
            # Secondary test failed
            addRules "${tertiaryDNS}" "${tertiaryDNS}";
            tgMsg "null [None set]" "tertiary [${tertiaryDNS}]";
        fi
    fi
elif [[ "${#captiveDNS[@]}" -ge "2" ]]; then
    # There is more than one result. This should not happen.
    panicExit 1;
elif [[ "${captiveDNS[0]}" == "${primaryDNS}" ]]; then
    # Captive DNS is Primary
    if testDNS "${primaryDNS}"; then
        # Primary test succeded
        /bin/rm -f "${lockFile}"
        exit 0
    else
        # Primary test failed. Test secondary.
        if testDNS "${secondaryDNS}"; then
            # Secondary test succeded
            removeRules;
            addRules "${secondaryDNS}" "${secondaryDNS}";
            tgMsg "primary [${primaryDNS}]" "secondary [${secondaryDNS}]";
        else
            # Secondary test failed
            removeRules;
            addRules "${tertiaryDNS}" "${tertiaryDNS}";
            tgMsg "primary [${primaryDNS}]" "tertiary [${tertiaryDNS}]";
        fi
    fi
elif [[ "${captiveDNS[0]}" == "${secondaryDNS}" ]]; then
    # Captive DNS is Secondary
    if testDNS "${primaryDNS}"; then
        # Primary test succeded
        removeRules;
        addRules "${primaryDNS}" "${allowedDNS}";
        tgMsg "secondary [${secondaryDNS}]" "primary [${primaryDNS}]";
    else
        # Primary test failed. Test secondary.
        if testDNS "${secondaryDNS}"; then
            # Secondary test succeded
            /bin/rm -f "${lockFile}"
            exit 0
        else
            # Secondary test failed
            removeRules;
            addRules "${tertiaryDNS}" "${tertiaryDNS}";
            tgMsg "secondary [${secondaryDNS}]" "tertiary [${tertiaryDNS}]";
        fi
    fi
elif [[ "${captiveDNS[0]}" == "${tertiaryDNS}" ]]; then
    # Captive DNS is Tertiary
    if testDNS "${primaryDNS}"; then
        # Primary test succeded
        removeRules;
        addRules "${primaryDNS}" "${allowedDNS}";
        tgMsg "tertiary [${tertiaryDNS}]" "primary [${primaryDNS}]";
    else
        # Primary test failed. Test secondary.
        if testDNS "${secondaryDNS}"; then
            # Secondary test succeded
            removeRules;
            addRules "${secondaryDNS}" "${secondaryDNS}";
            tgMsg "tertiary [${tertiaryDNS}]" "secondary [${secondaryDNS}]";
        else
            # Secondary test failed
            /bin/rm -f "${lockFile}"
            exit 0
        fi
    fi
else
    # One set of rules exist, but it's not Primary, Secondary, or Tertiary - We should never reach this
    panicExit 2;
fi

/bin/rm -f "${lockFile}"
exit 0
