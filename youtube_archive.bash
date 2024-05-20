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
if ! [ -e "/bin/bash" ]; then
    echo "This script requires Bash"
    exit 255
fi
if [[ -z "${BASH_VERSINFO[0]}" || "${BASH_VERSINFO[0]}" -lt "4" ]]; then
    echo "This script requires Bash version 4 or greater"
    exit 255
fi
depArr=("awk" "curl" "md5sum" "printf" "rm")
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
updateURL="https://raw.githubusercontent.com/goose-ws/bash-scripts/main/ytdlp-plex-mirror.bash"
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
if [[ "${1}" -eq "1" ]]; then
    errorArr+=("${2}")
fi
}

function removeLock {
if rm -f "${lockFile}"; then
    printOutput "4" "Lockfile removed"
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
    printOutput "1" "${2}"
    exit "${1}"
fi
}

function cleanExit {
removeLock
exit 0
}

function callCurl {
# URL to call should be ${1}
if [[ -z "${1}" ]]; then
    badExit "1" "No input URL provided for GET"
fi
curlOutput="$(curl -skL "${1}" 2>&1)"
curlExitCode="${?}"
if [[ "${curlExitCode}" -eq "28" ]]; then
    printOutput "2" "Curl timed out, waiting 10 seconds then trying again"
    sleep 10
    curlOutput="$(curl -skL "${1}" 2>&1)"
    curlExitCode="${?}"
fi
if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    while read -r i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    badExit "2" "Bad curl output"
fi
}

function timeDiff {
# Start time should be passed as ${1}
# End time can be passed as ${2}
# If no end time is defined, will use the time the function is called as the end time
# Time should be provided via: startTime="$(($(date +%s%N)/1000000))"
if [[ -z "${1}" ]]; then
    echo "No start time provided"
else
    startTime="${1}"
fi
if [[ -z "${2}" ]]; then
    endTime="$(($(date +%s%N)/1000000))"
fi

if [[ "$(( ${endTime:0:10} - ${startTime:0:10} ))" -le "5" ]]; then
    printf "%sms\n" "$(( endTime - startTime ))"
else
    local T="$(( ${endTime:0:10} - ${startTime:0:10} ))"
    local D="$((T/60/60/24))"
    local H="$((T/60/60%24))"
    local M="$((T/60%60))"
    local S="$((T%60))"
    (( D > 0 )) && printf '%dd' "${D}"
    (( H > 0 )) && printf '%dh' "${H}"
    (( M > 0 )) && printf '%dm' "${M}"
    (( D > 0 || H > 0 || M > 0 ))
    printf '%ds\n' "${S}"
fi
}

#############################
##     Unique Functions    ##
#############################

function callCurlPost {
# URL to call should be ${1}
if [[ -z "${1}" ]]; then
    badExit "3" "No input URL provided for POST"
fi
# ${2} could be --data-binary and ${3} could be an image to be uploaded
if [[ "${2}" == "--data-binary" ]]; then
    curlOutput="$(curl -skL -X POST "${1}" --data-binary "${3}" 2>&1)"
else
    curlOutput="$(curl -skL -X POST "${1}" 2>&1)"
fi
curlExitCode="${?}"
if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    while read -r i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    badExit "4" "Bad curl output"
fi
}

function callCurlPut {
# URL to call should be $1
if [[ -z "${1}" ]]; then
    badExit "5" "No input URL provided for PUT"
fi
curlOutput="$(curl -skL -X PUT "${1}" 2>&1)"
curlExitCode="${?}"
if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    while read -r i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    badExit "6" "Bad curl output"
fi
}

function callCurlDelete {
# URL to call should be $1
if [[ -z "${1}" ]]; then
    badExit "7" "No input URL provided for DELETE"
fi
curlOutput="$(curl -skL -X DELETE "${1}" 2>&1)"
curlExitCode="${?}"
if [[ "${curlExitCode}" -ne "0" ]]; then
    printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    while read -r i; do
        printOutput "1" "Output: ${i}"
    done <<<"${curlOutput}"
    badExit "8" "Bad curl output"
fi
}

function callCurlDownload {
# URL to call should be $1, output should be $2
if [[ -z "${1}" ]]; then
    badExit "9" "No input URL provided for download"
elif [[ -z "${2}" ]]; then
    badExit "10" "No output path provided for download"
fi
curlOutput="$(curl -skL "${1}" -o "${2}" 2>&1)"
# curlExitCode="${?}"
# if [[ "${curlExitCode}" -ne "0" ]]; then
    # printOutput "1" "Curl returned non-zero exit code ${curlExitCode}"
    # while read -r i; do
        # printOutput "1" "Output: ${i}"
    # done <<<"${curlOutput}"
    # badExit "11" "Bad curl output"
# fi
}

function plexOutputToJson {
curlOutput="$(xq <<<"${curlOutput}" | jq -M ".")"
}

function getContainerIp {
if ! [[ "${containerIp}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
    # Container name should be passed as positional paramter #1
    # It will return the variable ${containerIp} if successful
    printOutput "3" "Attempting to automatically determine container IP address for container: ${1}"

    if [[ "${1%%:*}" == "docker" ]]; then
        unset containerNetworking
        while read -r i; do
            if [[ -n "${i}" ]]; then
                containerNetworking+=("${i}")
            fi
        done < <(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "${1#*:}")
        if [[ "${#containerNetworking[@]}" -eq "0" ]]; then
            printOutput "3" "No network type defined. Checking to see if networking is through another container."
            containerIp="$(docker inspect "${1#*:}" | jq -M -r ".[].HostConfig.NetworkMode")"
            printOutput "4" "Host config network mode: ${containerIp}"
            if [[ "${containerIp%%:*}" == "container" ]]; then
                printOutput "3" "Networking routed through another container. Retrieving IP address."
                containerIp="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${containerIp#container:}")"
            else
                printOutput "1" "Unable to determine networking type"
                unset containerIp
            fi
        else
            printOutput "4" "Container is utilizing ${#containerNetworking[@]} network type(s): ${containerNetworking[*]}"
            for i in "${containerNetworking[@]}"; do
                if [[ "${i}" == "host" ]]; then
                    printOutput "4" "Networking type: ${i}"
                    containerIp="127.0.0.1"
                else
                    printOutput "4" "Networking type: ${i}"
                    containerIp="$(docker inspect "${1#*:}" | jq -M -r ".[] | .NetworkSettings.Networks.${i}.IPAddress")"
                    if [[ "${containerIp}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
                        break
                    fi
                fi
            done
        fi
    else
        badExit "12" "Unknown container daemon: ${1%%:*}"
    fi
fi

if [[ -z "${containerIp}" ]] || ! [[ "${containerIp}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.([0-9]{1,3}|[0-9]/[0-9]{1,2})$ ]]; then
    badExit "13" "Unable to determine IP address via networking mode: ${i}"
else
    printOutput "4" "Container IP address: ${containerIp}"
fi
}

function getChannelCountry {
case "${2}" in
    AF) channelCountry[${1}]="Afghanistan";;
    AX) channelCountry[${1}]="Aland Islands";;
    AL) channelCountry[${1}]="Albania";;
    DZ) channelCountry[${1}]="Algeria";;
    AS) channelCountry[${1}]="American Samoa";;
    AD) channelCountry[${1}]="Andorra";;
    AO) channelCountry[${1}]="Angola";;
    AI) channelCountry[${1}]="Anguilla";;
    AQ) channelCountry[${1}]="Antarctica";;
    AG) channelCountry[${1}]="Antigua And Barbuda";;
    AR) channelCountry[${1}]="Argentina";;
    AM) channelCountry[${1}]="Armenia";;
    AW) channelCountry[${1}]="Aruba";;
    AU) channelCountry[${1}]="Australia";;
    AT) channelCountry[${1}]="Austria";;
    AZ) channelCountry[${1}]="Azerbaijan";;
    BS) channelCountry[${1}]="the Bahamas";;
    BH) channelCountry[${1}]="Bahrain";;
    BD) channelCountry[${1}]="Bangladesh";;
    BB) channelCountry[${1}]="Barbados";;
    BY) channelCountry[${1}]="Belarus";;
    BE) channelCountry[${1}]="Belgium";;
    BZ) channelCountry[${1}]="Belize";;
    BJ) channelCountry[${1}]="Benin";;
    BM) channelCountry[${1}]="Bermuda";;
    BT) channelCountry[${1}]="Bhutan";;
    BO) channelCountry[${1}]="Bolivia";;
    BQ) channelCountry[${1}]="Bonaire";;
    BA) channelCountry[${1}]="Bosnia And Herzegovina";;
    BW) channelCountry[${1}]="Botswana";;
    BV) channelCountry[${1}]="Bouvet Island";;
    BR) channelCountry[${1}]="Brazil";;
    IO) channelCountry[${1}]="British Indian Ocean Territory";;
    BN) channelCountry[${1}]="Brunei Darussalam";;
    BG) channelCountry[${1}]="Bulgaria";;
    BF) channelCountry[${1}]="Burkina Faso";;
    BI) channelCountry[${1}]="Burundi";;
    KH) channelCountry[${1}]="Cambodia";;
    CM) channelCountry[${1}]="Cameroon";;
    CA) channelCountry[${1}]="Canada";;
    CV) channelCountry[${1}]="Cape Verde";;
    KY) channelCountry[${1}]="the Cayman Islands";;
    CF) channelCountry[${1}]="the Central African Republic";;
    TD) channelCountry[${1}]="Chad";;
    CL) channelCountry[${1}]="Chile";;
    CN) channelCountry[${1}]="China";;
    CX) channelCountry[${1}]="Christmas Island";;
    CC) channelCountry[${1}]="Cocos Keeling Islands";;
    CO) channelCountry[${1}]="Colombia";;
    KM) channelCountry[${1}]="the Comoros";;
    CG) channelCountry[${1}]="Congo";;
    CK) channelCountry[${1}]="Cook Islands";;
    CR) channelCountry[${1}]="Costa Rica";;
    CI) channelCountry[${1}]="Cote D'ivoire";;
    HR) channelCountry[${1}]="Croatia";;
    CU) channelCountry[${1}]="Cuba";;
    CW) channelCountry[${1}]="Curacao";;
    CY) channelCountry[${1}]="Cyprus";;
    CZ) channelCountry[${1}]="the Czech Republic";;
    DK) channelCountry[${1}]="Denmark";;
    DJ) channelCountry[${1}]="Djibouti";;
    DM) channelCountry[${1}]="Dominica";;
    DO) channelCountry[${1}]="the Dominican Republic";;
    EC) channelCountry[${1}]="Ecuador";;
    EG) channelCountry[${1}]="Egypt";;
    SV) channelCountry[${1}]="El Salvador";;
    GQ) channelCountry[${1}]="Equatorial Guinea";;
    ER) channelCountry[${1}]="Eritrea";;
    EE) channelCountry[${1}]="Estonia";;
    ET) channelCountry[${1}]="Ethiopia";;
    FK) channelCountry[${1}]="the Falkland Islands Malvinas";;
    FO) channelCountry[${1}]="Faroe Islands";;
    FJ) channelCountry[${1}]="Fiji";;
    FI) channelCountry[${1}]="Finland";;
    FR) channelCountry[${1}]="France";;
    GF) channelCountry[${1}]="French Guiana";;
    PF) channelCountry[${1}]="French Polynesia";;
    TF) channelCountry[${1}]="French Southern Territories";;
    GA) channelCountry[${1}]="Gabon";;
    GM) channelCountry[${1}]="Gambia";;
    GE) channelCountry[${1}]="Georgia";;
    DE) channelCountry[${1}]="Germany";;
    GH) channelCountry[${1}]="Ghana";;
    GI) channelCountry[${1}]="Gibraltar";;
    GR) channelCountry[${1}]="Greece";;
    GL) channelCountry[${1}]="Greenland";;
    GD) channelCountry[${1}]="Grenada";;
    GP) channelCountry[${1}]="Guadeloupe";;
    GU) channelCountry[${1}]="Guam";;
    GT) channelCountry[${1}]="Guatemala";;
    GG) channelCountry[${1}]="Guernsey";;
    GN) channelCountry[${1}]="Guinea";;
    GW) channelCountry[${1}]="Guinea-Bissau";;
    GY) channelCountry[${1}]="Guyana";;
    HT) channelCountry[${1}]="Haiti";;
    HM) channelCountry[${1}]="Heard Mcdonald Islands";;
    HN) channelCountry[${1}]="Honduras";;
    HK) channelCountry[${1}]="Hong Kong";;
    HU) channelCountry[${1}]="Hungary";;
    IS) channelCountry[${1}]="Iceland";;
    IN) channelCountry[${1}]="India";;
    ID) channelCountry[${1}]="Indonesia";;
    IR) channelCountry[${1}]="Iran";;
    IQ) channelCountry[${1}]="Iraq";;
    IE) channelCountry[${1}]="Ireland";;
    IM) channelCountry[${1}]="the Isle Of Man";;
    IL) channelCountry[${1}]="Israel";;
    IT) channelCountry[${1}]="Italy";;
    JM) channelCountry[${1}]="Jamaica";;
    JP) channelCountry[${1}]="Japan";;
    JE) channelCountry[${1}]="Jersey";;
    JO) channelCountry[${1}]="Jordan";;
    KZ) channelCountry[${1}]="Kazakhstan";;
    KE) channelCountry[${1}]="Kenya";;
    KI) channelCountry[${1}]="Kiribati";;
    KP) channelCountry[${1}]="North Korea";;
    KR) channelCountry[${1}]="South Korea";;
    XK) channelCountry[${1}]="Kosovo";;
    KW) channelCountry[${1}]="Kuwait";;
    KG) channelCountry[${1}]="Kyrgyzstan";;
    LA) channelCountry[${1}]="Laos";;
    LV) channelCountry[${1}]="Latvia";;
    LB) channelCountry[${1}]="Lebanon";;
    LS) channelCountry[${1}]="Lesotho";;
    LR) channelCountry[${1}]="Liberia";;
    LY) channelCountry[${1}]="Libya";;
    LI) channelCountry[${1}]="Liechtenstein";;
    LT) channelCountry[${1}]="Lithuania";;
    LU) channelCountry[${1}]="Luxembourg";;
    MO) channelCountry[${1}]="Macao";;
    MK) channelCountry[${1}]="Macedonia";;
    MG) channelCountry[${1}]="Madagascar";;
    MW) channelCountry[${1}]="Malawi";;
    MY) channelCountry[${1}]="Malaysia";;
    MV) channelCountry[${1}]="the Maldives";;
    ML) channelCountry[${1}]="Mali";;
    MT) channelCountry[${1}]="Malta";;
    MH) channelCountry[${1}]="the Marshall Islands";;
    MQ) channelCountry[${1}]="Martinique";;
    MR) channelCountry[${1}]="Mauritania";;
    MU) channelCountry[${1}]="Mauritius";;
    YT) channelCountry[${1}]="Mayotte";;
    MX) channelCountry[${1}]="Mexico";;
    FM) channelCountry[${1}]="Micronesia";;
    MD) channelCountry[${1}]="Moldova";;
    MC) channelCountry[${1}]="Monaco";;
    MN) channelCountry[${1}]="Mongolia";;
    ME) channelCountry[${1}]="Montenegro";;
    MS) channelCountry[${1}]="Montserrat";;
    MA) channelCountry[${1}]="Morocco";;
    MZ) channelCountry[${1}]="Mozambique";;
    MM) channelCountry[${1}]="Myanmar";;
    NA) channelCountry[${1}]="Namibia";;
    NR) channelCountry[${1}]="Nauru";;
    NP) channelCountry[${1}]="Nepal";;
    NL) channelCountry[${1}]="the Netherlands";;
    NC) channelCountry[${1}]="New Caledonia";;
    NZ) channelCountry[${1}]="New Zealand";;
    NI) channelCountry[${1}]="Nicaragua";;
    NE) channelCountry[${1}]="Niger";;
    NG) channelCountry[${1}]="Nigeria";;
    NU) channelCountry[${1}]="Niue";;
    NF) channelCountry[${1}]="Norfolk Island";;
    MP) channelCountry[${1}]="Northern Mariana Islands";;
    NO) channelCountry[${1}]="Norway";;
    OM) channelCountry[${1}]="Oman";;
    PK) channelCountry[${1}]="Pakistan";;
    PW) channelCountry[${1}]="Palau";;
    PS) channelCountry[${1}]="Palestinian Territory";;
    PA) channelCountry[${1}]="Panama";;
    PG) channelCountry[${1}]="Papua New Guinea";;
    PY) channelCountry[${1}]="Paraguay";;
    PE) channelCountry[${1}]="Peru";;
    PH) channelCountry[${1}]="the Philippines";;
    PN) channelCountry[${1}]="Pitcairn";;
    PL) channelCountry[${1}]="Poland";;
    PT) channelCountry[${1}]="Portugal";;
    PR) channelCountry[${1}]="Puerto Rico";;
    QA) channelCountry[${1}]="Qatar";;
    RE) channelCountry[${1}]="Reunion";;
    RO) channelCountry[${1}]="Romania";;
    RU) channelCountry[${1}]="Russia";;
    RW) channelCountry[${1}]="Rwanda";;
    BL) channelCountry[${1}]="Saint Barthelemy";;
    SH) channelCountry[${1}]="Saint Helena";;
    KN) channelCountry[${1}]="Saint Kitts And Nevis";;
    LC) channelCountry[${1}]="Saint Lucia";;
    MF) channelCountry[${1}]="Saint Martin French";;
    PM) channelCountry[${1}]="Saint Pierre And Miquelon";;
    VC) channelCountry[${1}]="Saint Vincent And Grenadines";;
    WS) channelCountry[${1}]="Samoa";;
    SM) channelCountry[${1}]="San Marino";;
    ST) channelCountry[${1}]="Sao Tome And Principe";;
    SA) channelCountry[${1}]="Saudi Arabia";;
    SN) channelCountry[${1}]="Senegal";;
    RS) channelCountry[${1}]="Serbia";;
    SC) channelCountry[${1}]="Seychelles";;
    SL) channelCountry[${1}]="Sierra Leone";;
    SG) channelCountry[${1}]="Singapore";;
    SX) channelCountry[${1}]="Sint Maarten Dutch";;
    SK) channelCountry[${1}]="Slovakia";;
    SI) channelCountry[${1}]="Slovenia";;
    SB) channelCountry[${1}]="Solomon Islands";;
    SO) channelCountry[${1}]="Somalia";;
    ZA) channelCountry[${1}]="South Africa";;
    GS) channelCountry[${1}]="South Georgia And South Sandwich Islands";;
    SS) channelCountry[${1}]="South Sudan";;
    ES) channelCountry[${1}]="Spain";;
    LK) channelCountry[${1}]="Sri Lanka";;
    SD) channelCountry[${1}]="Sudan";;
    SR) channelCountry[${1}]="Suriname";;
    SJ) channelCountry[${1}]="Svalbard And Jan Mayen";;
    SZ) channelCountry[${1}]="Swaziland";;
    SE) channelCountry[${1}]="Sweden";;
    CH) channelCountry[${1}]="Switzerland";;
    SY) channelCountry[${1}]="Syria";;
    TW) channelCountry[${1}]="Taiwan";;
    TJ) channelCountry[${1}]="Tajikistan";;
    TZ) channelCountry[${1}]="Tanzania";;
    TH) channelCountry[${1}]="Thailand";;
    TL) channelCountry[${1}]="Timor-Leste";;
    TG) channelCountry[${1}]="Togo";;
    TK) channelCountry[${1}]="Tokelau";;
    TO) channelCountry[${1}]="Tonga";;
    TT) channelCountry[${1}]="Trinidad And Tobago";;
    TN) channelCountry[${1}]="Tunisia";;
    TR) channelCountry[${1}]="Turkey";;
    TM) channelCountry[${1}]="Turkmenistan";;
    TC) channelCountry[${1}]="the Turks And Caicos Islands";;
    TV) channelCountry[${1}]="Tuvalu";;
    UG) channelCountry[${1}]="Uganda";;
    UA) channelCountry[${1}]="Ukraine";;
    AE) channelCountry[${1}]="the United Arab Emirates";;
    GB) channelCountry[${1}]="the United Kingdom";;
    US) channelCountry[${1}]="the United States";;
    UM) channelCountry[${1}]="the U.S. Minor Outlying Islands";;
    UY) channelCountry[${1}]="Uruguay";;
    UZ) channelCountry[${1}]="Uzbekistan";;
    VU) channelCountry[${1}]="Vanuatu";;
    VA) channelCountry[${1}]="Vatican Holy See";;
    VE) channelCountry[${1}]="Venezuela";;
    VN) channelCountry[${1}]="Vietnam";;
    VG) channelCountry[${1}]="the Virgin Islands British";;
    VI) channelCountry[${1}]="the Virgin Islands U.S.";;
    WF) channelCountry[${1}]="Wallis And Futuna";;
    EH) channelCountry[${1}]="Western Sahara";;
    YE) channelCountry[${1}]="Yemen";;
    ZM) channelCountry[${1}]="Zambia";;
    ZW) channelCountry[${1}]="Zimbabwe";;
    null) channelCountry[${1}]="an unknown country";;
    *) channelCountry[${1}]="Unknown country code: ${2}";;
esac
}

function printUsernameWarning {
printOutput "2" "=========================================================================="
printOutput "2" "|       #     #     #     ######   #     #  ###  #     #   #####         |"
printOutput "2" "|       #  #  #    # #    #     #  ##    #   #   ##    #  #     #        |"
printOutput "2" "|       #  #  #   #   #   #     #  # #   #   #   # #   #  #              |"
printOutput "2" "|       #  #  #  #######  #   #    #   # #   #   #   # #  #   ###        |"
printOutput "2" "|       #  #  #  #     #  #    #   #    ##   #   #    ##  #     #        |"
printOutput "2" "|        ## ##   #     #  #     #  #     #  ###  #     #   #####         |"
printOutput "2" "=========================================================================="
printOutput "2" "| Using a username link is less reliable than using a channel ID link!   |"
printOutput "2" "|            Usernames may change, channel ID's will not!                |"
printOutput "2" "|                                                                        |"
printOutput "2" "| Please consider replacing the username link with the channel ID link:  |"
printOutput "2" "|     ${1}           |"
printOutput "2" "=========================================================================="
}

function getChannelInfo {
# Channel ID should be passed as ${1}
validateChannelId "${1}"
# Done using the Data API
callCurl "https://www.googleapis.com/youtube/v3/channels?part=snippet,statistics,brandingSettings&id=${1}&key=${ytApiKey}"
channelName[${1}]="$(jq -M -r ".items[].snippet.title" <<<"${curlOutput}")"
channelDesc[${1}]="$(jq -M -r ".items[].snippet.description" <<<"${curlOutput}")"
channelUrl[${1}]="https://www.youtube.com/$(jq -M -r ".items[].snippet.customUrl" <<<"${curlOutput}")"
channelSubs[${1}]="$(jq -M -r ".items[].statistics.subscriberCount" <<<"${curlOutput}")"
if [[ "${channelSubs[${1}]}" == "null" ]]; then
    channelSubs[${1}]="0"
elif [[ "${channelSubs[${1}]}" -ge "1000" ]]; then
    channelSubs[${1}]="$(printf "%'d" "${channelSubs[${1}]}")"
fi
channelVidCount[${1}]="$(jq -M -r ".items[].statistics.videoCount" <<<"${curlOutput}")"
if [[ "${channelVidCount[${1}]}" == "null" ]]; then
    channelVidCount[${1}]="0"
elif [[ "${channelVidCount[${1}]}" -ge "1000" ]]; then
    channelVidCount[${1}]="$(printf "%'d" "${channelVidCount[${1}]}")"
fi
channelViewCount[${1}]="$(jq -M -r ".items[].statistics.viewCount" <<<"${curlOutput}")"
if [[ "${channelViewCount[${1}]}" == "null" ]]; then
    channelViewCount[${1}]="0"
elif [[ "${channelViewCount[${1}]}" -ge "1000" ]]; then
    channelViewCount[${1}]="$(printf "%'d" "${channelViewCount[${1}]}")"
fi
channelDate[${1}]="$(jq -M -r ".items[].snippet.publishedAt" <<<"${curlOutput}")"
channelDate[${1}]="${channelDate[${1}]:0:10}"
channelCountry[${1}]="$(jq -M -r ".items[].snippet.country" <<<"${curlOutput}")"
getChannelCountry "${1}" "${channelCountry[${1}]}"
channelImg[${1}]="$(jq -M -r ".items | if type==\"array\" then .[] else . end | .snippet.thumbnails | to_entries | [last] | from_entries | keys[]" <<<"${curlOutput}")"
channelImg[${1}]="$(jq -M -r ".items | if type==\"array\" then .[] else . end | .snippet.thumbnails.${channelImg[${1}]}.url" <<<"${curlOutput}")"

if [[ -z "${channelJson}" ]]; then
    channelJson[${1}]="$(yt-dlp --retry-sleep 30 --cookies "${cookieFile}" --flat-playlist --no-warnings --playlist-items 0 -J "https://www.youtube.com/channel/${1}" 2>/dev/null)"
fi
channelBanner[${1}]="$(jq -M -r ".thumbnails[] | select ( .id == \"banner_uncropped\" ) .url" <<<"${channelJson}")"
# Built product should be:
# Description
# Channel link
# Subscriber count
# Video count
# View count
# Join date
# Country

channelStats[${1}]="${channelUrl[${1}]}${lineBreak}${channelSubs[${1}]} subscribers${lineBreak}${channelVidCount[${1}]} videos${lineBreak}${channelViewCount[${1}]} views${lineBreak}Joined $(date --date="${channelDate[${1}]}" "+%b. %d, %Y")${lineBreak}Based in ${channelCountry[${1}]}${lineBreak}Channel description and statistics last updated $(date)"

if [[ -z "${channelDesc[${1}]}" ]]; then
    channelDesc="${channelStats[${1}]}"
else
    channelDesc="${channelDesc[${1}]}${lineBreak}${channelStats[${1}]}"
fi
}

function randomSleep {
# ${1} is minumum seconds, ${2} is maximum
# If no min/max set, min=5 max=30
if [[ -z "${1}" ]]; then
    sleepTime="$(shuf -i 5-30 -n 1)"
else
    sleepTime="$(shuf -i ${1}-${2} -n 1)"
fi
printOutput "4" "Pausing for ${sleepTime} seconds before continuing"
sleep "${sleepTime}"
}

function refreshLibrary {
# Issue a "Scan Library" command
printOutput "3" "Issuing a 'Scan Library' command to Plex"
callCurl "${plexAdd}/library/sections/${libraryId[0]}/refresh?X-Plex-Token=${plexToken}"
}

function getMediaId {
# The YouTube ID of the video you want should be passed as ${1}
# Note that this is the *raw* YouTube ID, so it needs to be padded with _ when utilizing associate array elements
startTime="$(($(date +%s%N)/1000000))"
if [[ -z "${mediaIdArr[_${1}]}" ]]; then
    # printOutput "4" "Looking up Media ID: ${1}"
    # Already defined
    if [[ -e "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkeys" && -z "${mediaIdArr[_${1}]}" ]]; then
        while read -r z; do
            if [[ "${z#* }" == "${1}" ]]; then
                # printOutput "4" "Media ID previously found, using filed value"
                mediaIdArr[_${1}]="${z% *}"
                break
            fi
        done < "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkeys"
    fi
    if [[ -z "${mediaIdArr[_${1}]}" ]]; then
        if [[ -n "${1}" ]]; then
            unset showKeys
            # File system lookup
            if [[ -e "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/.show_ratingkey" ]]; then
                readarray -t showKeys < "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/.show_ratingkey"
                # Check the shows for a match
                for showId in "${showKeys[@]}"; do
                    unset seasonKeys
                    if [[ -e "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkey" ]]; then
                        readarray -t seasonKeys < "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkey"
                    else
                        callCurl "${plexAdd}/library/metadata/${showId}/children?X-Plex-Token=${plexToken}"
                        plexOutputToJson
                        while read -r z; do
                            if ! [[ "${z}" == "null" ]]; then
                                seasonKeys+=("${z}")
                            fi
                        done < <(jq -M -r ".MediaContainer.Directory | if type==\"array\" then .[] else . end | select ( .\"@title\" == \"Season ${vidYear[_${1}]}\" ) .\"@ratingKey\"" <<<"${curlOutput}")
                        if [[ "${seasonKeys[0]}" == "null" ]]; then
                            badExit "14" "No season key returned for ${channelName[_${1}]}/Season ${vidYear[_${1}]}"
                        fi
                    fi

                    for seasonId in "${seasonKeys[@]}"; do
                        callCurl "${plexAdd}/library/metadata/${seasonId}/children?X-Plex-Token=${plexToken}"
                        plexOutputToJson
                        while read -r plexitem; do
                            ytVidId="${plexitem%\]*}"
                            ytVidId="${ytVidId##*\[}"
                            if [[ "${ytVidId}" == "${1#ytid_}" ]]; then
                                mediaIdArr[_${1}]="${plexitem%% *}"
                                if ! [[ -e "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/.show_ratingkey" ]]; then
                                    echo "${showId}" > "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/.show_ratingkey"
                                fi
                                if ! [[ -e "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkey" ]]; then
                                    echo "${seasonId}" > "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkey"
                                fi
                                echo "${plexitem%% *} ${1#ytid_}" >> "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkeys"
                                # printOutput "4" "Match found: [YTID: ${1} | Show ID: ${showId} | Season ID: ${seasonId} | ratingKey ID: ${mediaIdArr[_${1}]}]"
                                break 3
                            fi
                        done < <(jq -M -r ".MediaContainer.Video | if type==\"array\" then .[] else . end | .\"@ratingKey\" + \" \" + .Media.Part.\"@file\"" <<<"${curlOutput}")
                    done
                done
            else
                callCurl "${plexAdd}/library/sections/${libraryId[0]}/all?X-Plex-Token=${plexToken}"
                plexOutputToJson
                allLibraryJson="${curlOutput}"
                # printOutput "4" "Attempting efficient search method"
                # Name match lookup
                readarray -t showKeys < <(jq -M -r ".MediaContainer.Directory | if type==\"array\" then .[] else . end | select ( .\"@title\" == \"${channelName[_${1}]}\" ) .\"@ratingKey\"" <<<"${allLibraryJson}")
                if [[ "${#showKeys[@]}" -eq "1" && "${showKeys[0]}" == "null" ]]; then
                    unset showKeys
                fi
                # First letter match lookup
                if [[ "${#showKeys[@]}" -eq "0" ]]; then
                    # printOutput "4" "No matches found, utilizing semi-efficient search method"
                    startsWith="${channelName[_${1}],}"
                    startsWith="${startsWith:0:1}"
                    readarray -t showKeys < <(jq -M -r ".MediaContainer.Directory | if type==\"array\" then .[] else . end | select ( ( .\"@title\" | ascii_downcase ) | startswith(\"${startsWith}\") ) .\"@ratingKey\"" <<<"${allLibraryJson}")
                    if [[ "${#showKeys[@]}" -eq "1" && "${showKeys[0]}" == "null" ]]; then
                        unset showKeys
                    else
                        # Check the shows for a match
                        for showId in "${showKeys[@]}"; do
                            unset seasonKeys
                            if [[ -e "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkey" ]]; then
                                readarray -t seasonKeys < "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkey"
                            else
                                callCurl "${plexAdd}/library/metadata/${showId}/children?X-Plex-Token=${plexToken}"
                                plexOutputToJson
                                while read -r z; do
                                    if ! [[ "${z}" == "null" ]]; then
                                        seasonKeys+=("${z}")
                                    fi
                                done < <(jq -M -r ".MediaContainer.Directory | if type==\"array\" then .[] else . end | select ( .\"@title\" == \"Season ${vidYear[_${1}]}\" ) .\"@ratingKey\"" <<<"${curlOutput}")
                                if [[ "${seasonKeys[0]}" == "null" ]]; then
                                    badExit "15" "No season key returned for ${channelName[_${1}]}/Season ${vidYear[_${1}]}"
                                fi
                            fi

                            for seasonId in "${seasonKeys[@]}"; do
                                while read -r plexitem; do
                                    ytVidId="${plexitem%\]*}"
                                    ytVidId="${ytVidId##*\[}"
                                    if [[ "${ytVidId}" == "${1#ytid_}" ]]; then
                                        mediaIdArr[_${1}]="${plexitem%% *}"
                                        if ! [[ -e "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/.show_ratingkey" ]]; then
                                            echo "${showId}" > "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/.show_ratingkey"
                                        fi
                                        if ! [[ -e "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkey" ]]; then
                                            echo "${seasonId}" > "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkey"
                                        fi
                                        echo "${plexitem%% *} ${1#ytid_}" >> "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkeys"
                                        # printOutput "4" "Match found: [YTID: ${1} | Show ID: ${showId} | Season ID: ${seasonId} | ratingKey ID: ${mediaIdArr[_${1}]}]"
                                        break 3
                                    fi
                                done < <(jq -M -r ".MediaContainer.Video | if type==\"array\" then .[] else . end | .\"@ratingKey\" + \" \" + .Media.Part.\"@file\"" <<<"${curlOutput}")
                            done
                        done
                    fi
                fi
                # Try an inefficient search
                if [[ -z "${mediaIdArr[_${1}]}" ]]; then
                    printOutput "4" "No matches found, utilizing inefficient search method"
                    callCurl "${plexAdd}/library/sections/${libraryId[0]}/all?X-Plex-Token=${plexToken}"
                    plexOutputToJson
                    readarray -t showKeys < <(jq -M -r ".MediaContainer.Directory | if type==\"array\" then .[] else . end | .\"@ratingKey\"" <<<"${allLibraryJson}")
                    if [[ "${#showKeys[@]}" -eq "1" && "${showKeys[0]}" == "null" ]]; then
                        unset showKeys
                    else
                        # Check the shows for a match
                        for showId in "${showKeys[@]}"; do
                            unset seasonKeys
                            if [[ -e "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkey" ]]; then
                                readarray -t seasonKeys < "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkey"
                            else
                                callCurl "${plexAdd}/library/metadata/${showId}/children?X-Plex-Token=${plexToken}"
                                plexOutputToJson
                                while read -r z; do
                                    if ! [[ "${z}" == "null" ]]; then
                                        seasonKeys+=("${z}")
                                    fi
                                done < <(jq -M -r ".MediaContainer.Directory | if type==\"array\" then .[] else . end | select ( .\"@title\" == \"Season ${vidYear[_${1}]}\" ) .\"@ratingKey\"" <<<"${curlOutput}")
                                if [[ "${seasonKeys[0]}" == "null" ]]; then
                                    badExit "16" "No season key returned for ${channelName[_${1}]}/Season ${vidYear[_${1}]}"
                                fi
                            fi

                            for seasonId in "${seasonKeys[@]}"; do
                                callCurl "${plexAdd}/library/metadata/${seasonId}/children?X-Plex-Token=${plexToken}"
                                plexOutputToJson
                                while read -r plexitem; do
                                    ytVidId="${plexitem%\]*}"
                                    ytVidId="${ytVidId##*\[}"
                                    if [[ "${ytVidId}" == "${1#ytid_}" ]]; then
                                        mediaIdArr[_${1}]="${plexitem%% *}"
                                        if ! [[ -e "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/.show_ratingkey" ]]; then
                                            echo "${showId}" > "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/.show_ratingkey"
                                        fi
                                        if ! [[ -e "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkey" ]]; then
                                            echo "${seasonId}" > "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkey"
                                        fi
                                        echo "${plexitem%% *} ${1#ytid_}" >> "${outputDir}/${channelName[_${1}]} [${channelId[_${1}]}]/Season ${vidYear[_${1}]}/.season_ratingkeys"
                                        # printOutput "4" "Match found: [YTID: ${1} | Show ID: ${showId} | Season ID: ${seasonId} | ratingKey ID: ${mediaIdArr[_${1}]}]"
                                        break 3
                                    fi
                                done < <(jq -M -r ".MediaContainer.Video | if type==\"array\" then .[] else . end | .\"@ratingKey\" + \" \" + .Media.Part.\"@file\"" <<<"${curlOutput}")
                            done
                        done
                    fi
                fi
            fi
            
            if [[ -z "${mediaIdArr[_${1}]}" ]]; then
                printOutput "1" "Unable to match media ID [${1}][${vidTitle[_${1}]}][Show IDs: ${showKeys[*]}][Season Keys: ${seasonKeys[*]}]"
            fi
        else
            printOutput "1" "No media ID provided for getMediaId function"
        fi
    fi
# else
    # printOutput "4" "Media ID already defined, skipping lookup"
fi
# printOutput "4" "Media ID lookup took $(timeDiff "${startTime}")"
}

function setPlexMetadata {
# ${1} should be an unpadded (no leading _) YT Video ID
validateVideoId "${1}"
getMediaId "${1}"
if [[ -n "${mediaIdArr[_${1}]}" ]]; then
    printOutput "3" "Media found in Plex -- Issuing API call to update channel metadata"
    encodedChannel="$(jq -rn --arg x "${channelName[_${1}]}" '$x|@uri')"
    if [[ -n "${channelDesc[${channelId[_${1}]}]}" ]]; then
        encodedDesc="$(jq -rn --arg x "${channelDesc[${channelId[_${1}]}]}" '$x|@uri')"
        encodedDesc="&summary.value=${encodedDesc}"
    else
        unset encodedDesc
    fi

    # Issue the PUT call
    callCurlPut "${plexAdd}/library/sections/${libraryId[0]}/all?type=2&id=${showId}&title.value=${encodedChannel}&titleSort.value=${encodedChannel}${encodedDesc}&studio.value=YouTube&originallyAvailableAt.value=${channelDate}&summary.locked=1&title.locked=1&titleSort.locked=1&originallyAvailableAt.locked=1&studio.locked=1&X-Plex-Token=${plexToken}"
    printOutput "3" "Metadata update successfully called"
else
    printOutput "1" "No media ID returned for [${1}], perhaps Plex has not yet picked up the file?"
fi
}

function getCollectionOrder {
# printOutput "4" "Obtaining order of items in collection from Plex"
unset plOrderByNum
callCurl "${plexAdd}/library/collections/${collectionKey}/children?X-Plex-Token=${plexToken}"
plexOutputToJson
while read -r ii; do
    if [[ -z "${ii}" || "${ii}" == "null" ]]; then
        printOutput "2" "No items in collection"
        break
    fi
    ii="${ii%\]\.mp4}"
    ii="${ii##*\[}"
    plOrderByNum[$(( ${#plOrderByNum[@]} + 1))]="${ii}"
done < <(jq -M -r ".MediaContainer.Video | if type==\"array\" then .[] else . end | .Media.Part.\"@file\"" <<<"${curlOutput}")
readarray -t plIndexSorted < <(for i in "${!plOrderByNum[@]}"; do echo "${i}"; done | sort -n)
for ii in "${plIndexSorted[@]}"; do
    getMediaId "${plOrderByNum[${ii}]}"
done
}

function collectionVerifyAdd {
printOutput "3" "Checking for items to be added to collection"
for ii in "${ytIndexSorted[@]}"; do
    needNewOrder="0"
    inPlaylist="0"
    for iii in "${plIndexSorted[@]}"; do
        if [[ "${ytOrderByNum[${ii}]}" == "${plOrderByNum[${iii}]}" ]]; then
            inPlaylist="1"
            break
        fi
    done
    if [[ "${inPlaylist}" -eq "0" ]]; then
        if [[ -n "${mediaIdArr[_${ytOrderByNum[${ii}]}]}" ]]; then
            needNewOrder="1"
            callCurlPut "${plexAdd}/library/collections/${collectionKey}/items?uri=server%3A%2F%2F${plexMachineIdentifier}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${mediaIdArr[_${ytOrderByNum[${ii}]}]}&X-Plex-Token=${plexToken}"
            printOutput "3" "Added [${ytOrderByNum[${ii}]}][${vidTitle[_${ytOrderByNum[${ii}]}]}] to collection [${playlistTitle}]"
        fi
    fi
if [[ "${needNewOrder}" -eq "1" ]]; then
    getCollectionOrder
fi
done
}

function collectionVerifyDelete {
printOutput "3" "Checking for items to be removed to collection"
for ii in "${plIndexSorted[@]}"; do
    needNewOrder="0"
    inPlaylist="1"
    for iii in "${ytIndexSorted[@]}"; do
        if [[ "${ytOrderByNum[${iii}]}" == "${plOrderByNum[${ii}]}" ]]; then
            inPlaylist="0"
            break
        fi
    done
    if [[ "${inPlaylist}" -eq "1" ]]; then
        needNewOrder="1"
        callCurlDelete "${plexAdd}/library/collections/${collectionKey}/children/${mediaIdArr[_${plOrderByNum[${ii}]}]}?excludeAllLeaves=1&X-Plex-Token=${plexToken}"
        printOutput "3" "Removed [${plOrderByNum[${ii}]}][${vidTitle[_${plOrderByNum[${ii}]}]}] from collection [${playlistTitle}]"
    fi
done
if [[ "${needNewOrder}" -eq "1" ]]; then
    getCollectionOrder
fi
}

function collectionVerifySort {
printOutput "3" "Checking for items to be re-ordered in collection"
for ii in "${ytIndexSorted[@]}"; do
    if [[ "${ii}" -eq "1" ]]; then
        if ! [[ "${ytOrderByNum[1]}" == "${plOrderByNum[1]}" ]]; then
            callCurlPut "${plexAdd}/library/collections/${collectionKey}/items/${mediaIdArr[_${ytOrderByNum[${ii}]}]}/move?X-Plex-Token=${plexToken}"
        fi
    elif [[ "${ii}" -ge "2" ]]; then
        for iii in "${!plOrderByNum[@]}"; do
            if [[ "${plOrderByNum[${iii}]}" == "${ytOrderByNum[${ii}]}" ]]; then
                break
                # Our position is "${iii}"
            fi
        done
        if ! [[ "${ytOrderByNum[$(( ii - 1 ))]}" == "${plOrderByNum[$(( iii - 1 ))]}" ]]; then
            callCurlPut "${plexAdd}/library/collections/${collectionKey}/items/${mediaIdArr[_${ytOrderByNum[${ii}]}]}/move?after=${mediaIdArr[_${ytOrderByNum[$(( ii - 1 ))]}]}&X-Plex-Token=${plexToken}"
        fi
    else
        badExit "17" "Impossible condition"
    fi
done
}

function getPlaylistOrder {
# printOutput "4" "Obtaining order of items in playlist"
unset plOrderByNum plItemId
declare -gA plItemId
callCurl "${plexAdd}/playlists/${playlistKey}/items?X-Plex-Token=${plexToken}"
plexOutputToJson
while read -r ii; do
    if [[ -z "${ii}" ]]; then
        printOutput "2" "No items in playlist"
        break
    fi
    id="${ii%\]\.mp4}"
    id="${id##*\[}"
    plOrderByNum[$(( ${#plOrderByNum[@]} + 1))]="${id}"
    plItemId[_${id}]="${ii%% *}"
done < <(jq -M -r ".MediaContainer.Video | if type==\"array\" then .[] else . end | .\"@playlistItemID\" + \" \" + .Media.Part.\"@file\"" <<<"${curlOutput}")
readarray -t plIndexSorted < <(for i in "${!plOrderByNum[@]}"; do echo "${i}"; done | sort -n)
for ii in "${!plOrderByNum[@]}"; do
    getMediaId "${plOrderByNum[${ii}]}"
done
}

function playlistVerifyAdd {
printOutput "5" "Items in YouTube playlist: ${#ytOrderByNum[@]}"
for ii in "${ytIndexSorted[@]}"; do
    printOutput "5" "[${ii}] ${ytOrderByNum[${ii}]}"
done
printOutput "5" "Items in Plex playlist: ${#plIndexSorted[@]}"
for ii in "${plIndexSorted[@]}"; do
    printOutput "5" "[${ii}] ${plOrderByNum[${ii}]}"
done
printOutput "3" "Checking for items to be added to playlist"
for ii in "${ytIndexSorted[@]}"; do
    needNewOrder="0"
    inPlaylist="0"
    for iii in "${plIndexSorted[@]}"; do
        if [[ "${ytOrderByNum[${ii}]}" == "${plOrderByNum[${iii}]}" ]]; then
            inPlaylist="1"
            break
        fi
    done
    if [[ "${inPlaylist}" -eq "0" ]]; then
        needNewOrder="1"
        callCurlPut "${plexAdd}/playlists/${playlistKey}/items?uri=server%3A%2F%2F${plexMachineIdentifier}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${mediaIdArr[_${ytOrderByNum[${ii}]}]}&X-Plex-Token=${plexToken}"
        printOutput "3" "Added [${ytOrderByNum[${ii}]}][${vidTitle[_${ytOrderByNum[${ii}]}]}] to playlist [${playlistTitle}]"
    fi
    if [[ "${needNewOrder}" -eq "1" ]]; then
        getPlaylistOrder
    fi
done
}

function playlistVerifyDelete {
printOutput "3" "Checking for items to be removed to playlist"
for ii in "${plIndexSorted[@]}"; do
    needNewOrder="0"
    inPlaylist="1"
    for iii in "${ytIndexSorted[@]}"; do
        if [[ "${ytOrderByNum[${iii}]}" == "${plOrderByNum[${ii}]}" ]]; then
            inPlaylist="0"
            break
        fi
    done
    if [[ "${inPlaylist}" -eq "1" ]]; then
        needNewOrder="1"
        callCurlDelete "${plexAdd}/playlists/${playlistKey}/items/${plItemId[${plOrderByNum[${ii}]}]}?X-Plex-Token=${plexToken}"
        printOutput "3" "Removed [${plOrderByNum[${ii}]}][${vidTitle[_${plOrderByNum[${ii}]}]}] from playlist [${playlistTitle}]"
    fi
done
if [[ "${needNewOrder}" -eq "1" ]]; then
    getPlaylistOrder
fi
}

function playlistVerifySort {
printOutput "3" "Checking for items to be re-ordered in playlist"
for ii in "${ytIndexSorted[@]}"; do
    if [[ "${ii}" -eq "1" ]]; then
        if ! [[ "${ytOrderByNum[1]}" == "${plOrderByNum[1]}" ]]; then
            callCurlPut "${plexAdd}/playlists/${playlistKey}/items/${plItemId[_${ytOrderByNum[${ii}]}]}/move?X-Plex-Token=${plexToken}"
        fi
    elif [[ "${ii}" -ge "2" ]]; then
        for iii in "${!plOrderByNum[@]}"; do
            if [[ "${plOrderByNum[${iii}]}" == "${ytOrderByNum[${ii}]}" ]]; then
                break
                # Our position is "${iii}"
            fi
        done
        if ! [[ "${ytOrderByNum[$(( ii - 1 ))]}" == "${plOrderByNum[$(( iii - 1 ))]}" ]]; then
            callCurlPut "${plexAdd}/playlists/${playlistKey}/items/${plItemId[_${ytOrderByNum[${ii}]}]}/move?after=${plItemId[_${ytOrderByNum[$(( ii - 1 ))]}]}&X-Plex-Token=${plexToken}"
        fi
    else
        badExit "18" "Impossible condition"
    fi
done
}

function validateVideoId {
if ! [[ "${1}" =~ ^[0-9A-Za-z_-]{10}[048AEIMQUYcgkosw]$ ]]; then
    badExit "19" "Video ID [${1}] failed to validate"
fi
}

function validateChannelId {
if ! [[ "${1}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
    badExit "20" "Channel ID [${1}] failed to validate"
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
        echo "-h  --help           Displays this help message"
        echo ""
        echo "-u  --update         Self update to the most recent version"
        echo ""
        echo "-m  --metadata       Forces update of metadata for all channels"
        echo ""
        echo "-mo --metadata-only  Forces update of metadata for all channels,"
        echo "                     and then exits (Doesn't check for new videos)"
        echo ""
        echo "-do --download-only  Downloads videos only, without updating any"
        echo "                     channel metadata or processing any playlists"
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
                badExit "21" "Update downloaded, but unable to \`chmod +x\`"
            fi
        else
            badExit "22" "Unable to download Update"
        fi
    ;;
    "-m"|"--metadata"|"-mo"|"--metadata-only")
        forceMetadataUpdate="true"
    ;;
    "-do"|"--download-only")
        downloadOnly="true"
    ;;
esac

#############################
##   Initiate .env file    ##
#############################
if [[ -e "${realPath%/*}/${scriptName%.bash}.env" ]]; then
    source "${realPath%/*}/${scriptName%.bash}.env"
else
    badExit "23" "Error: \"${realPath%/*}/${scriptName%.bash}.env\" does not appear to exist"
fi
varFail="0"
# Standard checks
if ! [[ "${updateCheck,,}" =~ ^(yes|no|true|false)$ ]]; then
    echo "Option to check for updates not valid. Assuming no."
    updateCheck="No"
fi
if ! [[ "${outputVerbosity}" =~ ^[1-5]$ ]]; then
    echo "Invalid output verbosity defined. Assuming level 1 (Errors only)"
    outputVerbosity="1"
fi

# Config specific checks

# Quit if failures
if [[ "${varFail}" -eq "1" ]]; then
    badExit "24" "Please fix above errors"
fi

#############################
##       Update check      ##
#############################
if [[ "${updateCheck,,}" =~ ^(yes|true)$ ]]; then
    newest="$(curl -skL "${updateURL}" | md5sum | awk '{print $1}')"
    current="$(md5sum "${0}" | awk '{print $1}')"
    if ! [[ "${newest}" == "${current}" ]]; then
        printOutput "0" "A newer version is available"
    else
        printOutput "4" "No new updates available"
    fi
fi

#############################
##         Payload         ##
#############################
# Verify that we can connect to Plex
printOutput "3" "############# Verifying Plex connectivity #############"
getContainerIp "${plexIp}"
plexAdd="${plexScheme}://${containerIp}:${plexPort}"
callCurl "${plexAdd}/servers?X-Plex-Token=${plexToken}"
plexOutputToJson
if [[ "$(jq -M -r ".MediaContainer.\"@size\"" <<<"${curlOutput}")" -eq "1" ]]; then
    plexServerName="$(jq -M -r ".MediaContainer.Server.\"@name\"" <<<"${curlOutput}")"
    plexVersion="$(jq -M -r ".MediaContainer.Server.\"@version\"" <<<"${curlOutput}")"
    plexMachineIdentifier="$(jq -M -r ".MediaContainer.Server.\"@machineIdentifier\"" <<<"${curlOutput}")"
elif [[ "$(jq -M -r ".MediaContainer.\"@size\"" <<<"${curlOutput}")" -ge "2" ]]; then
    if [[ -z "${plexServerName}" ]]; then
        printOutput "1" "[$(jq -M -r ".MediaContainer.\"@size\"" <<<"${curlOutput}")] servers identified:"
        badExit "25" "Please identify which server to interface with in the config"
    fi
    # This line is a redundant validator
    plexServerName="$(jq -M -r ".MediaContainer.Server[] | select ( .\"@name\" == \"${plexServerName}\") .\"@name\"" <<<"${curlOutput}")"
    plexVersion="$(jq -M -r ".MediaContainer.Server[] | select ( .\"@name\" == \"${plexServerName}\") .\"@version\"" <<<"${curlOutput}")"
    plexMachineIdentifier="$(jq -M -r ".MediaContainer.Server[] | select ( .\"@name\" == \"${plexServerName}\") .\"@machineIdentifier\"" <<<"${curlOutput}")"
fi

if [[ -n "${plexVersion}" ]]; then
    printOutput "3" "Verified Plex connectivity"
    printOutput "4" "PMS Server: ${plexServerName}"
    printOutput "4" "PMS Version: ${plexVersion}"
else
    badExit "26" "Unable to verify Plex connectivity"
fi
if [[ -n "${plexMachineIdentifier}" ]]; then
    printOutput "4" "PMS Machine Identifier: ${plexMachineIdentifier}"
else
    badExit "27" "Unable to obtain Plex Machine Identifier"
fi

callCurl "${plexAdd}/library/sections/?X-Plex-Token=${plexToken}"
plexOutputToJson
curlOutput="$(jq -M -r ".MediaContainer.Directory[] | select(.\"@title\" == \"${libraryName}\")" <<<"${curlOutput}")"
readarray -t libraryId < <(jq -M -r ".\"@key\"" <<<"${curlOutput}")
if [[ "${#libraryId[@]}" -ne "1" ]]; then
    badExit "28" "Invalid number of library ID matches: ${#libraryId[@]}"
elif [[ "${#libraryId[@]}" -eq "1" ]]; then
    printOutput "4" "Found library ID: ${libraryId[0]}"
else
    badExit "29" "Impossible condition"
fi

declare -A knownFiles vidIds ytIdClean chanIds plIds vidTitle vidUpload vidYear vidEpoch channelUrl channelName channelId setChannelMetadata mediaIdArr vidTitleClean watchStatusArray channelSubs channelVidCount channelViewCount channelDate channelCountry channelImg channelJson channelBanner channelDesc channelStats epCode

if [[ "${forceMetadataUpdate}" == "true" ]]; then
    printOutput "3" "################ Forcing metadata update ##############"

    callCurl "${plexAdd}/library/sections/${libraryId[0]}/all?X-Plex-Token=${plexToken}"
    plexOutputToJson
    readarray -t showKeys < <(jq -M -r ".MediaContainer.Directory | if type==\"array\" then .[] else . end | .\"@ratingKey\"" <<<"${curlOutput}")
    printOutput "4" "Found [${#showKeys[@]}] show keys: ${showKeys[*]}"

    for showId in "${showKeys[@]}"; do
        unset seasonKeys
        printOutput "4" "Processing show ID ${showId}"
        callCurl "${plexAdd}/library/metadata/${showId}/children?X-Plex-Token=${plexToken}"
        plexOutputToJson
        while read -r i; do
            if ! [[ "${i}" == "null" ]]; then
                seasonKeys+=("${i}")
            fi
        done < <(jq -M -r ".MediaContainer.Directory | if type==\"array\" then .[] else . end | .\"@ratingKey\"" <<<"${curlOutput}")
        # We really just need to look at the first episode for the first season to get the Channel ID
        callCurl "${plexAdd}/library/metadata/${seasonKeys[0]}/children?X-Plex-Token=${plexToken}"
        plexOutputToJson
        fileStr="$(jq -M -r ".MediaContainer.Video | if type==\"array\" then .[] else . end | .Media.Part.\"@file\"" <<<"${curlOutput}")"
        ytId="${fileStr%\]\.mp4}"
        ytId="_${ytId##*\[}"
        chanId="${fileStr%]/*/*}"
        chanId="${chanId##*[}"
        channelId[${ytId}]="${chanId}"
        getChannelInfo "${channelId[${ytId}]}"

        printOutput "4" "Found Channel: ${channelName[${channelId[${ytId}]}]} [${channelId[${ytId}]}]"

        # Get our background image
        callCurlDownload "${channelImg[${channelId[${ytId}]}]}" "${outputDir}/${channelName[${channelId[${ytId}]}]} [${channelId[${ytId}]}]/show.jpg"
        if [[ -n "${channelBanner[${channelId[${ytId}]}]}" ]]; then
            callCurlDownload "${channelBanner[${channelId[${ytId}]}]}" "${outputDir}/${channelName[${channelId[${ytId}]}]} [${channelId[${ytId}]}]/background.jpg"
        fi

        # Encode our description
        encodedChannel="$(jq -rn --arg x "${channelName[${channelId[${ytId}]}]}" '$x|@uri')"
        if [[ -n "${channelDesc}" ]]; then
            encodedDesc="$(jq -rn --arg x "${channelDesc}" '$x|@uri')"
            encodedDesc="&summary.value=${encodedDesc}"
        else
            unset uncodedDesc
        fi

        # Set the metadata
        callCurlPut "${plexAdd}/library/sections/${libraryId[0]}/all?type=2&id=${showId}&title.value=${encodedChannel}&titleSort.value=${encodedChannel}${encodedDesc}&studio.value=YouTube&originallyAvailableAt.value=${channelDate}&summary.locked=1&title.locked=1&titleSort.locked=1&originallyAvailableAt.locked=1&studio.locked=1&X-Plex-Token=${plexToken}"
        printOutput "3" "Metadata for '${channelName[${channelId[${ytId}]}]}' [${channelId[${ytId}]}] successfully updated"
    done

    # TODO: Update metadata for collections and playlists

    if [[ "${1,,}" == "-mo" || "${1,,}" == "--metadata-only" ]]; then
        cleanExit
    fi
fi

# Start by getting a list of known files
while read -r i; do
    ytId="${i%\]\.mp4}"
    ytId="${ytId##*\[}"
    knownFiles[_${ytId}]="${i}"
    ii="${i%/*}"
    ii="${ii##*/Season }"
    vidYear[_${ytId}]="${ii}"
    ii="${i%\]/*/*}"
    ii="${ii##*\[}"
    channelId[_${ytId}]="${ii}"
    ii="${i% \[${channelId[_${ytId}]}\]/*/*}"
    ii="${ii##*/}"
    channelName[_${ytId}]="${ii}"
    # vidTitle[_${ytId}]="$(jq -M -r ".title" "${i%/*}/.${ytId}.json")"
    # printOutput "4" "[${knownFiles[_${ytId}]}][${vidYear[_${ytId}]}][${channelId[_${ytId}]}][${channelName[_${ytId}]}]"
    # sleep 40
done < <(find "${outputDir}" -not -path "${stagingDir}/*" -type f -name "*.mp4")
printOutput "4" "Files in library: ${#knownFiles[@]}"

if [[ "${#inputArr[@]}" -eq "0" ]]; then
    printOutput "3" "No items to process"
    cleanExit
fi

printOutput "3" "################ Processing input items ###############"
for i in "${inputArr[@]}"; do
    printOutput "3" "Processing: ${i}"
    unset itemType ytId channelJsonStr
    iOrig="${i}"
    i="${i#http:\/\/}"
    i="${i#https:\/\/}"
    i="${i#m\.}"
    i="${i#www\.}"
    if [[ "${i:0:8}" == "youtu.be" ]]; then
        # This can only be a video ID
        itemType="video"
        ytId="${i:9:11}"
    elif [[ "${i:0:8}" == "youtube." ]]; then
        # This can be a video ID, a channel ID, a channel name, or a playlist
        if [[ "${i:12:1}" == "@" ]]; then
            # It's a username
            ytId="${i:13}"
            ytId="${ytId%\&*}"
            ytId="${ytId%\?*}"
            ytId="${ytId%\/*}"
            # Get channel ID from username
            channelJsonStr="$(yt-dlp --cookies "${cookieFile}" --retry-sleep 30 --flat-playlist --no-warnings --playlist-items 0 -J "https://www.youtube.com/@${ytId}" 2>/dev/null)"
            # Throttle after a yt-dlp call, to hopefully prevent throttling from YouTube
            #randomSleep "3" "10"
            itemType="channel"
            ytId="$(jq -M -r ".channel_id" <<<"${channelJsonStr}")"
            printUsernameWarning "https://www.youtube.com/channel/${ytId}"
        elif [[ "${i:12:8}" == "watch?v=" ]]; then
            # It's a video ID
            itemType="video"
            ytId="${i:20:11}"
        elif [[ "${i:12:7}" == "channel" ]]; then
            # It's a channel ID
            itemType="channel"
            ytId="${i:20:24}"
        elif [[ "${i:12:8}" == "playlist" ]]; then
            # It's a playlist
            itemType="playlist"
            if [[ "${i:26:2}" == "WL" ]]; then
                # Watch later
                ytId="${i:26:2}"
            elif [[ "${i:26:2}" == "LL" ]]; then
                # Liked videos
                ytId="${i:26:2}"
            elif [[ "${i:26:2}" == "PL" ]]; then
                # Public playlist?
                ytId="${i:26:34}"
            fi
        fi
    else
        printOutput "1" "Unable to parse input [${i}] -- skipping"
        continue
    fi
    if [[ "${itemType}" == "video" ]]; then
        if [[ "${ytId}" =~ ^[0-9A-Za-z_-]{10}[048AEIMQUYcgkosw]$ ]]; then
            if [[ -z "${knownFiles[_${ytId}]}" ]]; then
                if [[ -z "${vidIds[_${ytId}]}" ]]; then
                    vidIds[_${ytId}]="${iOrig}"
                    printOutput "3" "Added video ID [${ytId}] to download queue"
                else
                    printOutput "4" "Video ID [${ytId}] already in queue from source [${vidIds[_${ytId}]}]"
                    continue
                fi
            else
                printOutput "4" "Video ID [${ytId}] already on disk, skipping"
            fi
        else
            printOutput "1" "INVALID video ID [${ytId}], skipping"
            continue
        fi
    elif [[ "${itemType}" == "channel" ]]; then
        if [[ "${ytId}" =~ ^[0-9A-Za-z_-]{23}[AQgw]$ ]]; then
            if [[ -z "${chanIds[_${ytId}]}" ]]; then
                printOutput "4" "Adding videos from channel ID [${ytId}] to download queue"
                chanIds[_${ytId}]="${iOrig}"
                while read -r chVids; do
                    if [[ -z "${knownFiles[_${chVids}]}" ]]; then
                        if [[ -z "${vidIds[_${chVids}]}" ]]; then
                            vidIds[_${chVids}]="${iOrig}"
                            printOutput "4" "Added video ID [${chVids}] to download queue"
                        else
                            printOutput "3" "Video ID [${chVids}] already in queue from source [${vidIds[_${chVids}]}]"
                            continue
                        fi
                    else
                        printOutput "4" "Video ID [${chVids}] already on disk, skipping"
                    fi
                done < <(yt-dlp --cookies "${cookieFile}" --retry-sleep 30 --no-warnings --flat-playlist --print "%(id)s" "https://www.youtube.com/channel/${ytId}")
                # Throttle after a yt-dlp call, to hopefully prevent throttling from YouTube
                #randomSleep "3" "10"
            else
                printOutput "1" "Channel ID [${ytId}] already in queue from source [${chanIds[_${ytId}]}]"
                continue
            fi
        else
            printOutput "1" "INVALID channel ID [${ytId}], skipping"
            continue
        fi
    elif [[ "${itemType}" == "playlist" ]]; then
        if [[ "${ytId}" =~ ^(WL$|LL$|PL[0-9A-Za-z_-]+$) ]]; then
            if [[ -z "${plIds[${ytId}]}" ]]; then
                plIds[${ytId}]="${iOrig}"
                while read -r plVids; do
                    if [[ -z "${knownFiles[_${plVids}]}" ]]; then
                        if [[ -z "${vidIds[_${plVids}]}" ]]; then
                            vidIds[_${plVids}]="${iOrig}"
                            printOutput "4" "Added video ID [${plVids}] to download queue"
                        else
                            printOutput "3" "Video ID [${plVids}] already in queue from source [${vidIds[_${plVids}]}]"
                            continue
                        fi
                    else
                        printOutput "4" "Video ID [${plVids}] already on disk, skipping"
                    fi
                done < <(yt-dlp --cookies "${cookieFile}" --retry-sleep 30 --no-warnings --flat-playlist --print "%(id)s" "https://www.youtube.com/playlist?list=${ytId}")
                # Throttle after a yt-dlp call, to hopefully prevent throttling from YouTube
                #randomSleep "3" "10"
            else
                printOutput "1" "Playlist ID [${ytId}] already in queue from source [${plIds[${ytId}]}]"
                continue
            fi
        else
            printOutput "1" "INVALID playlist ID [${ytId}], skipping"
            continue
        fi
    fi
done

# Set up our staging area, if it hasn't been already
if ! [[ -d "${stagingDir}" ]]; then
    if ! mkdir -p "${stagingDir}"; then
        badExit "30" "Unable to create staging area"
    fi
fi

if [[ "${#vidIds[@]}" -ge "1" ]]; then
    printOutput "3" "############## Processing download queue ##############"
    count="1"
    for ytId in "${!vidIds[@]}"; do
        ytIdClean[${ytId}]="${ytId#_}"
        printOutput "3" "Processing video ID [${ytIdClean[${ytId}]}] [Item ${count} of ${#vidIds[@]}]"
        # Grab the file to the staging directory
        startTime="$(($(date +%s%N)/1000000))"
        yt-dlp --cookies "${cookieFile}" --retry-sleep 30 --match-filter !is_live --merge-output-format mp4 --restrict-filenames --write-thumbnail --convert-thumbnails jpg --write-info-json --embed-subs --embed-metadata --embed-chapters --sponsorblock-mark all -o "${stagingDir}/${ytIdClean[${ytId}]}.mp4" "https://www.youtube.com/watch?v=${ytIdClean[${ytId}]}" > /dev/null 2>&1
        if ! [[ -e "${stagingDir}/${ytIdClean[${ytId}]}.mp4" ]]; then
            printOutput "1" "Download failed (Took $(timeDiff "${startTime}"))"
            # Throttle after a yt-dlp call, to hopefully prevent throttling from YouTube
            #randomSleep "3" "10"
            printOutput "3" "Attempting workaround download via extension preference"
            startTime="$(($(date +%s%N)/1000000))"
            ytDlpOutput="$(yt-dlp --cookies "${cookieFile}" --retry-sleep 30 --match-filter !is_live --merge-output-format mp4 --restrict-filenames --write-thumbnail --convert-thumbnails jpg --write-info-json --embed-subs --embed-metadata --embed-chapters --sponsorblock-mark all -S ext -U -v -o "${stagingDir}/${ytIdClean[${ytId}]}.mp4" "https://www.youtube.com/watch?v=${ytIdClean[${ytId}]}" 2>&1)"
            if ! [[ -e "${stagingDir}/${ytIdClean[${ytId}]}.mp4" ]]; then
                printOutput "1" "Download failed (Took $(timeDiff "${startTime}"))"
                printOutput "4" "##### Begin failed yt-dlp output #####"
                printOutput "4" "######################################"
                echo "${ytDlpOutput}"
                unset ytDlpOutput
                printOutput "4" "######################################"
                printOutput "4" "#####  End failed yt-dlp output  #####"
                printOutput "1" "Unable to grab \"https://www.youtube.com/watch?v=${ytIdClean[${ytId}]}\" from source \"${vidIds[${ytId}]}\""
                (( count++ ))
                continue
            elif [[ -e "${stagingDir}/${ytIdClean[${ytId}]}.mp4" ]]; then
                moveArray+=("${ytId}")
            else
                badExit "31" "Impossible condition"
            fi
        elif [[ -e "${stagingDir}/${ytIdClean[${ytId}]}.mp4" ]]; then
            moveArray+=("${ytId}")
        else
            badExit "32" "Impossible condition"
        fi

        # Make sure we have a JSON file to read
        if ! [[ -e "${stagingDir}/${ytIdClean[${ytId}]}.info.json" ]]; then
            printOutput "1" "JSON file not found, unable to continue for [${ytIdClean[${ytId}]}]"
            (( count++ ))
            continue
        fi

        # Get the video information
        # Video title
        vidTitle[${ytId}]="$(jq -M -r ".title" "${stagingDir}/${ytIdClean[${ytId}]}.info.json")"
        if [[ -z "${vidTitle[${ytId}]}" || "${vidTitle[${ytId}]}" == "null" ]]; then
            printOutput "1" "Unable to determine title for [${ytIdClean[${ytId}]}] -- Skipping"
            (( count++ ))
            continue
        fi

        # Video upload date
        vidUpload[${ytId}]="$(jq -M -r ".upload_date" "${stagingDir}/${ytIdClean[${ytId}]}.info.json")"
        if [[ -z "${vidUpload[${ytId}]}" || "${vidUpload[${ytId}]}" == "null" ]]; then
            printOutput "1" "Unable to determine upload date for [${ytIdClean[${ytId}]}] -- Skipping"
            (( count++ ))
            continue
        fi
        vidYear[${ytId}]="${vidUpload[${ytId}]:0:4}"

        # Video upload epoch timestamp
        # This is not obtained by the yt-dlp payload, so we need to use the Google API to get it
        callCurl "https://www.googleapis.com/youtube/v3/videos?part=snippet&id=${ytIdClean[${ytId}]}&key=${ytApiKey}"
        vidEpoch[${ytId}]="$(jq -M -r ".items[].snippet.publishedAt" <<<"${curlOutput}")"
        if [[ -z "${vidEpoch[${ytId}]}" ]]; then
            # This should really only ever hit if the video is private
            # Scrape it from the web if the video is private since we can't get it from the API (without oauth)
            # I am ashamed of the following 3 lines, but unwilling to deal with API oauth at this time
            vidEpoch[${ytId}]="$(curl -b "${cookieFile}" -skL "https://www.youtube.com/watch?v=${ytIdClean[${ytId}]}" | grep -E -o "<meta itemprop=\"datePublished\" content=\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}\">")"
            vidEpoch[${ytId}]="${vidEpoch[${ytId}]%\">}"
            vidEpoch[${ytId}]="${vidEpoch[${ytId}]##*\"}"
        fi
        vidEpoch[${ytId}]="$(date --date="${vidEpoch[${ytId}]}" "+%s")"
        if [[ -z "${vidEpoch[${ytId}]}" ]]; then
            printOutput "1" "Unable to determine upload time for [${ytIdClean[${ytId}]}|${vidTitle[${ytId}]}] -- Skipping"
            (( count++ ))
            continue
        fi

        # Channel name
        channelName[${ytId}]="$(jq -M -r ".channel" "${stagingDir}/${ytIdClean[${ytId}]}.info.json")"
        if [[ "${channelName[${ytIdClean[${ytId}]}]}" == "null" ]]; then
            channelName[${ytId}]="$(jq -M -r ".uploader_id" "${stagingDir}/${ytIdClean[${ytId}]}.info.json")"
        fi
        if [[ -z "${channelName[${ytId}]}" || "${channelName[${ytId}]}" == "null" ]]; then
            channelName[${ytId}]="$(yt-dlp --print "%(channel)s" "https://www.youtube.com/watch?v=${ytIdClean[${ytId}]}")"
        fi
        if [[ -z "${channelName[${ytId}]}" || "${channelName[${ytId}]}" == "null" ]]; then
            printOutput "1" "Unable to determine channel name for [${ytIdClean[${ytId}]}|${vidTitle[${ytId}]}] -- Skipping"
            (( count++ ))
            continue
        fi

        # Channel ID
        channelId[${ytId}]="$(jq -M -r ".channel_id" "${stagingDir}/${ytIdClean[${ytId}]}.info.json")"
        if [[ "${channelId[${ytId}]}" == "null" ]]; then
            channelId[${ytId}]="$(jq -M -r ".uploader_id" "${stagingDir}/${ytIdClean[${ytId}]}.info.json")"
        fi
        if [[ -z "${channelId[${ytId}]}" || "${channelId[${ytId}]}" == "null" ]]; then
            channelId[${ytId}]="$(yt-dlp --print "%(channel_id)s" "https://www.youtube.com/watch?v=${ytIdClean[${ytId}]}")"
        fi
        if [[ -z "${channelId[${ytId}]}" || "${channelId[${ytId}]}" == "null" ]]; then
            printOutput "1" "Unable to determine channel name for [${ytIdClean[${ytId}]}|${vidTitle[${ytId}]}] -- Skipping"
            (( count++ ))
            continue
        fi

        # Does our parent directory exist?
        if ! [[ -d "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]" ]]; then
            # No. So let's make it, and get the show poster.
            setChannelMetadata[${channelId[${ytId}]}]="${ytIdClean[${ytId}]}"
            mkdir -p "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]"
            printOutput "4" "Creating directory for new channel (${channelName[${ytId}]} [${channelId[${ytId}]}])"

            # Get the channel information
            getChannelInfo "${channelId[${ytId}]}"

            # Get our background image
            callCurlDownload "${channelImg[${channelId[${ytId}]}]}" "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/show.jpg" "https://www.youtube.com/channel/${channelId[${ytId}]}"
            if [[ -n "${channelBanner[${channelId[${ytId}]}]}" ]]; then
                callCurlDownload "${channelBanner[${channelId[${ytId}]}]}" "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/background.jpg"
            fi
        fi

        # Does our season directory exist?
        if ! [[ -d "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}" ]]; then
            # Create the new directory
            mkdir -p "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}"
            # Keep track of new directories we have created, as they will only have videos from this run
            newDirs+=("${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}")
            # Create a season thumbnail
            # Get the height of the show image
            posterHeight="$(identify -format "%h" "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/show.jpg")"
            # We want 0.3 of the height, with no trailing decimal
            # We have to use 'awk' here, since bash doesn't like floating decimals
            textHeight="$(awk '{print $1 * $2}' <<<"${posterHeight} 0.3")"
            textHeight="${textHeight%\.*}"
            strokeHeight="$(awk '{print $1 * $2}' <<<"${textHeight} 0.03")"
            strokeHeight="${strokeHeight%\.*}"
            convert "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/show.jpg" -gravity Center -pointsize "${textHeight}" -fill white -stroke black -strokewidth "${strokeHeight}" -annotate 0 "${vidYear[${ytId}]}" "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/Season${vidYear[${ytId}]}.jpg"
        elif [[ -d "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}" ]]; then
            # Assume we need to re-index, unless...
            needReindex="1"
            for ii in "${newDirs[@]}"; do
                # The directory we're writing to is one we created (${newDirs[@]} array)
                if [[ "${ii}" == "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}" ]]; then\
                    needReindex="0"
                    break
                fi
            done
            if [[ "${needReindex}" -eq "1" ]]; then
                # Add it to our ${reindexArray[@]}
                addToArray="1"
                for ii in "${reindexArray[@]}"; do
                    if [[ "${ii}" == "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}" ]]; then
                        # If it's not already in there
                        addToArray="0"
                        break
                    fi
                done
                if [[ "${addToArray}" -eq "1" ]]; then\
                    reindexArray+=("${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}")
                fi
            fi
        else
            badExit "33" "Impossible condition"
        fi

        # Write our upload timestamp
        if ! [[ -e "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/.season_timestamps" ]]; then
            echo "${vidEpoch[${ytId}]} ${ytIdClean[${ytId}]}" > "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/.season_timestamps"
        elif [[ -e "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/.season_timestamps" ]]; then
            needTime="1"
            while read -r ii; do
                if [[ "${ii#* }" == "${ytIdClean[${ytId}]}" ]]; then
                    # We already have a timestamp for this video, somehow?
                    needTime="0"
                    break
                fi
            done < "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/.season_timestamps"
            if [[ "${needTime}" -eq "1" ]]; then
                readarray -t timeArr < "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/.season_timestamps"
                timeArr+=("${vidEpoch[${ytId}]} ${ytIdClean[${ytId}]}")
                ( for ii in "${timeArr[@]}"; do echo "${ii}"; done ) | sort -n > "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/.season_timestamps"
                unset timeArr
            fi
        else
            badExit "34" "Impossible condition"
        fi

        # Video title cleaned
        vidTitleClean[${ytId}]="${vidTitle[${ytId}]//</}"
        vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//>/}"
        vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//\:/}"
        vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//\"/}"
        vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//\?/}"
        vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//\*/}"
        vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//\\/_}"
        vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//\//_}"
        vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//\|/_}"

        # Set our watch status to "Unwatched"
        watchStatusArray[${ytId}]="unwatched"

        printOutput "4" "Download completed in $(timeDiff "${startTime}") (${vidTitle[${ytId}]})"
        (( count++ ))
        #randomSleep "3" "10"

        # printOutput "4" "YTID: ${ytId}"
        # printOutput "4" "YTID_Clean: ${ytIdClean[${ytId}]}"
        # printOutput "4" "Title: ${vidTitle[${ytId}]}"
        # printOutput "4" "Upload: ${vidUpload[${ytId}]}"
        # printOutput "4" "Year: ${vidYear[${ytId}]}"
        # printOutput "4" "Epoch: ${vidEpoch[${ytId}]}"
        # printOutput "4" "Chan Name: ${channelName[${ytId}]}"
        # printOutput "4" "Chan ID: ${channelId[${ytId}]}"
        # printOutput "4" "Metadata: \${setChannelMetadata[${channelId[${ytId}]}]}=\"${setChannelMetadata[${channelId[${ytId}]}]}\""
        # printOutput "4" "channelName: ${channelName[${channelId[${ytId}]}]}"
        # printOutput "4" "channelDesc: ${channelDesc[${channelId[${ytId}]}]}"
        # printOutput "4" "channelUrl: ${channelUrl[${channelId[${ytId}]}]}"
        # printOutput "4" "channelSubs: ${channelSubs[${channelId[${ytId}]}]}"
        # printOutput "4" "channelVidCount: ${channelVidCount[${channelId[${ytId}]}]}"
        # printOutput "4" "channelViewCount: ${channelViewCount[${channelId[${ytId}]}]}"
        # printOutput "4" "channelDate: ${channelDate[${channelId[${ytId}]}]}"
        # printOutput "4" "channelCountry: ${channelCountry[${channelId[${ytId}]}]}"
        # printOutput "4" "channelImg: ${channelImg[${channelId[${ytId}]}]}"
        # printOutput "4" "channelBanner: ${channelBanner[${channelId[${ytId}]}]}"
    done
elif [[ "${#vidIds[@]}" -eq "0" ]]; then
    printOutput "3" "No files to be downloaded"
else
    badExit "35" "Impossible condition"
fi

if [[ "${#moveArray[@]}" -ge "1" ]]; then
    printOutput "3" "############### Moving downloaded files ###############"
    count="1"
    for ytId in "${moveArray[@]}"; do
        printOutput "4" "Processing YTID: ${ytIdClean[${ytId}]}"
        # Get the episode number from the season timestamps file entry
        if ! [[ -e "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/.season_timestamps" ]]; then
            badExit "36" "No season timestamp index present for: ${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}"
        fi
        epNum="1"
        while read -r ii; do
            if [[ "${ii#* }" == "${ytIdClean[${ytId}]}" ]]; then
                break
            elif [[ "${epNum}" -ge "1000" ]]; then
                printOutput "1" "Unable to support seasons beyond 999 episodes, skipping file [${ytIdClean[${ytId}]}]"
                (( count++ ))
                continue 2
            else
                (( epNum++ ))
            fi
        done < "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/.season_timestamps"
        epCode[${ytId}]="S${vidYear[${ytId}]}E$(printf '%03d' "${epNum}")"
        mv "${stagingDir}/${ytIdClean[${ytId}]}.info.json" "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/.${ytIdClean[${ytId}]}.json"
        mv "${stagingDir}/${ytIdClean[${ytId}]}.jpg" "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/${channelName[${ytId}]} - ${epCode[${ytId}]} - ${vidTitleClean[${ytId}]} [${ytIdClean[${ytId}]}].jpg"
        mv "${stagingDir}/${ytIdClean[${ytId}]}.mp4" "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/${channelName[${ytId}]} - ${epCode[${ytId}]} - ${vidTitleClean[${ytId}]} [${ytIdClean[${ytId}]}].mp4"
        if ! [[ -e "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/.${ytIdClean[${ytId}]}.json" ]]; then
            badExit "37" "Unable to move JSON file"
        fi
        if ! [[ -e "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/${channelName[${ytId}]} - ${epCode[${ytId}]} - ${vidTitleClean[${ytId}]} [${ytIdClean[${ytId}]}].jpg" ]]; then
            badExit "38" "Unable to move thumbnail file"
        fi
        if ! [[ -e "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/${channelName[${ytId}]} - ${epCode[${ytId}]} - ${vidTitleClean[${ytId}]} [${ytIdClean[${ytId}]}].mp4" ]]; then
            badExit "39" "Unable to move video file"
        fi
        printOutput "4" "Moved file ID [${ytIdClean[${ytId}]}] to [${channelName[${ytId}]} - ${epCode[${ytId}]} - ${vidTitleClean[${ytId}]}] [Item ${count} of ${#moveArray[@]}]"
        knownFiles[${ytId}]="${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/${channelName[${ytId}]} - ${epCode[${ytId}]} - ${vidTitleClean[${ytId}]} [${ytIdClean[${ytId}]}].mp4"

        (( count++ ))
    done
elif [[ "${#moveArray[@]}" -eq "0" ]]; then
    printOutput "3" "No files to be moved"
else
    badExit "40" "Impossible condition"
fi

# If we were on a download-only run we can safely exit
if [[ "${downloadOnly}" == "true" ]]; then
    cleanExit
fi

# Set any channel metadata waiting to be set
if [[ "${#setChannelMetadata[@]}" -ne "0" ]]; then
    printOutput "3" "############## Updating channel metadata ##############"
    # Start by refreshing the library to ensure PMS assigns the necessary values for us to update it
    refreshLibrary
    # We should sleep for 3 seconds per file downloaded, with a minimum of 20 seconds, maximum of 300 seconds
    sleepMin="$(( ${#moveArray[@]} * 3 ))"
    if [[ "${sleepMin}" -lt "20" ]]; then
        sleepMin="20"
    fi
    sleepMax="$(( ${#moveArray[@]} * 5 ))"
    if [[ "${sleepMax}" -gt "300" ]]; then
        sleepMax="300"
    fi
    if [[ "${sleepMin}" -gt "${sleepMax}" ]]; then
        if [[ "${sleepMin}" -le "80" ]]; then
            sleepMax="$(( sleepMin + 60 ))"
        else
            sleepMin="$(( sleepMax - 60 ))"
        fi
    elif [[ "${sleepMax}" -lt "${sleepMin}" ]]; then
        sleepMax="$(( sleepMin + 60 ))"
    fi
    randomSleep "${sleepMin}" "${sleepMax}"
    for chanId in "${!setChannelMetadata[@]}"; do
        printOutput "3" "Setting channel metadata (${channelName[${chanId}]} [${chanId}]) with file ID [${setChannelMetadata[${chanId}]}]"
        getChannelInfo "${chanId}"
        setPlexMetadata "${setChannelMetadata[${chanId}]}"
    done
fi

if [[ "${#reindexArray[@]}" -ge "1" ]]; then
    printOutput "3" "############### Re-indexing known files ###############"
    for i in "${reindexArray[@]}"; do
        printOutput "3" "Processing: ${i}"
        # Check to see if all the files are where they *should* be. If so, no need to do anything.
        unset renameArrayFrom renameArrayTo
        declare -A renameArrayFrom renameArrayTo
        printOutput "3" "Verifying correct episode coding of items in season"
        while read -r inputFile; do
            ytId="${inputFile%\]\.mp4}"
            ytId="_${ytId##*\[}"
            if [[ -z "${ytIdClean[${ytId}]}" ]]; then
                ytIdClean[${ytId}]="${ytId#_}"
            fi

            # Where can we find the item's JSON?
            itemJson="${i}/.${ytIdClean[${ytId}]}.json"

            # Build what should be the file name
            # Video title
            if [[ -z "${vidTitle[${ytId}]}" ]]; then
                vidTitle[${ytId}]="$(jq -M -r ".title" "${i}/.${ytIdClean[${ytId}]}.json")"
            fi

            if [[ -z "${vidTitleClean[${ytId}]}" ]]; then
                vidTitleClean[${ytId}]="${vidTitle[${ytId}]//</}"
                vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//>/}"
                vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//\:/}"
                vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//\"/}"
                vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//\?/}"
                vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//\*/}"
                vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//\\/_}"
                vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//\//_}"
                vidTitleClean[${ytId}]="${vidTitleClean[${ytId}]//\|/_}"
            fi

            # Video upload year
            if [[ -z "${vidUpload[${ytId}]}" ]]; then
                vidUpload[${ytId}]="$(jq -M -r ".upload_date" "${i}/.${ytIdClean[${ytId}]}.json")"
            fi
            if [[ -z "${vidYear[${ytId}]}" ]]; then
                vidYear[${ytId}]="${vidUpload[${ytId}]:0:4}"
            fi

            # Channel name
            if [[ -z "${channelName[${ytId}]}" ]]; then
                channelName[${ytId}]="$(jq -M -r ".channel" "${i}/.${ytIdClean[${ytId}]}.json")"
                if [[ "${channelName[${ytId}]}" == "null" ]]; then
                    channelName[${ytId}]="$(jq -M -r ".uploader_id" "${i}/.${ytIdClean[${ytId}]}}.json")"
                fi
            fi
            # Channel ID
            if [[ -z "${channelId[${ytId}]}" ]]; then
                channelId[${ytId}]="$(jq -M -r ".channel_id" "${i}/.${ytIdClean[${ytId}]}.json")"
            fi

            # Get the episode number from the season timestamps file entry
            epNum="1"
            while read -r iii; do
                if [[ "${iii#* }" == "${ytIdClean[${ytId}]}" ]]; then
                    break
                elif [[ "${epNum}" -ge "1000" ]]; then
                    printOutput "1" "Unable to support seasons beyond 999 episodes, skipping file [${ytIdClean[${ytId}]}]"
                    continue 2
                else
                    (( epNum++ ))
                fi
            done < "${i}/.season_timestamps"
            epCode[${ytId}]="S${vidYear[${ytId}]}E$(printf '%03d' "${epNum}")"

            # Now we have the complete path of where the file *should* be
            if ! [[ "${inputFile}" == "${i}/${channelName[${ytId}]} - ${epCode[${ytId}]} - ${vidTitleClean[${ytId}]} [${ytIdClean[${ytId}]}].mp4" ]]; then
                unset oldEpCode
                oldEpCode="${inputFile#*/}"
                oldEpCode="${oldEpCode#* - }"
                oldEpCode="${oldEpCode%% - *}"
                printOutput "4" "Video ID [${ytIdClean[${ytId}]}][${vidTitle[${ytId}]}] has incorrect position [${oldEpCode}], moving to [${epCode[${ytId}]}]"
                renameArrayFrom[${ytId}]="${inputFile}"
                renameArrayTo[${ytId}]="${i}/${channelName[${ytId}]} - ${epCode[${ytId}]} - ${vidTitleClean[${ytId}]} [${ytIdClean[${ytId}]}].mp4"
            fi
        done < <(find "${i}" -type f -name "*.mp4")
        if [[ "${#renameArrayFrom[@]}" -ge "1" ]]; then
            for i in "${!renameArrayFrom[@]}"; do
                ytId="${i}"
                break
            done
            # We gotta do a rename in that year

            # Step 1, get the watched status for all items in the season to be re-indexed
            # We can use just the first item of the array for this, since really we just need the season year
            # To start, we need to rating key for the season we want
            printOutput "3" "Obtaining watch status for items in season"

            # Get the show key
            unset showKey
            if [[ -e "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/.show_ratingkey" ]]; then
                readarray -t showKey < "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/.show_ratingkey"
            else
                callCurl "${plexAdd}/library/sections/${libraryId[0]}/all?X-Plex-Token=${plexToken}"
                plexOutputToJson
                readarray -t showKey < <(jq -M -r ".MediaContainer.Directory | if type==\"array\" then .[] else . end | select ( .\"@title\" == \"${channelName[${ytId}]}\" ) .\"@ratingKey\"" <<<"${curlOutput}")
            fi
            if [[ "${#showKey[@]}" -ne "1" ]]; then
                printOutput "1" "Invalid number of show keys returned for [${channelName[${ytId}]}] - ${#showKey[@]} results [${showKey[*]}]"
                continue
            elif ! [[ -e "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/.show_ratingkey" ]]; then
                echo "${showKey[0]}" > "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/.show_ratingkey"
            fi

            # Get the season key
            unset seasonKey
            if [[ -e "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/.season_ratingkey" ]]; then
                readarray -t seasonKey < "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/.season_ratingkey"
            else
                callCurl "${plexAdd}/library/metadata/${showKey[0]}/children?X-Plex-Token=${plexToken}"
                plexOutputToJson
                readarray -t seasonKey < <(jq -M -r ".MediaContainer.Directory | if type==\"array\" then .[] else . end | select ( .\"@title\" == \"Season ${vidYear[${ytId}]}\" ) .\"@ratingKey\"" <<<"${curlOutput}")
            fi
            if [[ "${#seasonKey[@]}" -ne "1" ]]; then
                printOutput "1" "Invalid number of season keys returned for [${vidYear[${ytId}]}][Show key: ${showKey[0]}] - ${#seasonKey[@]} results [${seasonKey[*]}]"
                continue
            elif ! [[ -e "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/.season_ratingkey" ]]; then
                echo "${seasonKey[0]}" > "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/.season_ratingkey"
            fi

            # Get the watch status for the season
            callCurl "${plexAdd}/library/metadata/${seasonKey[0]}/children?X-Plex-Token=${plexToken}"
            plexOutputToJson
            while read -r z; do
                # z is the rating key
                unset watchFileArr
                readarray -t watchFileArr < <(jq -M -r ".MediaContainer.Video | if type==\"array\" then .[] else . end | select ( .\"@ratingKey\" == \"${z}\" ) | .Media | if type==\"array\" then .[] else . end | .Part.\"@file\"" <<<"${curlOutput}")
                # In case there's more than one file for the rating key, we can live with just one file ID
                watchFileId="${watchFileArr[0]%\]\.mp4}"
                watchFileId="_${watchFileId##*\[}"
                # We want either
                # - ".MediaContainer.Video.\"@viewOffset\" (Partially watched)
                # - ".MediaContainer.Video.\"@viewCount\" (Watched)
                # If neither of those two keys exist, item is (Unwatched)
                watchStatus="$(jq -M -r ".MediaContainer.Video | if type==\"array\" then .[] else . end | select ( .\"@ratingKey\" == \"${z}\" ) .\"@viewCount\"" <<<"${curlOutput}")"
                if [[ "${watchStatus}" == "null" ]]; then
                    # It's not 'Watched', is it partially watched?
                    watchStatus="$(jq -M -r ".MediaContainer.Video | if type==\"array\" then .[] else . end | select ( .\"@ratingKey\" == \"${z}\" ) .\"@viewOffset\"" <<<"${curlOutput}")"
                    if [[ "${watchStatus}" == "null" ]]; then
                        # It's 'Unwatched'
                        watchStatusArray[${watchFileId}]="unwatched"
                    elif [[ "${watchStatus}" =~ ^[0-9]+$ ]]; then
                        # It's 'Partially watched'
                        watchStatusArray[${watchFileId}]="${watchStatus}"
                    else
                        badExit "41" "Unexpected watch status: ${watchStatus}"
                    fi
                else
                    # It's 'Watched'
                    watchStatusArray[${watchFileId}]="watched"
                fi
            done < <(jq -M -r ".MediaContainer.Video | if type==\"array\" then .[] else . end | .\"@ratingKey\"" <<<"${curlOutput}")

            # Assign an "Unwatched" status to any files that exist on disk, but do not exist in Plex
            while read -r ii; do
                watchFileId="${ii%\]\.mp4}"
                watchFileId="_${watchFileId##*\[}"
                if [[ -z "${watchStatusArray[${watchFileId}]}" ]]; then
                    watchStatusArray[${watchFileId}]="unwatched"
                fi
                printOutput "4" "File ID [${ytIdClean[${watchFileId}]}][${vidTitle[${ytId}]}] has watch status [${watchStatusArray[${watchFileId}]}]"
            done < <(find "${outputDir}/${channelName[${ytId}]} [${channelId[${ytId}]}]/Season ${vidYear[${ytId}]}/" -type f -name "*.mp4")

            # Step 2, move the files
            printOutput "3" "Correcting episode coding of items in season"
            for ii in "${!renameArrayFrom[@]}"; do
                # Move the thumbnail
                mv "${renameArrayFrom[${ii}]//\.mp4/.jpg}" "${renameArrayTo[${ii}]//\.mp4/.jpg}"
                if [[ -e "${renameArrayFrom[${ii}]//\.mp4/.jpg}" ]]; then
                    printOutput "1" "Unable to rename thumbnail: ${renameArrayFrom[${ii}]//\.mp4/.jpg}"
                elif [[ -e "${renameArrayTo[${ii}]//\.mp4/.jpg}" ]]; then
                    printOutput "4" "File ID [${ytIdClean[${ii}]}][${vidTitle[${ytId}]}] thumbnail successfully re-indexed"
                else
                    badExit "42" "Unexpected thumbnail re-index outcome"
                fi
                # Move the file
                mv "${renameArrayFrom[${ii}]}" "${renameArrayTo[${ii}]}"
                if [[ -e "${renameArrayFrom[${ii}]}" ]]; then
                    printOutput "1" "Unable to rename video: ${renameArrayFrom[${ii}]}"
                elif [[ -e "${renameArrayTo[${ii}]}" ]]; then
                    printOutput "4" "File ID [${ytIdClean[${ii}]}][${vidTitle[${ytId}]}] video successfully re-indexed"
                else
                    badExit "43" "Unexpected video re-index outcome"
                fi
                knownFiles[${ii}]="${renameArrayTo[${ii}]}"
            done

            # Step 3, refresh the library
            refreshLibrary
            # We should sleep for 3 seconds per file re-indexed, with a minimum of 20 seconds, maximum of 300 seconds
            sleepMin="$(( ${#renameArrayFrom[@]} * 3 ))"
            if [[ "${sleepMin}" -lt "20" ]]; then
                sleepMin="20"
            fi
            sleepMax="$(( ${#renameArrayFrom[@]} * 5 ))"
            if [[ "${sleepMax}" -gt "300" ]]; then
                sleepMax="300"
            fi
            if [[ "${sleepMin}" -gt "${sleepMax}" ]]; then
                if [[ "${sleepMin}" -le "80" ]]; then
                    sleepMax="$(( sleepMin + 60 ))"
                else
                    sleepMin="$(( sleepMax - 60 ))"
                fi
            elif [[ "${sleepMax}" -lt "${sleepMin}" ]]; then
                sleepMax="$(( sleepMin + 60 ))"
            fi
            randomSleep "${sleepMin}" "${sleepMax}"

            printOutput "3" "Issuing a 'Refresh all metadata' command to Plex"
            callCurl "${plexAdd}/library/sections/${libraryId[0]}/refresh?force=1&X-Plex-Token=${plexToken}"
            randomSleep "30" "60"

            # Step 4, apply the old watched status to all old items, unwatched to all new items
            printOutput "3" "Correcting watch status for items in season"
            if [[ "${#watchStatusArray[@]}" -eq "0" ]]; then
                badExit "44" "No items in watch status array to set"
            fi
            for zz in "${!watchStatusArray[@]}"; do
                getMediaId "${zz#_}"
                if [[ "${watchStatusArray[${zz}]}" == "watched" ]]; then
                    # Issue the call to mark the item as watched
                    printOutput "4" "Marking file ID [${ytIdClean[${zz}]}][${vidTitle[${zz}]}] as watched"
                    callCurl "${plexAdd}/:/scrobble?identifier=com.plexapp.plugins.library&key=${mediaIdArr[${zz}]}&X-Plex-Token=${plexToken}"
                elif [[ "${watchStatusArray[${zz}]}" == "unwatched" ]]; then
                    # Issue the call to mark the item as unwatched
                    printOutput "4" "Marking file ID [${ytIdClean[${zz}]}][${vidTitle[${zz}]}] as unwatched"
                    callCurl "${plexAdd}/:/unscrobble?identifier=com.plexapp.plugins.library&key=${mediaIdArr[${zz}]}&X-Plex-Token=${plexToken}"
                elif [[ "${watchStatusArray[${zz}]}" =~ ^[0-9]+$ ]]; then
                    # Issue the call to mark the item as partially watched
                    printOutput "4" "Marking file ID [${ytIdClean[${zz}]}][${vidTitle[${zz}]}] as partially watched watched [${watchStatusArray[${zz}]}ms]"
                    callCurlPut "${plexAdd}/:/progress?key=${mediaIdArr[${zz}]}&identifier=com.plexapp.plugins.library&time=${watchStatusArray[${zz}]}&state=stopped&X-Plex-Token=${plexToken}"
                else
                    badExit "45" "Unexpected watch status for [${ytIdClean[${zz}]}][${vidTitle[${zz}]}]: ${watchStatusArray[${zz}]}"
                fi
            done
        fi
    done
elif [[ "${#reindexArray[@]}" -eq "0" ]]; then
    printOutput "3" "No directories to be reindexed"
else
    badExit "46" "Impossible condition"
fi

# TODO: PAD ASSOCIATIVE ARRAYS FOR YTID'S IN PLAYLISTS AND COLLECTIONS
if [[ "${#plIds[@]}" -ge "1" ]]; then
    printOutput "3" "################# Processing playlists ################"
    for playlistId in "${!plIds[@]}"; do
        unset ytOrderByNum ytIndexSorted playlistJson playlistTitle playlistDesc playlistImg playlistAvailability collectionKey playlistKey
        declare -A ytOrderByNum
        printOutput "3" "Processing playlist ID: ${playlistId}"
        # Start by determining if the playlist type is public or private
        playlistJson="$(yt-dlp --cookies "${cookieFile}" --retry-sleep 30 --skip-download --no-warnings --flat-playlist -J "https://www.youtube.com/playlist?list=${playlistId}")"
        playlistTitle="$(jq -M -r ".title" <<<"${playlistJson}")"
        playlistAvailability="$(jq -M -r ".availability" <<<"${playlistJson}")"
        playlistDesc="$(jq -M -r ".description" <<<"${playlistJson}")"
        playlistImg="$(jq -M -r ".thumbnails[-1].url" <<<"${playlistJson}")"
        while read -r i; do
            if [[ -n "${knownFiles[_${i}]}" ]]; then
                # If we don't have information on a file, we should get It
                if [[ -z "${ytIdClean[_${i}]}" ]]; then
                    ytIdClean[_${i}]="${i}"
                fi

                # Where can we find the item's JSON?
                itemJson="${knownFiles[_${i}]%/*}/.${i}.json"

                # Build what should be the file name
                # Video title
                if [[ -z "${vidTitle[_${i}]}" ]]; then
                    vidTitle[_${i}]="$(jq -M -r ".title" "${itemJson}")"
                fi

                if [[ -z "${vidTitleClean[_${i}]}" ]]; then
                    vidTitleClean[_${i}]="${vidTitle[_${i}]//</}"
                    vidTitleClean[_${i}]="${vidTitleClean[_${i}]//>/}"
                    vidTitleClean[_${i}]="${vidTitleClean[_${i}]//\:/}"
                    vidTitleClean[_${i}]="${vidTitleClean[_${i}]//\"/}"
                    vidTitleClean[_${i}]="${vidTitleClean[_${i}]//\?/}"
                    vidTitleClean[_${i}]="${vidTitleClean[_${i}]//\*/}"
                    vidTitleClean[_${i}]="${vidTitleClean[_${i}]//\\/_}"
                    vidTitleClean[_${i}]="${vidTitleClean[_${i}]//\//_}"
                    vidTitleClean[_${i}]="${vidTitleClean[_${i}]//\|/_}"
                fi

                # Video upload year
                if [[ -z "${vidUpload[_${i}]}" ]]; then
                    vidUpload[_${i}]="$(jq -M -r ".upload_date" "${itemJson}")"
                fi
                if [[ -z "${vidYear[_${i}]}" ]]; then
                    vidYear[_${i}]="${vidUpload[_${i}]:0:4}"
                fi

                # Channel name
                if [[ -z "${channelName[_${i}]}" ]]; then
                    channelName[_${i}]="$(jq -M -r ".channel" "${itemJson}")"
                    if [[ "${channelName[_${i}]}" == "null" ]]; then
                        channelName[_${i}]="$(jq -M -r ".uploader_id" "${itemJson}")"
                    fi
                fi
                # Channel ID
                if [[ -z "${channelId[_${i}]}" ]]; then
                    channelId[_${i}]="$(jq -M -r ".channel_id" "${itemJson}")"
                fi

                # Do a media lookup
                getMediaId "${i}"
                if [[ -n "${mediaIdArr[_${i}]}" ]]; then
                    ytOrderByNum[$(( ${#ytOrderByNum[@]} + 1))]="${i}"
                fi
            fi
        done < <(jq -M -r ".entries  | if type==\"array\" then .[] else . end | .id" <<<"${playlistJson}")

        readarray -t ytIndexSorted < <(for i in "${!ytOrderByNum[@]}"; do echo "${i}"; done | sort -n)

        # Now we have all the information we need from the playlist, let's get some info from Plex
        # printOutput "4" ""
        # printOutput "4" "ytIndexSorted: ${#ytIndexSorted[@]}"
        # for z in "${!ytIndexSorted[@]}"; do
            # printOutput "4" "\${ytIndexSorted[${z}]} => ${ytIndexSorted[${z}]}"
        # done
        # printOutput "4" "ytOrderByNum: ${#ytOrderByNum[@]}"
        # for z in "${ytIndexSorted[@]}"; do
            # printOutput "4" "\${ytOrderByNum[${z}]} => ${ytOrderByNum[${z}]} [${vidTitle[_${ytOrderByNum[${z}]}]}]"
        # done
        # printOutput "4" "plOrderByNum: ${#plOrderByNum[@]}"
        # for z in "${plIndexSorted[@]}"; do
            # printOutput "4" "\${plOrderByNum[${z}]} => ${plOrderByNum[${z}]} [${vidTitle[_${plOrderByNum[${z}]}]}]"
        # done
        # printOutput "4" "mediaIdArr: ${#mediaIdArr[@]}"
        # for z in "${!mediaIdArr[@]}"; do
            # printOutput "4" "\${mediaIdArr[${z}]} => ${mediaIdArr[${z}]} [${vidTitle[${z}]}]"
        # done
        # printOutput "4" ""

        printOutput "4" "Availability: ${playlistAvailability^}"
        if [[ "${playlistAvailability,,}" == "public" ]]; then
            # Treat it as a collection
            # Get collections from Plex
            callCurl "${plexAdd}/library/sections/${libraryId[0]}/collections?X-Plex-Token=${plexToken}"
            plexOutputToJson
            if [[ "$(jq -M -r ".MediaContainer.Directory | length" <<<"${curlOutput}")" -ge "1" ]]; then
                readarray -t plexCollections < <(jq -M -r ".MediaContainer.Directory | if type==\"array\" then .[] else . end | .\"@title\"" <<<"${curlOutput}")
                if ! [[ "${plexCollections[0]}" == "null" ]]; then
                    for ii in "${plexCollections[@]}"; do
                        if [[ "${ii}" == "${playlistTitle}" ]]; then
                            # It's a match, get the rating key
                            collectionKey="$(jq -M -r ".MediaContainer.Directory | if type==\"array\" then .[] else . end | select ( .\"@title\" == \"${ii}\" ) .\"@ratingKey\"" <<<"${curlOutput}")"
                            printOutput "3" "Existing collection found: ${ii}"
                            printOutput "4" "Existing collection ID: ${collectionKey}"
                            break
                        fi
                    done
                fi
            fi
            if [[ -z "${collectionKey}" ]]; then
                printOutput "3" "Creating collection '${playlistTitle}'"
                # Create a collection and get the key returned
                collectionNameEncoded="$(jq -rn --arg x "${playlistTitle}" '$x|@uri')"

                # Issue POST call to create collection
                callCurlPost "${plexAdd}/library/collections?type=4&title=${collectionNameEncoded}&smart=0&uri=server%3A%2F%2F${plexMachineIdentifier}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${mediaIdArr[_${ytOrderByNum[${ytIndexSorted[0]}]}]}&sectionId=${libraryId[0]}&X-Plex-Token=${plexToken}"
                plexOutputToJson
                collectionKey="$(jq -M -r ".MediaContainer.Directory.\"@ratingKey\"" <<<"${curlOutput}")"
                printOutput "4" "Collection ID [${collectionKey}] Seeded video ID [${ytOrderByNum[${ytIndexSorted[0]}]}][${vidTitle[_${ytOrderByNum[${ytIndexSorted[0]}]}]}]"

                callCurlPut "${plexAdd}/library/metadata/${collectionKey}/prefs?collectionSort=2&X-Plex-Token=${plexToken}"
                printOutput "4" "Collection order set to 'Custom'"

                if [[ "${playlistDesc}" == "null" ]]; then
                    collectionDescEncoded="$(jq -rn --arg x "https://www.youtube.com/playlist?list=${playlistId}" '$x|@uri')"
                else
                    collectionDescEncoded="$(jq -rn --arg x "${playlistDesc}${lineBreak}https://www.youtube.com/playlist?list=${playlistId}" '$x|@uri')"
                fi
                callCurlPut "${plexAdd}/library/sections/${libraryId[0]}/all?type=18&id=${collectionKey}&includeExternalMedia=1&summary.value=${collectionDescEncoded}&summary.locked=1&X-Plex-Token=${plexToken}"
                printOutput "4" "Collection description updated"

                # TODO: Update collection image with ${playlistImg}
                if [[ -n "${playlistImg}" ]] && ! [[ "${playlistImg}" == "null" ]]; then
                    callCurlDownload "${playlistImg}" "${stagingDir}/${playlistId}.jpg"
                    callCurlPost "${plexAdd}/library/metadata/${collectionKey}/posters?X-Plex-Token=${plexToken}" --data-binary "@${stagingDir}/${playlistId}.jpg"
                    rm -f "${stagingDir}/${playlistId}.jpg"
                    printOutput "4" "Collection image set"
                fi

                # We know we had to create this collection, so we can go ahead and just add every item in ${ytIndexSorted[@]} to it sequentially
                # Skip the first item, it was already added when we made the collection
                for iii in "${ytIndexSorted[@]:1}"; do
                    # We need to get the media ID for the video
                    callCurlPut "${plexAdd}/library/collections/${collectionKey}/items?uri=server%3A%2F%2F${plexMachineIdentifier}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${mediaIdArr[_${ytOrderByNum[${iii}]}]}&X-Plex-Token=${plexToken}"
                    printOutput "3" "Added [${ytOrderByNum[${iii}]}][${vidTitle[_${ytOrderByNum[${iii}]}]}] to collection [${playlistTitle}]"
                done
                # Verify collection order
                getCollectionOrder
                collectionVerifySort
            elif [[ "${collectionKey}" =~ ^[0-9]+$ ]]; then
                # 1. Get playlist order in Plex
                getCollectionOrder
                # 2. Check for items that need to be added
                collectionVerifyAdd
                # 3. Check for items that need to be removed
                collectionVerifyDelete
                # 4. Check for items that need to be re-ordered
                collectionVerifySort
            else
                badExit "47" "Unexpected collection ID: ${collectionKey}"
            fi
        elif [[ "${playlistAvailability,,}" == "private" ]]; then
            # Treat it as a playlist
            # Get playlists from Plex
            callCurl "${plexAdd}/playlists/?X-Plex-Token=${plexToken}"
            plexOutputToJson
            if [[ "$(jq -M -r ".MediaContainer.Playlist | length" <<<"${curlOutput}")" -ge "1" ]]; then
                readarray -t plexPlaylists < <(jq -M -r ".MediaContainer.Playlist | if type==\"array\" then .[] else . end | .\"@title\"" <<<"${curlOutput}")
                if ! [[ "${plexPlaylists[0]}" == "null" ]]; then
                    for ii in "${plexPlaylists[@]}"; do
                        if [[ "${ii}" == "${playlistTitle}" ]]; then
                            # It's a match, get the rating key
                            playlistKey="$(jq -M -r ".MediaContainer.Playlist | if type==\"array\" then .[] else . end | select ( .\"@title\" == \"${ii}\" ) .\"@ratingKey\"" <<<"${curlOutput}")"
                            printOutput "3" "Existing playlist found: ${ii}"
                            printOutput "4" "Existing playlist ID: ${playlistKey}"
                            break
                        fi
                    done
                fi
            fi
            if [[ -z "${playlistKey}" ]]; then
                printOutput "3" "Creating playlist [${playlistTitle}]"
                # Create a playlist and get the key returned
                playlistNameEncoded="$(jq -rn --arg x "${playlistTitle}" '$x|@uri')"

                # Issue POST call to create playlist
                callCurlPost "${plexAdd}/playlists?type=video&title=${playlistNameEncoded}&smart=0&uri=server%3A%2F%2F${plexMachineIdentifier}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${mediaIdArr[_${ytOrderByNum[${ytIndexSorted[0]}]}]}&X-Plex-Token=${plexToken}"
                plexOutputToJson
                playlistKey="$(jq -M -r ".MediaContainer.Playlist.\"@ratingKey\"" <<<"${curlOutput}")"
                printOutput "4" "Playlist ID [${playlistKey}] Seeded video ID [${ytOrderByNum[${ytIndexSorted[0]}]}][${vidTitle[_${ytOrderByNum[${ytIndexSorted[0]}]}]}]"

                if [[ "${playlistDesc}" == "null" ]]; then
                    playlistDescEncoded="$(jq -rn --arg x "https://www.youtube.com/playlist?list=${playlistId}" '$x|@uri')"
                else
                    playlistDescEncoded="$(jq -rn --arg x "${playlistDesc}${lineBreak}https://www.youtube.com/playlist?list=${playlistId}" '$x|@uri')"
                fi
                callCurlPut "${plexAdd}/playlists/${playlistKey}?summary=${playlistDescEncoded}&X-Plex-Token=${plexToken}"
                printOutput "4" "Playlist description updated"

                # TODO: Update playlist image with ${playlistImg}
                if [[ -n "${playlistImg}" ]] && ! [[ "${playlistImg}" == "null" ]]; then
                    callCurlDownload "${playlistImg}" "${stagingDir}/${playlistId}.jpg"
                    callCurlPost "${plexAdd}/library/metadata/${playlistKey}/posters?X-Plex-Token=${plexToken}" --data-binary "@${stagingDir}/${playlistId}.jpg"
                    rm -f "${stagingDir}/${playlistId}.jpg"
                    printOutput "4" "Playlist image set"
                fi

                # We know we had to create this playlist, so we can go ahead and just add every item in ${ytIndexSorted[@]} to it sequentially
                # Skip the first item, it was already added when we made the playlist
                for iii in "${ytIndexSorted[@]:1}"; do
                    # We need to get the media ID for the video
                    callCurlPut "${plexAdd}/playlists/${playlistKey}/items?uri=server%3A%2F%2F${plexMachineIdentifier}%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F${mediaIdArr[_${ytOrderByNum[${iii}]}]}&X-Plex-Token=${plexToken}"
                    printOutput "3" "Added [${ytOrderByNum[${iii}]}][${vidTitle[_${ytOrderByNum[${iii}]}]}] to playlist [${playlistTitle}]"
                done
                # TODO: CORRECT ORDER
                getPlaylistOrder
                playlistVerifySort
            elif [[ "${playlistKey}" =~ ^[0-9]+$ ]]; then
                # 1. Get playlist order in Plex
                getPlaylistOrder
                # 2. Check for items that need to be added
                playlistVerifyAdd
                # 3. Check for items that need to be removed
                playlistVerifyDelete
                # 4. Check for items that need to be re-ordered
                playlistVerifySort
            else
                badExit "48" "Unexpected playlist ID: ${playlistKey}"
            fi
        else
            badExit "49" "Unexpected playlist type: ${playlistAvailability}"
        fi
    done
elif [[ "${#plIds[@]}" -eq "0" ]]; then
    printOutput "3" "No playlists to be processed"
else
    badExit "50" "Impossible condition"
fi

if [[ "${#errorArr[@]}" -ne "0" ]]; then
    printOutput "1" "################### Known error log ###################"
    for i in "${errorArr[@]}"; do
        printOutput "1" "${i}"
    done
fi

cleanExit
