#!/bin/bash
set -euo pipefail

die() {
	echo $1
	exit 1
}

[ ! -e ./conf ] && die "Config file not found."

. ./conf

CURLCMD="curl --no-progress-meter -u ${CRED} ${CERTFLAGS}"
HEADERFILE="/dev/shm/headers_out"

# You need a page called "My Content" in your space with that widget which gets
# all your pages. Or anything you want, come to think of it. This script will
# save all assets and pages linked by that page. But not comments. Who has time
# for that?
MY_URL="https://cannonst.com/confluence/display/~adam.richardson/My+Content"
[ ! -e content.html ] && ${CURLCMD} "${MY_URL}" 2>/dev/null >content.html

# Gliffies export as image. That'll do.
PAGES=$(grep "Page:</span> *<a href" content.html | cut -c 143- | cut -d\" -f1)
PNGS=$(grep "\.png\?" content.html | grep -v system-content-items | cut -c 18- | cut -d\? -f1)
JPGS=$(grep "\.jpg\?" content.html | grep -v system-content-items | cut -c 18- | cut -d\? -f1)
PDFS=$(grep "\.pdf\?" content.html | cut -c 18- | cut -d\? -f1)
CSSS=$(grep "stylesheet" content.html | cut -c 30- | cut -d\? -f1 | cut -d\" -f1)

ASSETDIR="assets"
PAGEDIR="pages"
PDFDIR="pdfs"

install -d ./${ASSETDIR} -m0755
for PNG in ${PNGS}
do
	echo "Getting ${PNG}..."
	PNGF=${ASSETDIR}/$(<<<"${PNG}" tr '/' '_')
	[ ! -e "${PNGF}" ] && ${CURLCMD} https://cannonst.com${PNG} -o "${PNGF}"
done

for JPG in ${JPGS}
do
	echo "Getting ${JPG}..."
	JPGF=${ASSETDIR}/$(<<<"${JPG}" tr '/' '_')
	[ ! -e "${JPGF}" ] && ${CURLCMD} https://cannonst.com${JPG} -o "${JPGF}"
done

for PDF in ${PDFS}
do
	echo "Getting ${PDF}..."
	PDFF=${ASSETDIR}/$(<<<"${PDF}" tr '/' '_')
	[ ! -e "${PDFF}" ] && ${CURLCMD} https://cannonst.com${PDF} -o "${PDFF}"
done

# BUG: URLs don't always match file paths, there is a missing %25 ('%') wherever
# there is an entity. The URL isn't being HTML-encoded. Confluence bug?
# Workaround: add missing entity?
install -d ./${PAGEDIR} -m0755
install -d ./${PDFDIR} -m0755
for PAGE in ${PAGES}
do
	echo "Getting ${PAGE}..."
	PAGEF=${PAGEDIR}/$(<<<"${PAGE}" tr '/' '_').html
	[ ! -e "${PAGEF}" ] && ${CURLCMD} https://cannonst.com${PAGE} -o "${PAGEF}"
	# relink css
	sed -i -e '/link rel=.stylesheet.*css/s/\//_/g' "${PAGEF}"
	# relink images
	sed -i -e 's:/:_:g; s:<_:</:g; s:_>:/>:g; s:src=":src="../assets/:g' "${PAGEF}"

	echo "Getting ${PAGE} PDF..."

	# get pageID
	PAGEID=""
	ACT=$(<<<"${PAGE}" cut -d/ -f3)
	if [ "x${ACT}" == "xpages" ] ; then
		# looks like: /confluence/pages/viewpage.action?pageId=1234
		PAGEID=$(<<<${PAGE} cut -d= -f2)
	elif [ "x${ACT}" == "xdisplay" ] ; then
		# looks like: /confluence/display/spaceKey/Title
		SPACEKEY=$(<<<${PAGE} cut -d/ -f4)
		TITLE=$(<<<${PAGE} cut -d/ -f5-)
		JSONURL="https://cannonst.com/confluence/rest/api/content?title=${TITLE}&spaceKey=${SPACEKEY}&expand=history"
		JSON=$(${CURLCMD} "${JSONURL}")
		SIZE=$(<<<${JSON} jq .size)
		if [ "x${SIZE}" != "x1" ] ; then
			echo "Ambiguous result, couldn't get PDF."
			continue
		fi
		PAGEID=$(<<<$JSON jq .results[0].id | cut -d\" -f2)
	fi
	if [ "x${PAGEID}" == "x" ] ; then
		echo "Couldn't get page ID --> no PDF."
		continue
	fi
	echo "Page ID: ${PAGEID}"

	# get pdf version of page
	# sed because I stupidly have page titles with "..."
	# which obviously filesystems do not like
	PDFF=${PDFDIR}/$(<<<"${PAGE}" tr '/' '_' | sed -e 's/\.\.\./_/g').pdf
	PDFURL="https://cannonst.com/confluence/spaces/flyingpdf/pdfpageexport.action?pageId=${PAGEID}"
	if [ ! -e "${PDFF}" ] ; then
		${CURLCMD} "${PDFURL}" -D ${HEADERFILE}
		grep -q "HTTP/1.1 302" ${HEADERFILE}
		IS_302=$?
		if [ $IS_302 -ne 0 ] ; then
			echo "No redirect --> no PDF."
			continue
		fi
		LOC="https://cannonst.com$(grep "^Location:" ${HEADERFILE} | cut -c 11- | tr -d '\r\n\f')"
		${CURLCMD} "${LOC}" -o "${PDFF}"
	fi
done

for CSS in ${CSSS}
do
	echo "Getting ${CSS}..."
	CSSF=${PAGEDIR}/$(<<<"${CSS}" tr '/' '_')
	[ ! -e "${CSSF}" ] && ${CURLCMD} https://cannonst.com${CSS} -o "${CSSF}"
done

echo "Making tarball..."
TARDIRS="${ASSETDIR} ${PAGEDIR} ${PDFDIR}"
TARBALL="$(date +%Y%m%d)_confluence_backup.tgz"
[ ! -e "${TARBALL}" ] && tar cpzf "${TARBALL}" ${TARDIRS}
# rm -rf ${TARDIRS}
# rm -f content.html

echo "Done."
