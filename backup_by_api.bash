#!/bin/bash
set -euo pipefail

[ ! -e ./conf ] && die "Config file not found."

. ./conf

# only get stuff mod'd since this date
# set to empty string to get everything ever
MODIFIED_SINCE="2024-06-01"

# Required in conf file...
# CRED="confuser:confpass"
# CERTFLAGS="--cert ~me/user-certificates/user.crt --key \
# ~me/user-certificates/my.key --cert-type pem"
# HOSTPREFIX="server.com/confluence"

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

EXTRA_TERMS="&includeArchivedSpaces=true"
SEARCHURL="${APIURL}/content/search?cql=${CQL_QUERY}${EXTRA_TERMS}"

P1=$(curl --no-progress-meter -u ${CRED} ${CERTFLAGS} "${SEARCHURL}")

TOTAL_SIZE=$(<<<"${P1}" jq .totalSize)
PAGE_LIMIT=$(<<<"${P1}" jq .limit)

DATA_DIRS="assets pages pdfs"

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
get_if() {
	OUTPATH=""
	GETURL=""
	if [ "z$1" == "zattachment" ]; then
		OUTPATH="assets/$2"
		GETURL="$3"
		<<<"${GETURL}" grep -q "preview="
		[ $? -eq 0 ] && GETURL=$(
			VAL=$(<<<${GETURL} awk -F[\?=] '{print $3}' \
				| sed -e 's:%2F:/:g')
			GETURL="${ASSETURL}${VAL}"
			echo $GETURL
		)
	else
		OUTPATH="pages/$2.html"
		GETURL="${TLSHOSTPREFIX}$3"
		#echo $GETURL
	fi
	if [ -e "${OUTPATH}" ]; then
		echo "Skipping because already got: ${OUTPATH}"
		return
	fi
	if [ "z${GETURL}" == "z" ] || [ "z${OUTPATH}" == "z" ]; then
		echo "Skipping because empty URL or path: ${OUTPATH}"
		return
	fi
	echo "Getting ${OUTPATH}..."
	${CURLCMD} "${GETURL}" -o "${OUTPATH}" 2>/dev/null
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

# Get the PDF version
# $1: page id
# $2: title
get_pdf() {
	echo "Getting PDF version of $2, page id $1..."
	OUTPATH="pdfs/$2.pdf"
	if [ ! -e "${OUTPATH}" ]; then
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
		echo "Already got."
	fi
}

# Download and fix if necessary
# $1: individual search result JSON
get_result() {
	TYPE=$(<<<"$1" jq -r .type)
	TITLE=$(<<<"$1" jq -r .title)
	LINK=$(<<<"$1" jq -r ._links.webui)
	get_if  "${TYPE}" "${TITLE}" "${LINK}"
	if [ "z${TYPE}" == "zpage" ]; then
		fix_css "pages/${TITLE}.html"
		fix_images "pages/${TITLE}.html"
		get_pdf "$(<<<$1 jq -r .id)" "${TITLE}"
	fi
	sleep 1
}

install -d ${DATA_DIRS}

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

echo "Making tarball..."
TARBALL="$(date +%Y%m%d)_confluence_backup.tgz"
[ ! -e "${TARBALL}" ] && tar cpzf "${TARBALL}" ${DATA_DIRS}

echo "Making zipfile..."
ZIPFILE="$(date +%Y%m%d)_confluence_backup.zip"
[ ! -e "${ZIPFILE}" ] && zip -T -r "${ZIPFILE}" ${DATA_DIRS}

#rm -r ${DATA_DIRS}
