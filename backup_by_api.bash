#!/bin/bash
set -uo pipefail

# If the proxy is down, prefix invocation with:
# no_proxy="*"
[ ! -e ./conf ] && die "Config file not found."

. ./conf

# only get stuff mod'd since this date
# set to empty string to get everything ever
MODIFIED_SINCE="2024-09-01"

MY_USER=$(<<<${CRED} cut -d: -f1)

CURLCMD="curl --no-progress-meter -u ${CRED} ${CERTFLAGS}"
TLSHOSTPREFIX="https://${HOSTPREFIX}"

TLSDOMAIN="https://$(<<<$HOSTPREFIX cut -d/ -f1)"
PDFURL="${TLSHOSTPREFIX}/spaces/flyingpdf"

ASSETURL="${TLSHOSTPREFIX}/download/attachments"
APIURL="${TLSHOSTPREFIX}/rest/api"

CQL_QUERY="contributor=${MY_USER}"
CQL_QUERY+="+and+type+in+(page,attachment)"
CQL_QUERY+="+and+type+not+in+(comment)"
if [ "z${MODIFIED_SINCE}" != "z" ]; then
	CQL_QUERY+="+and+lastmodified+%3E+${MODIFIED_SINCE}"
fi

# Override CQL_QUERY here if desired
#CQL_QUERY=''

#echo ${CQL_QUERY}

EXTRA_TERMS="&includeArchivedSpaces=true"
SEARCHURL="${APIURL}/content/search?cql=${CQL_QUERY}${EXTRA_TERMS}"

P1=$(curl --no-progress-meter -u ${CRED} ${CERTFLAGS} "${SEARCHURL}")

TOTAL_SIZE=$(<<<"${P1}" jq .totalSize)
PAGE_LIMIT=$(<<<"${P1}" jq .limit)

# Exit script with error message
# $1: error message
die() {
	echo $1
	exit 1
}

# Get URL if not existing already
# $1: type
# $2: title
# $3: _links.webui
# $4: _expandable.history
get_if() {
	OUTPATH=""
	GETURL=""
	if [ "z$1" == "zattachment" ]; then
		mkdir -p data/assets
		OUTPATH="data/assets/$2"
		GETURL="$3"
		<<<"${GETURL}" grep -q "preview="
		[ $? -eq 0 ] && GETURL=$(
			VAL=$(<<<${GETURL} awk -F[\?=] '{print $3}' \
				| sed -e 's:%2F:/:g')
			GETURL="${ASSETURL}${VAL}"
			# echo needed because subshell
			echo $GETURL
		)
	else
		mkdir -p data/pages
		OUTPATH="data/pages/$2.html"
		GETURL="${TLSHOSTPREFIX}$3"
	fi
	if [ "z${GETURL}" == "z" ] || [ "z${OUTPATH}" == "z" ]; then
		echo "Skipping because empty URL or path: ${OUTPATH} / ${GETURL}"
		return
	fi
	is_stale "${OUTPATH}" "$4"
	if [ $? -ne 0 ]; then
		echo "No update for ${OUTPATH}"
		return
	else
		echo "Need update for ${OUTPATH}"
	fi
	echo "Getting ${OUTPATH}..."
	${CURLCMD} "${GETURL}" -o "${OUTPATH}" 2>/dev/null
}

# Determine if local version needs update from server
# $1: local file
# $2: history URL _expandable.history
is_stale() {
	# if stale, return 0
	# stale means the history URL date is newer than the local file one
	HIST=$(curl --no-progress-meter -u ${CRED} ${CERTFLAGS} "${TLSHOSTPREFIX}$2")
	LU=$(<<<${HIST} jq -r .lastUpdated.when)
	LUT=$(date -d "${LU}" +%s)

	FUT=$(date -r "$1" +%s 2>/dev/null || true)

	if [ "x${FUT}" != "x" ]; then
		echo "File updated: $(date -d @${FUT})"
	fi
	echo "Conf updated: $(date -d @${LUT})"
	if [ "x${FUT}" == "x" ]; then
		echo "Not found, update needed"
		# file not found, return stale
		return 0
	fi

	# if last update time > file update time, it's stale
	if [ ${LUT} -gt ${FUT} ]; then
		echo "Update needed"
		return 0
	else
		echo "No update needed"
	fi
	return 255
}

# Get the PDF version
# $1: page id
# $2: title
# $3: _expandable.history
get_pdf() {
	echo "Getting PDF version of $2, page id $1..."
	mkdir -p data/pdfs
	OUTPATH="data/pdfs/$2.pdf"
	is_stale "${OUTPATH}" "$3"
	if [ $? -eq 0 ]; then
		PHDR="${PDFURL}/pdfpageexport.action?pageId=$1"
		echo "Getting redirect header..."
		HEADERS=$(${CURLCMD} --head "${PHDR}")
		<<<"${HEADERS}" grep -q "HTTP/1.1 302"
		if [ $? -ne 0 ]; then
			echo "No redirect => no PDF."
			return
		fi
		LOC=$(<<<"${HEADERS}" awk '/^Location:/ {print $2}')
		LOC=$(<<<"${LOC}" tr -d '\r\n')
		LOC=${TLSDOMAIN}${LOC}
		echo "Downloading..."
		${CURLCMD} -o "${OUTPATH}" ${LOC}
	else
		echo "No update needed for ${OUTPATH}."
	fi
}

# Download and fix if necessary
# $1: individual search result JSON
get_result() {
	TYPE=$(<<<"$1" jq -r .type)
	TITLE=$(<<<"$1" jq -r .title)
	LINK=$(<<<"$1" jq -r ._links.webui)
	HIST=$(<<<"$1" jq -r ._expandable.history)
	get_if "${TYPE}" "${TITLE}" "${LINK}" "${HIST}"
	if [ "z${TYPE}" == "zpage" ]; then
		fix_css "pages/${TITLE}.html"
		fix_images "pages/${TITLE}.html"
		H=$(<<<${HIST} jq -r ._links.self | cut -c $(<<<${TLSHOSTPREFIX} wc -c)-)
		get_pdf "$(<<<$1 jq -r .id)" "${TITLE}" "${H}"
	fi
	sleep 1
}

# Fix CSS links in HTML file
# $1: partial file path
fix_css() {
	# TODO: parse for CSS and get if needed
	# find very long CSS URL, download it
	# but make a small hash of the URL so Windows won't complain
	# replace link in HTML
	echo "Fixing CSS in $1..."
}

# Fix image links in HTML file
# $1: partial file path
fix_images() {
	# TODO: relink images if needed
	# image URLs aren't so long so no hashing needed
	# adjust link in HTML
	echo "Fixing images in $1..."
}

REMAINING=${TOTAL_SIZE}

while [ ${REMAINING} -gt 0 ] ; do
	START=$(( ${TOTAL_SIZE} - ${REMAINING} ))
	echo Requesting: ${START} Remaining: ${REMAINING}
	PAGE=$(curl --no-progress-meter -u ${CRED} ${CERTFLAGS} \
		"${SEARCHURL}&limit=${PAGE_LIMIT}&start=${START}")
	# Start of loop ^^

	for N in {0..24}; do
		R=$(<<<${PAGE} jq .results[${N}])
		if [ "z${R}" == "znull" ]; then
			echo "End of result set."
			break
		fi
		echo "Getting result #$(( ${START}+${N}+1 ))..."
		get_result "${R}"
	done

	# End of loop vv
	REMAINING=$(( ${REMAINING} - ${PAGE_LIMIT} ))
done
