#!/bin/bash
set -euxo pipefail

die() {
	echo $1
	exit
}

[ ! -e ./conf ] && die "Config file not found."

. ./conf

[ ! -e content.html ] && curl -u ${CRED} https://cannonst.com/confluence/display/~adam.richardson/My+Content ${CERTFLAGS} 2>/dev/null >content.html

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
	PNGF=${ASSETDIR}/$(<<<"${PNG}" tr '/' '_')
	[ ! -e "${PNGF}" ] && curl -u ${CRED} https://cannonst.com${PNG} ${CERTFLAGS} -o "${PNGF}"
done

for JPG in ${JPGS}
do
	JPGF=${ASSETDIR}/$(<<<"${JPG}" tr '/' '_')
	[ ! -e "${JPGF}" ] && curl -u ${CRED} https://cannonst.com${JPG} ${CERTFLAGS} -o "${JPGF}"
done

for PDF in ${PDFS}
do
	PDFF=${ASSETDIR}/$(<<<"${PDF}" tr '/' '_')
	[ ! -e "${PDFF}" ] && curl -u ${CRED} https://cannonst.com${PDF} ${CERTFLAGS} -o "${PDFF}"
done

install -d ./${PAGEDIR} -m0755
for PAGE in ${PAGES}
do
	PAGEF=${PAGEDIR}/$(<<<"${PAGE}" tr '/' '_').html
	[ ! -e "${PAGEF}" ] && curl -u ${CRED} https://cannonst.com${PAGE} ${CERTFLAGS} -o "${PAGEF}"
done

for CSS in ${CSSS}
do
	CSSF=${PAGEDIR}/$(<<<"${CSS}" tr '/' '_')
	[ ! -e "${CSSF}" ] && curl -u ${CRED} https://cannonst.com${PAGE} ${CERTFLAGS} -o "${CSSF}"
done

TARDIRS="${ASSETDIR} ${PAGEDIR}"

# TODO: tar up everything in dated tarball, then delete all
# Manually push to DISX

