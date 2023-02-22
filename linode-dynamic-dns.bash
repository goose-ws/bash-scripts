#!/usr/bin/env bash

if ! [ -e "/bin/bash" ]; then
    echo "This script requires Bash"
    exit 1
fi
if [[ -z "${BASH_VERSINFO}" || -z "${BASH_VERSINFO[0]}" || "${BASH_VERSINFO[0]}" -lt "4" ]]; then
    echo "This script requires Bash version 4 or greater"
    rm -f "${lockFile}"
    exit 2
fi
depArr=("awk" "curl" "date" "dig" "do" "done" "echo" "elif" "exit" "for" "if" "jq" "printf" "pwd" "realpath" "rm" "source" "then" "while")
depFail="0"
for i in "${depArr[@]}"; do
    if [[ "${i:0:1}" == "/" ]]; then
        if ! [[ -e "${i}" ]]; then
            echo -e "${i}\tnot found"
            depFail="1"
        fi
    else
        if ! command -v ${i} > /dev/null 2>&1; then
            echo -e "${i}\tnot found"
            depFail="1"
        fi
    fi
done
if [[ "${depFail}" -eq "1" ]]; then
    echo "Dependency check failed"
    rm -f "${lockFile}"
    exit 3
fi
myRealPath="$(realpath "${0}")"
fName="${myRealPath##*/}"
lockFile="${myRealPath%/*}/.${fName%.*}.lock"
envFile="${myRealPath%/*}/${fName%.*}.env"
if [[ -e "${lockFile}" ]]; then
    echo "Script already running (PID $(head "${lockFile}" -n 1 | awk '{print $2}'))"
    exit 0
else
    echo "PID: ${$}" > "${lockFile}"
    echo "PWD: $(pwd)" >> "${lockFile}"
    echo "Date: $(date)" >> "${lockFile}"
    echo "\${#@}: ${#@}" >> "${lockFile}"
    if [[ "${#@}" -gt "1" ]]; then
        n=0
        for i in "${@}"; do
            echo "${n}: ${i}" >> "${lockFile}"
            (( n++ ))
        done
    fi
fi
showHelp="0"
makeConf="0"
cleanDbg="0"
runQuiet="0"
updatev4="1"
updatev6="1"
while [[ "${#@}" -ne "0" ]]; do
    if [[ "${1}" == "--clean-debug" ]]; then
        if ! [[ -e "${envFile}" ]]; then
            echo "Unable to clean debug file, as no env file present"
            panicExit 4;
        fi
        debugFile="${myRealPath%/*}/.${fName%.*}.debug"
        if ! [[ -e "${debugFile}" ]]; then
            echo "Unable to clean debug file, as no debug file present"
            panicExit 5;
        fi
        source "${envFile}"
        echo -n "Removing API key from debug file..."
        sed -i "s/${apiKey}/API_KEY/g" "${debugFile}"
        if ! grep -Fq "${apiKey}" "${debugFile}"; then
            echo "Done"
        else
            echo "Failed to remove API key from debug file"
        fi
        if [[ -n "${telegramBotID}" ]]; then
            echo -n "Removing Telegram Bot API key from debug file..."
            sed -i "s/${telegramBotID}/BOT_KEY/g" "${debugFile}"
            if ! grep -Fq "${telegramBotID}" "${debugFile}"; then
                echo "Done"
            else
                echo "Failed to remove Bot API key from debug file"
            fi
        fi
        if [[ -n "${telegramChannelID}" ]]; then
            echo -n "Removing Telegram Channel ID from debug file..."
            sed -i "s/${telegramChannelID}/CHAN_ID/g" "${debugFile}"
            if ! grep -Fq -- "${telegramChannelID}" "${debugFile}"; then
                echo "Done"
            else
                echo "Failed to remove Channel ID from debug file"
            fi
        fi
        mv "${debugFile}" "${myRealPath%/*}/${fName%.*}.debug"
        rm -f "${lockFile}"
        exit 0
    fi
    if [[ "${1}" == "-d" || "${1}" == "--debug" ]]; then
        debugFile="${myRealPath%/*}/${fName%.*}.debug"
        if [[ -e "${debugFile}" ]]; then
            mv "${debugFile}" "${debugFile}.old"
        fi
        PS4='Line ${LINENO}: '
        exec 2>"${debugFile}"
        set -x
    fi
    if [[ "${1}" == "-h" || "${1}" == "--help" ]]; then
        showHelp="1"
    fi
    if [[ "${1}" == "-c" || "${1}" == "--config" ]]; then
        makeConf="1"
    fi
    if [[ "${1}" == "-q" || "${1}" == "--quiet" ]]; then
        runQuiet="1"
    fi
    shift
done

if [[ "${showHelp}" -eq "1" ]]; then
    echo "Script which can be used to update A and AAAA records in the Linode DNS Manager via API"
    echo "By default, it will attempt to update both IPv4 (A) and IPv6 (AAAA) records."
    echo ""
    echo "Usage:"
    echo " -h, --help       Displays this help message"
    echo " -d, --debug      Runs script in debug mode"
    echo " -c, --config     Generates a new config file"
    echo " -q, --quiet      Runs script silently (Without any output)"
    echo " --clean-debug    Sanitizes an existing debug output file of API keys and sensitive information"
    echo "                  (Only cleans the debug output, then exits)"
    rm -f "${lockFile}"
    exit 0
fi

panicExit () {
    echo "Discarding changes, exit code ${1}"
    rm -f "${lockFile}"
    exit ${1}
}
mkApi () {
echo "Please create a Personal Access Token at: https://cloud.linode.com/profile/tokens"
echo ""
echo "It only needs Read/Write permission for Domains. Set the expiry to whatever you are comfortable with."
echo ""
read -p "Please enter new API key: " userInput
if [[ "${userInput}" =~ ^[[:alnum:]]+$ ]]; then
    echo "New API key accepted"
    apiKey="${userInput}"
elif [[ -z "${userInput}" ]]; then
    echo "No input provided"
    panicExit 6;
else
    echo "API key appears to be invalid (Characters other than letters/numbers)"
    panicExit 7;
fi
}
getDomains () {
testData="$(curl -s \
           -L \
           -H "Authorization: Bearer ${apiKey}" \
           "https://api.linode.com/v4/domains/")"
if jq -e . >/dev/null 2>&1 <<<"${testData}"; then
    if [[ "$(jq " .errors[].reason" <<<"${testData}" > /dev/null 2>&1)" == "\"Invalid Token\"" ]]; then
        echo "Access denied using API key"
        panicExit 8;
    fi
    itemCount="$(jq ".results" <<<"${testData}")"
    if [[ "${itemCount}" -eq "0" ]]; then
        echo "Failed to retrieve any domains (Have you added any?)"
        panicExit 9;
    fi
fi
}
mkDns () {
(( itemCount-- ))
echo ""
if [[ "${itemCount}" -eq "0" ]]; then
    # We only have one choice
    domain="$(jq ".data[0].domain" <<<"${testData}")"
    domain="${domain#\"}"
    domain="${domain%\"}"
    domainID="$(jq ".data[0].id" <<< "${testData}")"
    echo "Only one domain choice available, choosing ${domain}"
else
    echo "Multiple domains available, please choose:"
    echo ""
    for i in $(seq 0 ${itemCount}); do
        domain="$(jq ".data[${i}].domain")"
        domain="${domain#\"}"
        domain="${domain%\"}"
        echo "[${i}] ${domain}"
    done
    echo ""
    read -p "> " userInput
    if ((number >= 0 && number <= ${itemCount})); then
        domain="$(jq ".data[${userInput}].domain" <<<"${testData}")"
        domainID="$(jq ".data[${userInput}].id" <<<"${testData}")"
        echo ""
        echo "Using ${domain}"
    else
        echo "Invalid choice"
        panicExit 10;
    fi
fi
echo ""
# Get the list of A/AAAA records for the domain
echo -n "Retrieving list of available A/AAAA records..."
testData="$(curl -s \
                 -L \
                 -H "Authorization: Bearer ${apiKey}" \
                 "https://api.linode.com/v4/domains/${domainID}/records/")"
# Make sure we actually received some results
if jq -e . >/dev/null 2>&1 <<<"${testData}"; then
    if [[ "$(jq " .errors[].reason" <<<"${testData}" > /dev/null 2>&1)" == "\"Invalid Token\"" ]]; then
        echo "Access denied using API key"
        panicExit 11;
    fi
    itemCount="$(jq ".results" <<<"${testData}")"
    if [[ "${itemCount}" -eq "0" ]]; then
        echo "Failed to retrieve any records (Have you added any?)"
        panicExit 12;
    fi
fi
echo "Success"
(( itemCount-- ))
echo ""
if [[ "${itemCount}" -eq "0" ]]; then
    # We only have one choice
    recordName="$(jq ".data[0].target" <<<"${testData}")"
    recordName="${recordName#\"}"
    recordName="${recordName%\"}"
    if [[ -z "${recordName}" ]]; then
        # It's the first level domain
        recordName="${domain}"
    else
        recordName="${recordName}.${domain}"
    fi
    recordNameID="$(jq ".data[0].id" <<<"${testData}")"
    echo "Only one record choice available, choosing ${recordName}"
else
    # Add each unique item to an array
    while read i; do
        i="${i#\"}"
        i="${i%\"}"
        inArray="0"
        for ii in "${recordNamesUnique[@]}"; do
            if [[ "${i}" == "${ii}" ]]; then
                inArray="1"
            fi
        done
        if [[ "${inArray}" -eq "0" ]]; then
            recordNamesUnique+=("${i}")
        fi
    done < <(jq ".data[] | select(.type == \"A\") | .name" <<<"${testData}"; jq ".data[] | select(.type == \"AAAA\") | .name" <<<"${testData}")
    echo "Multiple records available, please choose:"
    echo ""
    for i in $(seq 0 $(( ${#recordNamesUnique[@]} - 1 ))); do
        if [[ -z "${recordNamesUnique[${i}]}" ]]; then
            recordNamesUnique[${i}]="${domain}"
        else
            recordNamesUnique[${i}]="${recordNamesUnique[${i}]}.${domain}"
        fi
        echo "[${i}] ${recordNamesUnique[${i}]}"
    done
    echo ""
    read -p "> " userInput
    if ((userInput >= 0 && userInput <= $(( ${#recordNamesUnique[@]} - 1 )))); then
        recordName=${recordNamesUnique[${userInput}]}
        echo ""
        echo "Using ${recordName}"
    else
        echo "Invalid choice"
        panicExit 13;
    fi
fi
}
mkBotApi () {
echo "Please enter the Bot API token (Obtained from @BotFather)"
read -p "> " userInput
if [[ -z "${userInput}" ]]; then
    echo "No input provided"
    panicExit 14;
else
    telegramBotID="${userInput}"
fi
}
mkChanID () {
echo "Please enter the desired Channel ID - If you need help finding this,"
echo "see this: https://gist.github.com/goose-ws/1c82c98ac4701af433eb5c7562109e51"
read -p "> " userInput
if [[ -z "${userInput}" ]]; then
    echo "No input provided"
    panicExit 15;
elif [[ "${userInput}" =~ ^-100[[:digit:]]{10}$ ]]; then
    # This matches -100########## and is valid
    telegramChannelID="${userInput}"
else
    echo "Invalid Channel ID provided"
    panicExit 16;
fi
}
testTgAPI () {
echo ""
echo "Testing Telegram API..."
testTg="$(curl -s \
               -L \
               --data-urlencode "text=Test message - If you can see this, Telegram is configured correctly" \
               "https://api.telegram.org/bot${telegramBotID}/sendMessage?chat_id=${telegramChannelID}&parse_mode=html" 2>&1)"
if [[ "${?}" -ne "0" ]]; then
    echo "API call to Telegram failed"
    panicExit 17;
else
    # Check to make sure Telegram returned a true value for ok
    msgStatus="$(jq ".ok" <<<"${testTg}")"
    if [[ "${msgStatus}" == "true" ]]; then
        echo "API tested successfully"
    else
        echo "API test failed:"
        echo ""
        echo "${testTg}" | jq
        echo ""
        panicExit 18;
    fi
fi
}
writeConf () {
echo "Config summary:"
echo ""
echo "Linode API Key: ${apiKey}"
echo "DNS Record:     ${recordName}"
if [[ -n "${telegramBotID}" && -n "${telegramChannelID}" ]]; then
    echo "TG Bot API Key: ${telegramBotID}"
    echo "TG Channel ID:  ${telegramChannelID}"
fi
echo ""
echo "Save config?"
read -p "[y/n]> " userInput
if [[ "${userInput,,}" == "y" ]]; then
    echo "apiKey=\"${apiKey}\"" > "${envFile}"
    echo "recordName=\"${recordName}\"" >> "${envFile}"
    if [[ -n "${telegramBotID}" && -n "${telegramChannelID}" ]]; then
        echo "telegramBotID=\"${telegramBotID}\"" >> "${envFile}"
        echo "telegramChannelID=\"${telegramChannelID}\"" >> "${envFile}"
    fi
    echo ""
    echo "Done"
else
    echo "Discarding changes, exiting"
fi
rm -f "${lockFile}"
exit 0
}

## Placeholder for make config (Should result in an exit 0)
if [[ "${makeConf}" -eq "1" ]]; then
    if [[ -e "${envFile}" ]]; then
        echo "Previous config found"
        source "${envFile}"
        if [[ -n "${apiKey}" ]]; then
            echo "Found previous API key:"
            echo "${apiKey}"
            echo ""
            read -p "Keep? [y/n]: " userInput
            echo ""
            if [[ "${userInput,,}" == "y" ]]; then
                echo "Keeping previous API key"
            elif [[ "${userInput,,}" == "n" ]];  then
                mkApi;
            else
                echo "Invalid option"
                panicExit 19;
            fi
        fi
        if [[ -n "${recordName}" ]]; then
            echo "Found DNS record:"
            echo "${recordName}"
            echo ""
            read -p "Keep? [y/n]: " userInput
            echo ""
            if [[ "${userInput,,}" == "y" ]]; then
                echo "Keeping previous DNS record"
            elif [[ "${userInput,,}" == "n" ]];  then
                getDomains;
                mkDns;
            else
                echo "Invalid option"
                panicExit 20;
            fi
        fi
        if [[ -n "${telegramBotID}" ]]; then
            echo "Found Telegram API key:"
            echo "${telegramBotID}"
            echo ""
            read -p "Keep? [y/n]: " userInput
            echo ""
            if [[ "${userInput,,}" == "y" ]]; then
                echo "Keeping previous Telegram API key"
            elif [[ "${userInput,,}" == "n" ]];  then
                mkBotApi;
                echo ""
            else
                echo "Invalid option"
                panicExit 21;
            fi
        fi
        if [[ -n "${telegramChannelID}" ]]; then
            echo "Found Telegram channel ID:"
            echo "${telegramChannelID}"
            echo ""
            read -p "Keep? [y/n]: " userInput
            echo ""
            if [[ "${userInput,,}" == "y" ]]; then
                echo "Keeping previous Telegram channelID"
            elif [[ "${userInput,,}" == "n" ]];  then
                mkChanID;
                testTgAPI;
            else
                echo "Invalid option"
                panicExit 22;
            fi
        fi
        echo ""
        writeConf;
    else
        mkApi;
        echo ""
        echo -n "Testing API key..."
        getDomains;
        echo "Success"
        mkDns;
        echo ""
        echo "Would you like to configure a Telegram Bot to announce DNS changes?"
        read -p "[y/n]> " userInput
        echo ""
        if [[ "${userInput,,}" == "y" ]]; then
            mkBotApi;
            echo ""
            mkChanID;
            testTgAPI;
        elif ! [[ "${userInput,,}" == "n" ]]; then
            echo "Invalid option"
            panicExit 23;
        fi
        echo ""
        writeConf;
    fi
fi

if ! [[ -e "${envFile}" ]]; then
    echo "No config file found, please generate one with the command:"
    echo "${0} -c"
    panicExit 24;
else
    source "${envFile}"
fi

# Check our API key for validity
if [[ -z "${apiKey}" ]]; then
    echo "No API key set"
    panicExit 25;
elif ! [[ "${apiKey}" =~ ^[[:alnum:]]+$ ]]; then
    echo "API key contains something other than letters and numbers"
    panicExit 26;
fi

# Check our DNS record for validity
if [[ -z "${recordName}" ]]; then
    echo "No DNS record name is set"
    panicExit 27;
elif ! host "${recordName}" > /dev/null 2>&1; then
    echo "${recordName} does not appear to be a valid DNS record (Did you not create it yet?)"
    panicExit 28;
fi

if [[ "${runQuiet}" -eq "1" ]]; then
    exec > /dev/null 2>&1
fi

## Get our Domain ID
# Get a list of our domains:
domainData="$(curl -s \
                   -L \
                   -H "Authorization: Bearer ${apiKey}" \
                   "https://api.linode.com/v4/domains/")"
if jq -e . >/dev/null 2>&1 <<<"${domainData}"; then
    if [[ "$(jq " .errors[].reason" <<<"${domainData}" > /dev/null 2>&1)" == "\"Invalid Token\"" ]]; then
        echo "API key denied"
        panicExit 29;
    fi
    # Search the data for our domain
    levelOneDomain="${recordName}"
    domainID="$(jq " .data[] | select(.domain == \"${levelOneDomain}\") | .id" <<<"${domainData}")"
    # If that did not match, eliminate one level from the domain and re-check. Repeat until we find our level one domain, or we run out of items to remove.
    while [[ -z "${domainID}" && -n "${levelOneDomain}" ]]; do
        lastTry="${levelOneDomain}"
        levelOneDomain="${levelOneDomain#*.}"
        if [[ "${levelOneDomain}" == "${lastTry}" ]]; then
            break
        else
            domainID="$(jq " .data[] | select(.domain == \"${levelOneDomain}\") | .id" <<<"${domainData}")"
        fi
    done
else
    echo "Unable to obtain Domain ID"
    panicExit 30;
fi
if [[ -z "${domainID}" ]]; then
    echo "Failed to identify Domain ID"
    panicExit 31;
fi

# Remember our FQDN, before we start modifying ${recordName}
recordFQDN="${recordName}"

# Is our record name our first level domain?
if ! [[ "${recordName}" == "${levelOneDomain}" ]]; then
    # No, it is not. Remove the first level domain from the record name.
    recordName="${recordName%.${levelOneDomain}}"
    searchName="${recordName}"
else
    searchName=""
fi

## Get the resource ID:
resourceID="$(curl -s \
                   -L \
                   -H "Authorization: Bearer ${apiKey}" \
                   "https://api.linode.com/v4/domains/${domainID}/records/")"
if jq -e . >/dev/null 2>&1 <<<"${resourceID}"; then
    readarray -t resourceIDa < <(jq " .data[] | select((.name == \"${searchName}\") and (.type == \"A\")) | .id" <<<"${resourceID}")
    readarray -t resourceIDaaaa < <(jq " .data[] | select((.name == \"${searchName}\") and (.type == \"AAAA\")) | .id" <<<"${resourceID}")
else
    echo "Failed to get resource ID"
    panicExit 32;
fi
if [[ "${#resourceIDa[@]}" -eq "0" && "${#resourceIDaaaa[@]}" -eq "0" ]]; then
    echo "Failed to identify any resource ID's"
    panicExit 33;
fi
if [[ "${#resourceIDa[@]}" -gt "1" || "${#resourceIDaaaa[@]}" -gt "1" ]]; then
    echo "Identified multiple resource resource ID's"
    panicExit 34;
fi
if [[ "${#resourceIDa[@]}" -eq "0" ]]; then
    echo "Unable to find any A records for ${recordFQDN}, skipping IPv4 address update"
    updatev4="0"
fi
if [[ "${#resourceIDaaaa[@]}" -eq "0" ]]; then
    echo "Unable to find any AAAA records for ${recordFQDN}, skipping IPv6 address update"
    updatev6="0"
fi

if [[ "${updatev4}" -eq "1" ]]; then
    recordTargets="$(curl -s \
                     -L \
                     -H "Content-Type: application/json" \
                     -H "Authorization: Bearer ${apiKey}" \
                     "https://api.linode.com/v4/domains/${domainID}/records/${resourceIDa[0]}")"
    if jq -e . >/dev/null 2>&1 <<<"${recordTargets}"; then
        targetIPv4="$(jq "select((.name == \"${searchName}\") and (.type == \"A\")) | .target" <<<"${recordTargets}")"
        targetIPv4="${targetIPv4#\"}"
        targetIPv4="${targetIPv4%\"}"
        if ! [[ "${targetIPv4}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Failed to retrieve a valid target for IPv4 address for ${recordFQDN}"
            updatev4="0"
        fi
        #wanIPv4="$(dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com)"
        #wanIPv4="${wanIPv4#\"}"
        #wanIPv4="${wanIPv4%\"}"
        wanIPv4="$(curl -sL4 "https://checkip.amazonaws.com")"
        if ! [[ "${wanIPv4}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Failed to retrieve a valid local IPv4 address, will not update IPv4 address"
            updatev4="0"
        fi
    else
        echo "Failed to obtain records for Resource ID ${resourceID}"
        panicExit 35;
    fi
fi

if [[ "${updatev6}" -eq "1" ]]; then
    recordTargets="$(curl -s \
                    -L \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer ${apiKey}" \
                    "https://api.linode.com/v4/domains/${domainID}/records/${resourceIDaaaa[0]}")"
    if jq -e . >/dev/null 2>&1 <<<"${recordTargets}"; then
        targetIPv6="$(jq "select((.name == \"${searchName}\") and (.type == \"AAAA\")) | .target" <<<"${recordTargets}")"
        targetIPv6="${targetIPv6#\"}"
        targetIPv6="${targetIPv6%\"}"
        if ! [[ "${targetIPv6}" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
            echo "Failed to retrieve a valid target for IPv6 address for ${recordFQDN}"
            updatev6="0"
        fi
        #wanIPv6="$(dig -6 TXT +short o-o.myaddr.l.google.com @ns1.google.com)"
        #wanIPv6="${wanIPv6#\"}"
        #wanIPv6="${wanIPv6%\"}"
        wanIPv6="$(curl -sL6 "https://checkip.amazonaws.com")"
        if ! [[ "${wanIPv6}" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
            echo "Failed to retrieve a valid local IPv6 address, will not update IPv6 address"
            updatev6="0"
        fi
    else
        echo "Failed to obtain records for Resource ID ${resourceID}"
        panicExit 36;
    fi
fi

if [[ -z "${wanIPv4}" && -z "${wanIPv6}" ]]; then
    echo "Unable to obtain any local IPv4 or IPv6 addresses"
    panicExit 37;
fi

updatev4Addr () {
echo "Updating IPv4 address for ${recordFQDN} from ${targetIPv4} to ${wanIPv4}"
updateIP="$(curl -s \
     -L \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer ${apiKey}" \
     -X PUT -d '{
        "type": "A",
        "name": "'${searchName}'",
        "target": "'${wanIPv4}'",
        "priority": 0,
        "weight": 0,
        "port": 0,
        "service": null,
        "protocol": null,
        "ttl_sec": 0,
        "tag": null
     }' \
         "https://api.linode.com/v4/domains/${domainID}/records/${resourceIDa[0]}" 2>&1 )"
## Placeholder to check that our API call returned success
if [[ "${?}" -eq "0" ]]; then
    eventArr+=("IPv4 address for ${recordFQDN} updated from ${targetIPv4} to ${wanIPv4}")
else
    eventArr+=("IPv4 address for ${recordFQDN} update failed: $(printf "\r\n\r\n")$(echo "${updateIP}" | jq)")
fi
}
updatev6Addr () {
echo "Updating IPv6 address for ${recordFQDN} from ${targetIPv6} to ${wanIPv6}"
updateIP="$(curl -s \
     -L \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer ${apiKey}" \
     -X PUT -d '{
        "type": "AAAA",
        "name": "'${searchName}'",
        "target": "'${wanIPv6}'",
        "priority": 0,
        "weight": 0,
        "port": 0,
        "service": null,
        "protocol": null,
        "ttl_sec": 0,
        "tag": null
     }' \
         "https://api.linode.com/v4/domains/${domainID}/records/${resourceIDaaaa[0]}" 2>&1 )"
## Placeholder to check that our API call returned success
if [[ "${?}" -eq "0" ]]; then
    eventArr+=("IPv6 address for ${recordFQDN} updated from ${targetIPv6} to ${wanIPv6}")
else
    eventArr+=("IPv6 address for ${recordFQDN} update failed: $(printf "\r\n\r\n")$(echo "${updateIP}" | jq)")
fi
}

if [[ "${updatev4}" -eq "1" ]]; then
    if [[ ! "${wanIPv4}" == "${targetIPv4}" && -n "${wanIPv4}" ]]; then
        updatev4Addr;
    fi
fi
if [[ "${updatev6}" -eq "1" ]]; then
    if [[ ! "${wanIPv6}" == "${targetIPv6}" && -n "${wanIPv6}" ]]; then
        updatev6Addr;
    fi
fi

if [[ -n "${telegramBotID}" && -n "${telegramChannelID}" && "${#eventArr[@]}" -ne "0" ]]; then
    eventText="<b>DNS Record Updated</b>$(printf "\r\n\r\n\r\n")$(for i in "${eventArr[@]}"; do echo "${i}"; done)"
    sendMsg="$(curl -s \
                    -L \
                    --data-urlencode "text=${eventText}" \
                    "https://api.telegram.org/bot${telegramBotID}/sendMessage?chat_id=${telegramChannelID}&parse_mode=html" 2>&1)"
    if [[ "${?}" -ne "0" ]]; then
        echo "API call to Telegram failed"
        panicExit 38;
    else
        # Check to make sure Telegram returned a true value for ok
        msgStatus="$(jq ".ok" <<<"${sendMsg}")"
        if ! [[ "${msgStatus}" == "true" ]]; then
            echo "Failed to send Telegram message:"
            echo ""
            echo "${sendMsg}" | jq
            echo ""
            panicExit 39;
        fi
    fi
fi
rm "${lockFile}"
