#!/bin/bash
set -euo pipefail

die() {
	echo $1
	exit
}

[ ! -e ./conf ] && die "Config file not found."

. ./conf

CURLCMD="curl --no-progress-meter -u ${CRED} ${CERTFLAGS}"

[ ! -e content.html ] && ${CURLCMD} https://cannonst.com/confluence/display/~adam.richardson/My+Content 2>/dev/null >content.html

# Gliffies export as image. That'll do.
PAGES=$(grep "Page:</span> *<a href" content.html | cut -c 143- | cut -d\" -f1)
PNGS=$(grep "\.png\?" content.html | grep -v system-content-items | cut -c 18- | cut -d\? -f1)
JPGS=$(grep "\.jpg\?" content.html | grep -v system-content-items | cut -c 18- | cut -d\? -f1)
PDFS=$(grep "\.pdf\?" content.html | cut -c 18- | cut -d\? -f1)
CSSS=$(grep "stylesheet" content.html | cut -c 30- | cut -d\? -f1 | cut -d\" -f1)

ASSETDIR="assets"
PAGEDIR="pages"

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

# BUG: URLs don't always match file paths, there is a missing %25 ('%') wherever there is an entity. The URL isn't being HTML-encoded. Confluence bug? Workaround: add missing entity?
install -d ./${PAGEDIR} -m0755
for PAGE in ${PAGES}
do
	echo "Getting ${PAGE}..."
	PAGEF=${PAGEDIR}/$(<<<"${PAGE}" tr '/' '_').html
	[ ! -e "${PAGEF}" ] && ${CURLCMD} https://cannonst.com${PAGE} -o "${PAGEF}"
	# relink css
	sed -i -e '/link rel=.stylesheet.*css/s/\//_/g' "${PAGEF}"
	# relink images
	sed -i -e 's:/:_:g; s:<_:</:g; s:_>:/>:g; s:src=":src="../assets/:g' "${PAGEF}"
done

for CSS in ${CSSS}
do
	echo "Getting ${CSS}..."
	CSSF=${PAGEDIR}/$(<<<"${CSS}" tr '/' '_')
	[ ! -e "${CSSF}" ] && ${CURLCMD} https://cannonst.com${CSS} -o "${CSSF}"
done

TARDIRS="${ASSETDIR} ${PAGEDIR}"
echo "Making tarball..."
TARBALL="$(date +%Y%m%d)_confluence_backup.tgz"
[ ! -e "${TARBALL}" ] && tar cpzf "${TARBALL}" ${TARDIRS}
# rm -rf ${TARDIRS}

echo "Done."
