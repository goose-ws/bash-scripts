#!/usr/bin/env bash

# Automate the process of numbering the bad exit codes

if [[ -z "${BASH_VERSINFO[0]}" || "${BASH_VERSINFO[0]}" -lt "4" ]]; then
    echo "This script requires Bash version 4 or greater"
    exit 255
fi
depArr=("grep" "head" "tail" "sed" "read" "echo" "cut" "mktemp")
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

if ! [[ -e "${1}" ]]; then
	echo "No such file: ${1}"
	exit 1
fi
if ! [[ "${1##*.}" == "bash" ]]; then
	echo "${1} does not appear to be a bash script"
	exit 1
fi

grep -n -E "badExit \".+\" \".*\"$" "${1}"
echo ""
read -p "Continue? [y/n]> " userInput

if ! [[ "${userInput}" == "y" ]]; then
	exit 0
fi

cp "${1}" "${1}.bak"
sed -i 's/\t/    /g' "${1}"
tmpFile="$(mktemp)"

readarray -t lineArr < <(grep -n -E "badExit \".+\" \".*\"$" "${1}" | cut -f1 -d:)

num="1"
for i in "${lineArr[@]}"; do
	line="$(head -n "${i}" "${1}" | tail -n 1)"
	spaces="${line%%badExit \"*}"
	reason="${line%\"}"
	reason="${reason##* \"}"
	replace="${spaces}badExit \"${num}\" \"${reason}\""
	echo "${replace}"
	head -n "$(( i - 1 ))" "${1}" > "${tmpFile}"
	echo "${replace}" >> "${tmpFile}"
	tail -n+$(( i + 1 )) "${1}" >> "${tmpFile}"
	cat "${tmpFile}" > "${1}"
	(( num++ ))
done

rm "${tmpFile}"

diff "${1}.bak" "${1}"