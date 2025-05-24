#!/usr/bin/env bash

if [[ -z "${BASH_VERSINFO[0]}" || "${BASH_VERSINFO[0]}" -lt "4" ]]; then
    echo "This script requires Bash version 4 or greater"
    exit 255
fi

if ! [ -e "/usr/bin/yq" ]; then
    wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64 -O /usr/bin/yq
    chmod +x /usr/bin/yq
fi

if ! [ -e "/usr/bin/sqlite3" ]; then
    apt install sqlite3 -y
fi

# Dependency check
depsArr=("curl" "date" "realpath" "sqlite3" "yq")
depFail="0"
for i in "${depsArr[@]}"; do
    if [[ "${i:0:1}" == "/" ]]; then
        if ! [[ -e "${i}" ]]; then
            echo "Missing dependency [${i}]"
            depFail="1"
        fi
    else
        if ! command -v "${i}" > /dev/null 2>&1; then
            echo "Missing dependency [${i}]"
            depFail="1"
        fi
    fi
done
if [[ "${depFail}" -eq "1" ]]; then
    echo "Dependency check failed"
    exit 255
fi

# Define some external variables
telegramBotId="6464203996:AAHjbdf3YZzT5uXySqYSlVr8xoylcymzNfs"
telegramChannelId="-1001317880548"
localDNS="10.10.10.10"
outputVerbosity="4"

# Define some internal variables
scriptName="${0##*/}"
scriptName="${scriptName%.*}"
realPath="$(realpath "${0}")"
sqliteDb="${realPath%/*}/.${scriptName}.db"
lockFile="${realPath%/*}/.${scriptName}.lock"
logFile="${realPath%/*}/${scriptName}.log"
lineBreak=$'\n'

# Define some functions
function printOutput {
case "${1}" in
    0) logLevel="[${colorRed}reqrd${colorReset}]";; # Required
    1) logLevel="[${colorRed}error${colorReset}]";; # Errors
    2) logLevel="[${colorYellow}warn${colorReset}] ";; # Warnings
    3) logLevel="[${colorGreen}info${colorReset}] ";; # Informational
    4) logLevel="[${colorCyan}verb${colorReset}] ";; # Verbose
    5) logLevel="[${colorPurple}DEBUG${colorReset}]";; # Super Secret Debug Mode
esac
if [[ "${1}" -le "${outputVerbosity}" ]]; then
    echo -e "${0##*/}   ::   $(date "+%Y-%m-%d %H:%M:%S")   ::   ${logLevel} ${2}"
fi
if [[ "${1}" -le "1" ]]; then
    errorArr+=("${2}")
fi
}

function removeLock {
if rm -f "${lockFile}"; then
    if ! [[ "${1}" == "silent" ]]; then
        printOutput "4" "Lockfile removed"
    fi
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
    printOutput "1" "${2} [Error code: ${1}]"
    exit 1
fi
}

function cleanExit {
if [[ "${1}" == "silent" ]]; then
    removeLock "silent"
else
    removeLock
fi
exit 0
}

function rawUrlEncode {
local string="${1}"
local strlen="${#string}"
local encoded=()  # Declare encoded as an array
local pos c o

for (( pos=0 ; pos<strlen ; pos++ )); do
    c="${string:$pos:1}"
    if [[ "$c" =~ [[:ascii:]] ]]; then
        case "${c}" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * ) printf -v o '%%%02x' "'${c}" ;;
        esac
    else
        o=$(echo -n "$c" | xxd -p -c1 | while read -r line; do echo -n "%${line}"; done)
    fi
    encoded+=("${o}")  # Add the encoded character to the array
done
printf "%s" "${encoded[@]}"
}

function callCurlGet {
# URL to call should be ${1}
# Custom UA can be ${2}
# Will return the variable ${curlOutput}
if [[ -z "${1}" ]]; then
    badExit "1" "No input URL provided for GET"
fi
if [[ -z "${2}" ]]; then
    curlOutput="$(curl -skL -m 15 "${1}" 2>&1)"
else
    curlOutput="$(curl -skL -m 15 -A "${2}" "${1}" 2>&1)"
fi
curlExitCode="${?}"
retryCount=0
retryDelay=5
while [[ "${curlExitCode}" -eq "28" ]] && [[ "${retryDelay}" -le 30 ]]; do
    printOutput "2" "Curl timed out, waiting ${retryDelay} seconds then trying again (attempt ${retryCount})"
    sleep "${retryDelay}"
    if [[ -z "${2}" ]]; then
        curlOutput="$(curl -skL "${1}" 2>&1)"
    else
        curlOutput="$(curl -skL -A "${2}" "${1}" 2>&1)"
    fi
    curlExitCode="${?}"
    retryDelay="$(( retryDelay + 5 ))"
    retryCount="$(( retryCount + 1 ))"
done

if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    printOutput "1" "Curl output:"
    while read -r i; do
        printOutput "1" "${i}"
    done <<<"${curlOutput}"
    badExit "2" "Bad curl output"
fi
}

function sendTelegramMessage {
# Message to send should be passed as function positional parameter #1
callCurlGet "https://api.telegram.org/bot${telegramBotId}/getMe"
if ! [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
    printOutput "1" "Telegram bot API check failed"
else
    printOutput "4" "Telegram bot API key authenticated [$(yq -p json ".result.username" <<<"${curlOutput}")]"
    callCurlGet "https://api.telegram.org/bot${telegramBotId}/getChat?chat_id=${telegramChannelId}"
    if [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
        printOutput "4" "Telegram channel authenticated [$(yq -p json ".result.title" <<<"${curlOutput}")]"
        msgEncoded="$(rawUrlEncode "${1}")"
        callCurlGet "https://api.telegram.org/bot${telegramBotId}/sendMessage?chat_id=${telegramChannelId}&parse_mode=html&text=${msgEncoded}"
        # Check to make sure Telegram returned a true value for ok
        if ! [[ "$(yq -p json ".ok" <<<"${curlOutput}")" == "true" ]]; then
            printOutput "1" "Failed to send Telegram message:"
            printOutput "1" ""
            while read -r i; do
                printOutput "1" "${i}"
            done < <(yq -p json "." <<<"${curlOutput}")
            printOutput "1" ""
        else
            printOutput "4" "Telegram message sent successfully"
        fi
    else
        printOutput "1" "Telegram channel check failed"
    fi
fi
}

function sqDb {
# Log the command we're executing to the database, for development purposes
# Execute the command
if sqOutput="$(sqlite3 "${sqliteDb}" "${1}" 2>&1)"; then
    if [[ -n "${sqOutput}" ]]; then
        echo "${sqOutput}"
    fi
else
    sqlite3 "${sqliteDb}" "INSERT OR IGNORE INTO db_log (COMMAND, OUTPUT, TIME) VALUES ('${1//\'/\'\'}', '${sqOutput//\'/\'\'}', '$(date)');"
    if [[ -n "${sqOutput}" ]]; then
        echo "${sqOutput}"
    fi
    return 1
fi
}

function readLog {
# Read old entries
while read -r _timestamp _hostname _daemon _vlan _addr _mac _name; do
    if ! [[ "${_vlan}" =~ ^"DHCPACK".* ]]; then
        # Not a DHCPACK line
        continue
    fi
    # We are a DHCPACK line
    # Clean up our VLAN variable
    printOutput "5" "Pre-sanitized VLAN [${_vlan}]"
    _vlan="${_vlan#DHCPACK\(br}"
    _vlan="${_vlan%\)}"
    printOutput "5" "Post-sanitized VLAN [${_vlan}]"
    if ! [[ "${_vlan}" =~ ^[0-9]+$ ]]; then
        printOutput "1" "Invalid VLAN [${_vlan}]"
        continue
    fi
    if [[ -z "${_name}" ]]; then
        _name="[No client name]"
    fi
    # Check and see if we already have this MAC/IP logged under this VLAN and timestamp
    dbCount="$(sqDb "SELECT COUNT(1) FROM client WHERE VLAN = '${_vlan//\'/\'\'}' AND MAC = '${_mac//\'/\'\'}' AND IP = '${_addr//\'/\'\'}';")"
    if [[ "${dbCount}" -ne "0" ]]; then
        printOutput "3" "Skipping previously logged client [${_name}]"
        printOutput "5" "VLAN [${_vlan}] | MAC [${_mac}] | IP [${_addr}]"
        continue
    fi
    # Check and see if we have a local entry for it
    if _locName="$(host "${_addr}" "${localDNS}")"; then
        # We do, probably
        _locName="$(tail -n 1 <<<"${_locName}")"
        _locName="${_locName#* domain name pointer }"
        _locName="${_locName%.}"
    else
        _locName="[No local address found]"
    fi
    # Check and see if we've logged this MAC before
    _macLogged="$(sqDb "SELECT COUNT(1) FROM client WHERE MAC = '${_mac//\'/\'\'}';")"
    if [[ "${macLogged}" -eq "0" ]]; then
        _macLogged="No"
    else
        _macLogged="Yes"
    fi
    # We have zero DB entries for this, let's create one
    if sqDb "INSERT OR IGNORE INTO client (VLAN, MAC, IP, NAME, CREATED) VALUES ('${_vlan//\'/\'\'}', '${_mac//\'/\'\'}', '${_addr//\'/\'\'}', '${_name//\'/\'\'}', '$(date)');"; then
        printOutput "3" "Logged new client [${_name}] on VLAN ID [${_vlan}] with MAC address [${_mac}] and IP address [${_addr}]"
        # Send a telegram message
        sendTelegramMessage "$(printf '<b>Unifi Client Monitor</b>\n\nClient Name: <code>%s</code>\nLocal Address: <code>%s</code>\nVLAN ID: <code>%s</code>\nMAC Address: <code>%s</code>\nMAC seen before: <code>%s</code>\nIP Address: <code>%s</code>\n' \
                              "${_name}" \
                              "${_locName}" \
                              "${_vlan}" \
                              "${_mac}" \
                              "${_macLogged}" \
                              "${_addr}")"
    else
        printOutput "1" "Failed to log new client [${_name}] on VLAN ID [${_vlan}] with MAC address [${_mac}] and IP address [${_addr}]"
    fi
done < "/var/log/daemon.log"

# Now read new entries
while read -r _timestamp _hostname _daemon _vlan _addr _mac _name; do
    if ! [[ "${_vlan}" =~ ^"DHCPACK".* ]]; then
        # Not a DHCPACK line
        continue
    fi
    # We are a DHCPACK line
    # Clean up our VLAN variable
    printOutput "5" "Pre-sanitized VLAN [${_vlan}]"
    _vlan="${_vlan#DHCPACK\(br}"
    _vlan="${_vlan%\)}"
    printOutput "5" "Post-sanitized VLAN [${_vlan}]"
    if ! [[ "${_vlan}" =~ ^[0-9]+$ ]]; then
        printOutput "1" "Invalid VLAN [${_vlan}]"
        continue
    fi
    if [[ -z "${_name}" ]]; then
        _name="[No client name]"
    fi
    # Check and see if we already have this MAC/IP logged under this VLAN and timestamp
    dbCount="$(sqDb "SELECT COUNT(1) FROM client WHERE VLAN = '${_vlan//\'/\'\'}' AND MAC = '${_mac//\'/\'\'}' AND IP = '${_addr//\'/\'\'}';")"
    if [[ "${dbCount}" -ne "0" ]]; then
        printOutput "3" "Skipping previously logged client [${_name}]"
        printOutput "5" "VLAN [${_vlan}] | MAC [${_mac}] | IP [${_addr}]"
        continue
    fi
    # Check and see if we have a local entry for it
    if _locName="$(host "${_addr}" "${localDNS}")"; then
        # We do, probably
        _locName="$(tail -n 1 <<<"${_locName}")"
        _locName="${_locName#* domain name pointer }"
        _locName="${_locName%.}"
    else
        _locName="[No local DNS record found]"
    fi
    # Check and see if we've logged this MAC before
    _macLogged="$(sqDb "SELECT COUNT(1) FROM client WHERE MAC = '${_mac//\'/\'\'}';")"
    if [[ "${macLogged}" -eq "0" ]]; then
        _macLogged="No"
    else
        _macLogged="Yes"
    fi
    # We have zero DB entries for this, let's create one
    if sqDb "INSERT OR IGNORE INTO client (VLAN, MAC, IP, NAME, CREATED) VALUES ('${_vlan//\'/\'\'}', '${_mac//\'/\'\'}', '${_addr//\'/\'\'}', '${_name//\'/\'\'}', '$(date)');"; then
        printOutput "3" "Logged new client [${_name}] on VLAN ID [${_vlan}] with MAC address [${_mac}] and IP address [${_addr}]"
        # Send a telegram message
        sendTelegramMessage "$(printf '<b>Unifi Client Monitor</b>\n\nClient Name: <code>%s</code>\nLocal Name: <code>%s</code>\nVLAN ID: <code>%s</code>\nMAC Address: <code>%s</code>\nMAC seen before: <code>%s</code>\nIP Address: <code>%s</code>\n' \
                              "${_name}" \
                              "${_locName}" \
                              "${_vlan}" \
                              "${_mac}" \
                              "${_macLogged}" \
                              "${_addr}")"
    else
        printOutput "1" "Failed to log new client [${_name}] on VLAN ID [${_vlan}] with MAC address [${_mac}] and IP address [${_addr}]"
    fi
done < <(tail -q -n 0 -F "/var/log/daemon.log")
}

# Check if lockfile exists and process is still running
if [[ -e "${lockFile}" ]]; then
    existingPid="$(<"${lockFile}")"
    if kill -0 "${existingPid}" > /dev/null 2>&1; then
        # Valid running process, do not start another
        printOutput "3" "Already running PID [${existingPid}], exiting"
        exit 0
    else
        printOutput "2" "Stale lockfile found for PID [${existingPid}], removing"
        rm -f "${lockFile}"
    fi
fi

# Signal traps
trap "badExit SIGINT" INT
trap "badExit SIGQUIT" QUIT
trap "cleanExit" EXIT

# If our database does not exist, initialize it
if ! [[ -e "${sqliteDb}" ]]; then
    if sqlite3 "${sqliteDb}" "CREATE TABLE client(
    INT_ID INTEGER PRIMARY KEY AUTOINCREMENT,
    VLAN INTEGER,
    MAC TEXT,
    IP TEXT,
    NAME TEXT,
    CREATED TEXT
    );"; then
        printOutput "5" "Initialized sqlite DB [${sqliteDb}]"
    else
        badExit "1" "Failed to initialize sqlite DB [${sqliteDb}]"
    fi
    if sqlite3 "${sqliteDb}" "CREATE TABLE db_log(
    INT_ID INTEGER PRIMARY KEY AUTOINCREMENT,
    COMMAND TEXT,
    OUTPUT TEXT,
    TIME TEXT
    );"; then
        printOutput "5" "Initialized sqlite error log [${sqliteDb}]"
    else
        badExit "2" "Failed to initialize sqlite error log [${sqliteDb}]"
    fi
fi

# Start readLog in background and store its PID
while ! [[ -e "/var/log/daemon.log" ]]; do
    printOutput "3" "Waiting for daemon.log to be written..."
    sleep 10
done

printOutput "3" "Initializing readLog function"
readLog >> "${logFile}" 2>&1 &

echo "${!}" > "${lockFile}"
printOutput "3" "Started readLog in background [PID ${!}]"

# Let the script exit while readLog continues
exit 0
