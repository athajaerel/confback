#!/bin/bash
set -euo pipefail

[ ! -e ./conf ] && die "Config file not found."

. ./conf

# Required in conf file...
# CRED="confuser:confpass"
# CERTFLAGS="--cert ~me/user-certificates/me-cannonst.crt --key \
# ~me/user-certificates/me-cannonst.key --cert-type pem"

CURLCMD="curl --no-progress-meter -u ${CRED} ${CERTFLAGS}"
HEADERFILE="/dev/shm/confluence_pdf_download_headers"
DOMAIN="cannonst.com"

# You need a page called "My Content" in your space with that widget
# which gets all your pages. Or anything you want, come to think of it.
# This script will save all assets and pages linked by that page. But
# not comments. Who has time for that?
MY_PAGE="My+Content"

APIURL="https://${DOMAIN}/confluence/rest/api"
PDFURL="https://${DOMAIN}/confluence/spaces/flyingpdf"

NOPE="system-content-items"
ASSETDIR="assets"
PAGEDIR="pages"
PDFDIR="pdfs"

CSS_REGEX="/link rel=.stylesheet.*css/s/\//_/g"
IMG_REGEX="s:/:_:g;s:<_:</:g;s:_>:/>:g;s:src=\":src=\"../assets/:g"

# Exit script with error message
# $1: error message
die() {
	echo $1
	exit 1
}

# Get URL if not existing already
# $1: URL
# $2: local file
get_if() {
	if [ ! -e $2 ]; then
		${CURLCMD} "$1" -o $2 2>/dev/null
	fi
}

# Re-link links in HTML by means of regex
# $1: regex
# $2: page file
relink() {
	#echo sed -i -e "$1" "$2"
	sed -i -e "$1" "$2"

	# BUG: URLs don't always match file paths, there is a missing
	# %25 ('%') wherever there is an entity. The URL isn't being
	# HTML-encoded. Confluence bug? Workaround: add missing entity?
	# No good; somehow we get two copies of the 25. :(
	# Modify the filenames instead?
	sed -i -e "s:%:%25:g" "$2"
}

# Get page ID from URL, or download it
# $1: action (pages or display, currently)
# Return: page ID or null string
get_page_id() {
	if [ "x$1" == "xpages" ] ; then
		# PAGE looks like:
		# /confluence/pages/viewpage.action?pageId=123
		echo $(<<<${PAGE} cut -d= -f2)
	elif [ "x$1" == "xdisplay" ] ; then
		# PAGE looks like:
		# /confluence/display/spaceKey/Title
		SPACEKEY=$(<<<${PAGE} cut -d/ -f4)
		TITLE=$(<<<${PAGE} cut -d/ -f5-)
		QUERY="title=${TITLE}&spaceKey=${SPACEKEY}"
		QUERY="${QUERY}&expand=history"
		JSON=$(${CURLCMD} "${APIURL}/content?${QUERY}")
		SIZE=$(<<<${JSON} jq .size)
		if [ "x${SIZE}" != "x1" ] ; then
			return
		fi
		echo $(<<<$JSON jq .results[0].id | cut -d\" -f2)
	fi
}

# Export and download the PDF version of the page, if not present
# $1: page ID
# $2: local PDF file
download_pdf() {
	echo "Getting $1..."
	PDFHDR="${PDFURL}/pdfpageexport.action?pageId=$1"
	echo "Getting headers from ${PDFHDR}..."
	${CURLCMD} >/dev/null "${PDFHDR}" -D ${HEADERFILE}
	grep -q "HTTP/1.1 302" ${HEADERFILE}
	if [ $? -ne 0 ] ; then
		echo "No redirect --> no PDF."
		return
	fi
	AWK_PROG="/^Location:/ {print \$2}"
	PLOC=$(awk "${AWK_PROG}" "${HEADERFILE}" | tr -d '\r\n')
	LOC="https://${DOMAIN}${PLOC}"
	${CURLCMD} "${LOC}" -o "$2"
}

# Clip out interesting items using awk
# $1: file extension
# $2: input file
awk_clip() {
	awk -F[\"\?] '/.'$1'\?/&&!/system-content-items/ {print $2}' $2
}

MY_USER=$(<<<${CRED} cut -d: -f1)
MY_URL="https://${DOMAIN}/confluence/display/~${MY_USER}/${MY_PAGE}"
echo "Getting ${MY_URL}..."
get_if "${MY_URL}" "./content.html"

# Gliffies export as image. That'll do.
PAGES=$(awk -F\" '/Page:<\/span> *<a href/ { print $6 }' content.html)
PNGS=$(awk_clip "png" "content.html")
JPGS=$(awk_clip "jpg" "content.html")
PDFS=$(awk_clip "pdf" "content.html")
CSSS=$(awk -F[\"\?] '/stylesheet/ {print $4}' content.html)

install -m0755 -d ./${ASSETDIR}
for PNG in ${PNGS}
do
	echo "Getting ${PNG}..."
	PNGF=${ASSETDIR}/$(<<<"${PNG}" tr '/' '_')
	get_if "https://${DOMAIN}${PNG}" "${PNGF}"
done

for JPG in ${JPGS}
do
	echo "Getting ${JPG}..."
	JPGF=${ASSETDIR}/$(<<<"${JPG}" tr '/' '_')
	get_if "https://${DOMAIN}${JPG}" "${JPGF}"
done

for PDF in ${PDFS}
do
	echo "Getting ${PDF}..."
	PDFF=${ASSETDIR}/$(<<<"${PDF}" tr '/' '_')
	get_if "https://${DOMAIN}${PDF}" "${PDFF}"
done

install -m0755 -d ./${PAGEDIR}
install -m0755 -d ./${PDFDIR}
for PAGE in ${PAGES}
do
	echo "Getting ${PAGE}..."
	PAGEF=${PAGEDIR}/$(<<<"${PAGE}" tr '/' '_').html
	get_if "https://${DOMAIN}${PAGE}" "${PAGEF}"
	relink "${CSS_REGEX}" "${PAGEF}"
	relink "${IMG_REGEX}" "${PAGEF}"
	echo "Getting ${PAGE} PDF..."
	# get pdf version of page
	PDFF=${PDFDIR}/$(<<<"${PAGE}" tr '/' '_').pdf
	if [ ! -e ${PDFF} ] ; then
		# get pageID
		ACT=$(<<<"${PAGE}" cut -d/ -f3)
		PAGEID=$(get_page_id "${ACT}")
		if [ "x${PAGEID}" == "x" ] ; then
			echo "Couldn't get page ID --> no PDF."
			continue
		fi
		echo "Page ID: >${PAGEID}<"
		download_pdf "${PAGEID}" "${PDFF}"
	else
		echo "Already present. Moving on."
		continue
	fi
done

for CSS in ${CSSS}
do
	echo "Getting ${CSS}..."
	CSSF=${PAGEDIR}/$(<<<"${CSS}" tr '/' '_')
	get_if "https://${DOMAIN}${CSS}" "${CSSF}"
done

echo "Making tarball..."
TARDIRS="${ASSETDIR} ${PAGEDIR} ${PDFDIR}"
TARBALL="$(date +%Y%m%d)_confluence_backup.tgz"
[ ! -e "${TARBALL}" ] && tar cpzf "${TARBALL}" ${TARDIRS}
rm -rf ${TARDIRS}
rm -f content.html ${HEADERFILE}

echo "Done."
