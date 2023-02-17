#!/usr/bin/env bash

## About
# This script serves to manage captive DNS on a UDM Pro. Captive DNS meaning it will *force*
# all clients to use a specific DNS server via iptables if they are not querying the DNS servers
# set by the ${piHoleCIDR} range. Useful for forcing devices with hard coded DNS to use your PiHole
# (For example, a Google Home) while being flexible enough to change that captive DNS destination
# if the host that *should* be serving it is not, for some reason.

# For reference, in my setup, my PiHole IP addresses are:
# - 10.10.10.10
# - 10.10.10.11
# They are the only two devices in that 10.10.10.0/24 CIDR range (other than the gateway, of course).

# While I suppose it is possible to use this script for a single PiHole, rather than dual, I
# can't reasonably recommend it, as I have not optimized it for that use case. That said, if you
# absolutely wanted to, it will work as long as the ${primaryDNS} is your PiHole IP address,
# the ${piHoleCIDR} ends in x.x.x.0/31, and finally ${secondaryDNS} and ${tertiaryDNS} are valid
# and working DNS resolvers (8.8.8.8 and 8.8.4.4, for example).

# Of note, I tried to build some "debug" functionality into it. If anything fails, it should
# leave the lock file in place with some debug information, as well as the stderr/stdout.
# Assuming you follow the installation instructions, you can find these at:
# - /data/scripts/.captive-dns.sh.lock.${PID}
# - /data/scripts/.captive-dns.sh.stderr.${PID}
# - /data/scripts/.captive-dns.sh.stdout.${PID}
# If you run into any problems with me, try and reach out via IRC in #goose on Libera -- My response
# time should be less than 24 hours,  and I'll help as best I can.

## Changelog
# 2023-02-16
# Updated to work with Unifi 2.4.27, which is now based on Debian
# Greatly improved and simplified the logic of the script, now that we can use proper bash rather than sh

## Installation
# It depends on BoostChicken's Unifi Utilities: https://github.com/unifi-utilities/unifios-utilities
# so that you can run scripts in the '/data/on_boot.d/' directory on each boot.

# 0. Install BoostChicken's on-boot functionality to preserve across reboots.
# 1. Place this script at '/data/scripts/captive-dns.bash'
# 2. Set the script as executable (chmod +x).
# 3. Copy 'captive-dns.env.example' to 'captive-dns.env' and edit it to your liking
# 4. Run the command '/mnt/data/scripts/captive-dns.bash --install' to install it to cron and on_boot.d

###################################################
### Begin source, please don't edit below here. ###
###################################################

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
    echo "PID: ${$}
PWD: $(pwd)
Date: $(date)
RealPath: ${realPath}
\${@}: ${@}
\${#@}: ${#@}" > "${lockFile}"
fi

# Define functions
removeRules () {
while read -r i; do
	echo "Removing iptables NAT rule ${i}"
    /sbin/iptables -t nat -D PREROUTING "${i}"
done < <(/sbin/iptables -t nat -L PREROUTING --line-numbers | grep -E "to:([0-9]{1,3}[\.]){3}[0-9]{1,3}:53" | awk '{print $1}' | sort -nr)
}

addRules () {
if ! [[ "${1}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
	echo "${1} is not a valid IP address"
	rm -f "${lockFile}"
	exit 1
fi
if ! [[ "${2}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
	echo "${2} is not a valid IP address or CIDR range"
	rm -f "${lockFile}"
	exit 1
fi
# Should be passed as: addRules "IP address you want redirected to" "IP address or CIDR range allowed"
for intfc in "${vlanInterfaces[@]}"; do
	echo "Forcing interface ${intfc} to ${1}:${dnsPort}"
	/sbin/iptables -t nat -A PREROUTING -i "${intfc}" -p udp ! -s "${2}" ! -d "${2}" --dport "${dnsPort}" -j DNAT --to "${1}:${dnsPort}"
done
}

testDNS () {
if ! /usr/bin/host -W 5 "${testDomain}" "${1}" > /dev/null 2>&1; then
	# Wait 5 seconds and try again, in case of timeout
	sleep 5
	/usr/bin/host -W 5 "${testDomain}" "${1}" > /dev/null 2>&1
else
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
		echo "API call to Telegram failed"
	else
		# Check to make sure Telegram returned a true value for ok
		msgStatus="$(echo "${sendMsg}" | /usr/bin/jq ".ok")"
		if ! [[ "${msgStatus}" == "true" ]]; then
			echo "Failed to send Telegram message:"
			echo ""
			echo "${sendMsg}" | /usr/bin/jq
			echo ""
		fi
	fi
fi
}

panicExit () {
echo "Panic code: ${1}" >> "${lockFile}"
echo "Captive DNS is: ${captiveDNS}" >> "${lockFile}"
set >> "${lockFile}"
eventText="<b>$(</etc/hostname) Captive DNS Script</b>$(printf "\r\n\r\n\r\n")Unexpected output from ${0}$(printf "\r\n\r\n\r\n")Reference ${lockFile}$(printf "\r\n\r\n")Debug code: ${1}"
if [[ -n "${telegramBotId}" && -n "${telegramChannelId}" ]]; then
    sendMsg="$(/usr/bin/curl -skL --header "Host: api.telegram.org" --data-urlencode "text=${eventText}" "https://${telegramAddr}/bot${telegramBotId}/sendMessage?chat_id=${telegramChannelId}&parse_mode=html" 2>&1)"
    if [[ "${?}" -ne "0" ]]; then
        echo "API call to Telegram failed"
    else
        # Check to make sure Telegram returned a true value for ok
        msgStatus="$(echo "${sendMsg}" | /usr/bin/jq ".ok")"
        if ! [[ "${msgStatus}" == "true" ]]; then
            echo "Failed to send Telegram message:"
            echo ""
            echo "${sendMsg}" | /usr/bin/jq
            echo ""
        fi
    fi
fi
# Panic set DNS to Tertiary so internet can still work if DNS is down
removeRules;
addRules "${tertiaryDNS}" "${tertiaryDNS}";
cp "${lockFile}" "${lockFile}.${$}"
mv "${realPath%/*}/.${scriptName}.stdout" "${realPath%/*}/.${scriptName}.stdout.${$}"
mv "${realPath%/*}/.${scriptName}.stderr" "${realPath%/*}/.${scriptName}.stderr.${$}"
exit "${1}"
}

case "${1,,}" in
	"-h"|"--help")
	echo "-h  --help      Displays this help message"
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
	rm -f "${lockFile}"
	exit 0
	;;
	"-r"|"--rules")
	/sbin/iptables -t nat -L PREROUTING --line-numbers | grep -E "to:([0-9]{1,3}[\.]){3}[0-9]{1,3}:53"
	rm -f "${lockFile}"
	exit 0
	;;
	"-d"|"--delete")
	removeRules;
	rm -f "${lockFile}"
	exit 0
	;;
	"-s"|"--set")
	shift
	removeRules;
	addRules "${1}" "${2}";
	rm -f "${lockFile}"
	exit 0
	;;
	"--install")
	echo "* * * * * root ${realPath%/*}/${scriptName} > ${realPath%/*}/.${scriptName}.stdout" > "/etc/cron.d/${scriptName%.bash}"
    /etc/init.d/cron restart
	echo "#!/bin/sh" > "/data/on_boot.d/10-captive-dns.sh"
	echo "echo \"* * * * * root ${realPath%/*}/${scriptName} > ${realPath%/*}/.${scriptName}.stdout\" > \"/etc/cron.d/${scriptName%.bash}\"" >> "/data/on_boot.d/10-captive-dns.sh"
	chmod +x "/data/on_boot.d/10-captive-dns.sh"
	rm -f "${lockFile}"
	exit 0
	;;
	"--uninstall")
	rm -f "/etc/cron.d/${scriptName%.bash}" "/data/on_boot.d/10-captive-dns.sh"
    /etc/init.d/cron restart
	rm -f "${lockFile}"
	exit 0
	;;
esac

## General source begins here

# Get config options
source "${realPath%/*}/${scriptName%.bash}.env"

# Is the internet reachable?
if ! /bin/ping -w 5 -c 1 ${tertiaryDNS} > /dev/null 2>&1; then
    # It appears that it is not
    rm -f "${lockFile}"
    exit 0
fi

# We read this into an array as a cheap way of counting the number of results. It should only be zero or one.
readarray -t captiveDNS < <(/sbin/iptables -n -t nat --list PREROUTING | grep -Eo "to:([0-9]{1,3}[\.]){3}[0-9]{1,3}:53" | grep -Eo "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | sort -u)
if [[ "${#captiveDNS[@]}" -eq "0" ]]; then
	# No rules are set
    if testDNS "${primaryDNS}"; then
		# Primary test succeded
		addRules "${primaryDNS}" "${piHoleCIDR}";
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
		rm -f "${lockFile}"
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
		addRules "${primaryDNS}" "${piHoleCIDR}";
		tgMsg "secondary [${secondaryDNS}]" "primary [${primaryDNS}]";
	else
		# Primary test failed. Test secondary.
		if testDNS "${secondaryDNS}"; then
			# Secondary test succeded
			rm -f "${lockFile}"
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
		addRules "${primaryDNS}" "${piHoleCIDR}";
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
			rm -f "${lockFile}"
			exit 0
		fi
	fi
else
    # One set of rules exist, but it's not Primary, Secondary, or Tertiary - We should never reach this
    panicExit 2;
fi

rm -f "${lockFile}"
exit 0
