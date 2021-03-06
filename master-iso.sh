#!/bin/bash

NAME="ROCK"
VERSION="2.1"
RELEASE="1"
ARCH="x86_64"
KICKSTART="ks.cfg"
KICKSTART_MAN="ks_manual.cfg"
BUILD="1708"
SCRIPT_DIR=$(dirname $(readlink -f $0))
BUILD_LOG="build-$(date +%YT%H%M).log"

SRCISO=$(realpath $1)
OUT_ISO=${1/.iso/-$TIMESTAMP}.iso
[ $# -eq 2 ] && [ ! -z "$2" ] && OUT_ISO=$(realpath $2)

TMP_ISO=$(mktemp -d)
TMP_NEW=$(mktemp -d)
TMP_RPMDB=$(mktemp -d)
TMP_EFIBOOT=$(mktemp -d)

. ./offline-snapshot.sh

cleanup() {
  umount $TMP_ISO 2>/dev/null
  unmount $TMP_EFIBOOT 2>/dev/null
  [ -d ${TMP_ISO} ] && rm -rf ${TMP_ISO}
  [ -d ${TMP_NEW} ] && rm -rf ${TMP_NEW}
  [ -d ${TMP_RPMDB} ] && rm -rf ${TMP_RPMDB}
  [ -d ${TMP_EFIBOOT} ] && rm -rf ${TMP_EFIBOOT}
}

trap cleanup EXIT

check_depends() {
  which mkisofs    # genisoimage
  which flattenks  # pykiskstart
  which createrepo # createrepo
}

usage() {
  echo "Usage: $0 CentOS-7-x86_64-Everything-1611.iso [output.iso]"
  exit 2
}

if [ $# -lt 1 ] || [ -z "$1" ]; then usage; fi

die() { echo "ERROR: $@" >&2 ; exit 2 ; }
cond_out() { "$@" 2>&1 | tee -a ${BUILD_LOG} > .tmp.log 2>&1 || { cat .tmp.log >&2 ; die "Failed to run $@" ; } && rm .tmp.log || : ; return $? ; }

extract_iso() {
  echo "[1/4] Extracting ISO"

  # Might want to comment this out if you're sure of your ISO
  #cond_out checkisomd5 --verbose ${SRCISO}

  ## This approach doesn't require root, but it was truncating filenames :-(
  # local ISOFILES=$(isoinfo -i ${SRCISO} -RJ -f | sort -r | egrep "/.*/")
  # for F in ${ISOFILES}
  # do
  #   mkdir -p ${TMP_NEW}/$(dirname $F)
  #   [[ -d ${TMP_NEW}/.$F ]] || { isoinfo -i ${SRCISO} -RJ -x $F > ${TMP_NEW}/.$F ; }
  # done

  # Mount existing iso and copy to new dir
  cond_out mount -o loop -t iso9660 "${SRCISO}" ${TMP_ISO}
  cond_out rsync --recursive --exclude=Packages --exclude=repodata ${TMP_ISO}/ ${TMP_NEW}/
  cond_out mkdir -p ${TMP_NEW}/repodata
  cond_out cp $(ls ${TMP_ISO}/repodata/*comps*.xml | head -1 ) ${TMP_NEW}/repodata/comps.xml
  cond_out umount ${TMP_ISO}

  # Remove TRANS files
  find ${TMP_NEW} -name TRANS.TBL -delete

}

download_content() {
  echo "[2/4] Downloading offline snapshot."

  # Download offline-snapshot
  cond_out offline-snapshot
}

add_content() {
  echo "[3/4] Adding content"

  # Add new isolinux & grub config
  read -r -d '' template_json <<EOF
{
  "name": "${NAME}",
  "version": "${VERSION}",
  "arch": "${ARCH}",
  "kickstart": "${KICKSTART}",
  "kickstart_man": "${KICKSTART_MAN}",
  "build": "${BUILD}"
}
EOF

  echo ${template_json} | \
    py 'jinja2.Template(open("isolinux.cfg.j2").read()).render(json.loads(sys.stdin.read()))' | \
    cat - > ${TMP_NEW}/isolinux/isolinux.cfg

  echo ${template_json} | \
    py 'jinja2.Template(open("grub.cfg.j2").read()).render(json.loads(sys.stdin.read()))' | \
    cat - > ${TMP_NEW}/EFI/BOOT/grub.cfg

  # Update efiboot img
  cond_out mount -o loop ${TMP_NEW}/images/efiboot.img ${TMP_EFIBOOT}
  cond_out cp ${TMP_NEW}/EFI/BOOT/grub.cfg ${TMP_EFIBOOT}/EFI/BOOT/grub.cfg
  cond_out umount ${TMP_EFIBOOT}

  # Copy boot splash branding
  cond_out cp ${SCRIPT_DIR}/images/splash_rock.png ${TMP_NEW}/isolinux/splash.png

  # Generate product image
  cd ${SCRIPT_DIR}/product
  find . | cpio -c -o | gzip -9cv > ../product.img
  cd ${SCRIPT_DIR}
  mkdir -p ${TMP_NEW}/images
  cp product.img ${TMP_NEW}/images/

  # Sync over offline content
  cond_out rsync --recursive --quiet ${ROCK_CACHE_DIR}/ ${TMP_NEW}/

  # Create new repo metadata
  cond_out createrepo -g ${TMP_NEW}/repodata/comps.xml ${TMP_NEW}

  # Generate flattened manual kickstart & add pre-inst hooks
  cond_out ksflatten -c ks/install.ks -o "${TMP_NEW}/${KICKSTART}"
  cat <<EOF >> "${TMP_NEW}/${KICKSTART}"

# This seems to get removed w/ ksflatten
%addon com_redhat_kdump --disable
%end
EOF

  # Generate flattened automated kickstart & add pre-inst hooks
  cond_out ksflatten -c ks/manual.ks -o "${TMP_NEW}/${KICKSTART_MAN}"
  cat <<EOF >> "${TMP_NEW}/${KICKSTART_MAN}"

# This seems to get removed w/ ksflatten
%addon com_redhat_kdump --disable
%end
EOF

}

create_iso() {

  echo "[4/4] Creating new ISO"

  local _build_dir="${TMP_NEW}"
  local _iso_fname="${OUT_ISO}"
  local _volid="${NAME} ${VERSION} ${ARCH}"

  cond_out echo "Dumping tree listing"
  cond_out tree ${_build_dir}

  cond_out /usr/bin/mkisofs -J \
    -translation-table \
    -untranslated-filenames \
    -joliet-long \
    -o ${_iso_fname} \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e images/efiboot.img \
    -no-emul-boot \
    -rock \
    -rational-rock \
    -graft-points \
    -appid "${_volid}" \
    -V "${_volid}" \
    ${_build_dir}

  cond_out isohybrid --uefi ${_iso_fname}
  cond_out implantisomd5 --force ${_iso_fname}
}

main() {

  extract_iso
  download_content
  add_content
  create_iso

}

main
