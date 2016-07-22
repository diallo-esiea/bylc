#!/bin/bash -xv

CAT=/bin/cat
CHMOD=/bin/chmod
CP=/bin/cp
ECHO=/bin/echo
LN=/bin/ln
MKDIR=/bin/mkdir
MOUNT=/bin/mount
PRINTF=printf
PWD=/bin/pwd
RM=/bin/rm
SED=/bin/sed
TAR=/bin/tar
UMOUNT=/bin/umount

BLKID=/sbin/blkid
VGCHANGE=/sbin/vgchange

AWK=/usr/bin/awk
CHPASSWD=/usr/sbin/chpasswd
CHROOT=/usr/sbin/chroot
DEBOOTSTRAP=/usr/sbin/debootstrap
DPKG_DEB=/usr/bin/dpkg-deb
DPKG_RECONFIGURE=/usr/sbin/dpkg-reconfigure
FAKECHROOT=/usr/bin/fakechroot
FIND=/usr/bin/find
GIT=/usr/bin/git
GPG=/usr/bin/gpg
LOCALE_GEN=/usr/sbin/locale-gen
LOCALE_UPDATE=/usr/sbin/update-locale
MAKE=/usr/bin/make
WGET=/usr/bin/wget

NB_CORES=$(grep -c '^processor' /proc/cpuinfo)

# Default value 
ARCH=amd64
DEST_PATH=bycl
LXC_VERSION=2.0.0
MIRROR=http://ftp.fr.debian.org/debian
SUITE=unstable
TMP_PATH=/tmp
VARIANT=minbase     # minbase, buildd, fakechroot, scratchbox

USAGE="$(basename "${0}") [options] <COMMAND> DEVICE\n\n
\tDEVICE\tTarget device or path name\n\n
\tCOMMAND:\n
\t--------\n
\t\tinstall\tInstall lxc\n
\t\tupdate\tUpdate lxc container\n\n
\tinstall options:\n
\t----------------\n
\t\t-a=NAME, --variant=NAME\tName of the variant (minbase, buildd, fakeroot, scratchbox,...) (default=${VARIANT})\n\n
\t\t-g=PATH, --git=PATH\tGit path to get the lxc archive\n
\t\t-l=PATH, --local=PATH\tPath to get the lxc archive (instead of official LXC Archives URL)\n
\t\t-m=PATH, --mirror=PATH\tCan be an http:// URL, a file:/// URL, or an ssh:/// URL (default=${MIRROR})\n
\t\t-n, --nodelete\t\tKeep temporary files\n
\t\t-p=PATH, --path=PATH\tPath to install system (default=${DEST_PATH})\n
\t\t-s=NAME, --suite=NAME\tName of the suite (lenny, squeeze, sid,...) (default=${SUITE})\n\n
\t\t-t=PATH, --temp=PATH\tTemporary folder (default=${TMP_PATH})\n\n
\t\t-v=VERSION, --version=VERSION\tVersion of lxc (default=${LXC_VERSION})\n\n
\tupdate options:\n
\t---------------\n
\toptions:\n
\t--------\n
\t\t-d, --deb\t\tCreate Debian package archive\n
\t\t-f=FILE, --file=FILE\tConfiguration file\n
\t\t-h, --help\t\tDisplay this message\n\n
\t\t-r=NAME, --arch=NAME\tArchitecture name (i386, arm, amd64,...) (default=${ARCH})"

#########################################
# Print help
#########################################
print_help() {
  ${ECHO} -e ${USAGE}
}

#########################################
# Parse command line and manage options 
#########################################
parse_command_line() {
  for i in "$@"; do
    case ${i} in
      -a=*|--variant=*)
        VARIANT="${i#*=}"
        shift
        ;;
  
      -d|--deb)
        DEB=1
        shift
        ;;
  
      -f=*|--file=*)
        # Convert relative path to absolute path
        if [[ ${i#*=} != /* ]]; then
          FILE=`${PWD}`/${i#*=}
        else
          FILE="${i#*=}"
        fi
  
        if [ ! -f ${FILE} ]; then
          ${ECHO} "File ${FILE} does not exists"
          return 1
        fi
  
        # Parse configuration file
        source ${FILE}
        shift
        ;;
  
      -g=*|--git=*)
        GIT_PATH="${i#*=}"
        shift
        ;;
  
      -l=*|--local=*)
        LXC_PATH="${i#*=}"
        shift
        ;;
  
      -n|--nodelete)
        NO_DELETE=1
        shift
        ;;
  
      -p=*|--path=*)
        DEST_PATH="${i#*=}"
        shift
        ;;
  
      -r=*|--arch=*)
        ARCH="${i#*=}"
        shift
        ;;
  
      -t=*|--temp=*)
        TMP_PATH="${i#*=}"
        shift
        ;;
  
      -v=*|--version=*)
        LXC_VERSION="${i#*=}"
        shift
        ;;
  
      -h|--help|-*|--*) # help or unknown option
        print_help
        return 1
        ;;

    esac
  done
  
  if [ $# -eq  2 ] && ([ "${1}" == "install" ] || [ "${1}" == "update" ]); then
    COMMAND=${1}
    DEVICE=${2}
  else
    print_help
    return 1
  fi

  # Convert relative path to absolute path
  for i in DEST_PATH GIT_PATH LXC_PATH TMP_PATH; do 
    if [[ -n "${!i}" ]] && [[ ${!i} != /* ]]; then
      eval ${i}=`${PWD}`/${!i}
    fi
  done

  return 0
}

#########################################
# Get filesystem table from fstab file
#########################################
get_filesystem_table() {
  # Read fstab file
  while read fstab; do
    case ${fstab} in
      \#*) 
        continue 
        ;;
  
      UUID=*)
        IFS=$' \t' read uuid mount type options dump pass <<< "${fstab}"
        device=$(${BLKID} -U ${uuid#UUID=})
        ;;
  
      /dev/*)
        IFS=$' \t' read device mount type options dump pass <<< "${fstab}"
        ;;
  
      *)
        continue 
        ;;
  
    esac
  
    # Fill filesystem table FSTAB
    if [[ ${mount} == / ]]; then
      FSTAB=("${device} ${mount} ${type} ${options} ${dump} ${pass}" "${FSTAB[@]}")
      continue
    elif [[ ${device} =~ ^/* ]]; then 
      FSTAB=("${FSTAB[@]}" "${device} ${mount} ${type} ${options} ${dump} ${pass}")
    fi
  done < ${DEST_PATH}/etc/fstab
}

#########################################
# Build LXC
#########################################
build_lxc() {
  pushd ${TMP_PATH} > /dev/null || exit 1
  
  if [ -n "${GIT_PATH}" ]; then
    pushd ${GIT_PATH} > /dev/null || exit 1
    
    # Remove untracked directories and untracked files
    ${GIT} clean -d --force --quiet 
  
    # Checkout a branch version
    ${GIT} checkout lxc-${LXC_VERSION}
  else
    LXC_NAME=lxc-${LXC_VERSION}
    LXC_TAR=${LXC_NAME}.tar
    
    if [ -n "${LXC_PATH}" ]; then
      # Check if lxc version exists
      if [ ! -f ${LXC_PATH}/${LXC_TAR}.gz ]; then
        ${ECHO} "Lxc version does not exist" >&2
        return 1
      fi
    
      # Decompress lxc archive
      ${TAR} -zxf ${LXC_PATH}/${LXC_TAR}.gz -C ${TMP_PATH}
    else
      # Lxc branch url and target files
      LXC_URL=https://linuxcontainers.org/downloads/lxc
      
      # Check if BOTH lxc version AND signature file exist
      ${WGET} -c --spider ${LXC_URL}/${LXC_TAR}.{gz.asc,gz}
      
      if [ $? -ne 0 ]; then
        ${ECHO} "Lxc version does not exist" >&2
        return 1
      fi
      
      # Download lxc AND signature
      ${WGET} -c ${LXC_URL}/${LXC_TAR}.{gz.asc,gz}
    
      # Initialize GPG keyrings
      ${PRINTF} "" | ${GPG}
      
      # Download GPG keys
      GPG_KEYSERVER=keyserver.ubuntu.com 
      GPG_KEY=`${GPG} --verify ${LXC_TAR}.gz.asc 2>&1 | \
               ${AWK} '{print $NF}' | \
               ${SED} -n '/\([0-9]\|[A-H]\)$/p' | \
               ${SED} -n '1p'`
      ${GPG} --keyserver ${GPG_KEYSERVER} --recv-keys ${GPG_KEY}
      
      # Verify lxc archive against signature file
      ${GPG} --verify ${LXC_TAR}.gz.asc
    
      # Decompress lxc archive
      ${TAR} -zxf ${LXC_TAR}.gz -C ${TMP_PATH}
    fi
  
    pushd ${TMP_PATH}/${LXC_NAME} > /dev/null || exit 1
  fi
  
  # Define install folder
  if [ -n "${DEB}" ]; then
    INSTALL_PATH=${TMP_PATH}/lxc
  else
    INSTALL_PATH=${DEST_PATH}
  fi
 
  # Set lxc configuration
  CONFIGURE_OPTS="--disable-doc
                  --disable-api-docs
                  --disable-examples
                  --with-init-script=systemd
                  --prefix=${INSTALL_PATH}
                  --with-systemdsystemunitdir=${INSTALL_PATH}/lib/systemd/system"
  ./configure ${CONFIGURE_OPTS}

  # Build and install lxc
  ${MKDIR} -p ${INSTALL_PATH}
  ${MAKE} --jobs=$((NB_CORES+1)) --load-average=${NB_CORES}
  ${MAKE} install
  
  popd > /dev/null
  
  # Create Debian package 
  if [ -n "${DEB}" ]; then
    ${MKDIR} -p lxc/DEBIAN
      
    ${CAT} > lxc/DEBIAN/control << EOF
Package: lxc 
Version: ${LXC_VERSION}
Section: admin
Priority: optional
Architecture: amd64
Maintainer: David DIALLO
Description: Linux Containers userspace tools
 This package provides the lxc-* tools, which can be used to start a single
 daemon in a container.
EOF
      
    ${DPKG_DEB} --build lxc
      
    # Copy Debian package 
    ${CP} lxc.deb ${DEST_PATH}
  
    ## Delete Debian package and install folder
    if [ -z "${NO_DELETE}" ]; then
      ${RM} lxc.deb
      ${RM} -rf lxc
    fi
  fi
  
  # Delete temporary files
  if [ -z "${NO_DELETE}" ]; then
    # Delete lxc archive and decompressed lxc archive
    if [ -z "${GIT_PATH}" ] && [ -z "${LXC_PATH}"]; then
      ${RM} ${LXC_TAR}.{gz.asc,gz}
    fi
  
    ${RM} -rf ${LXC_NAME}
  fi
  
  popd > /dev/null

  return 0
}

#########################################
# Build distribution (system)
#########################################
build_system() {
  # Add and remove packages
  EXCLUDE=
  INCLUDE=,systemd,systemd-sysv,locales
  
  # Install Debian base system
  DEBOOTSTRAP_OPTIONS="--arch=${ARCH} --include=${INCLUDE} --variant=${VARIANT}"
  if [ -n "${EXCLUDE}" ]; then
    DEBOOTSTRAP_OPTIONS="${DEBOOTSTRAP_OPTIONS} --exclude=${EXCLUDE}"
  fi
  ${FAKECHROOT} fakeroot ${DEBOOTSTRAP} ${DEBOOTSTRAP_OPTIONS} ${SUITE} ${DEST_PATH} ${MIRROR}
  if [ $? -ne 0 ]; then
    return 1
  fi

  # Remplace symbolic link
  IFS=$'\n'
  LINKS=$(${FIND} ${DEST_PATH} -type l -lname "${DEST_PATH}*" -printf "%l\t%p\n")
  for link in ${LINKS}; do
    IFS=$' \t' read path name <<< "$link"
    ${LN} -sfn ${path#${DEST_PATH}*} ${name}
  done
 
  # Set the hostname
  ${ECHO} ${HOSTNAME} > ${DEST_PATH}/etc/hostname
  
  # Binding the virtual filesystems
  ${MOUNT} --bind /dev ${DEST_PATH}/dev
  ${MOUNT} -t proc none ${DEST_PATH}/proc
  ${MOUNT} -t sysfs none ${DEST_PATH}/sys

  # Create "chroot" script
  ${CAT} > ${DEST_PATH}/chroot.sh << EOF
#!/bin/bash
# Configure locale
${SED} -i "s/^# fr_FR/fr_FR/" /etc/locale.gen
${LOCALE_GEN}
${LOCALE_UPDATE} LANG=fr_FR.UTF-8

# Configure timezone
${ECHO} "Europe/Paris" > /etc/timezone    
${DPKG_RECONFIGURE} --frontend=noninteractive tzdata

# Create a password for root
${ECHO} root:${ROOT_PASSWD} | ${CHPASSWD}

# Quit the chroot environment
exit
EOF
  ${CHMOD} +x ${DEST_PATH}/chroot.sh
  
  # Entering the chroot environment
  ${CHROOT} ${DEST_PATH} ./chroot.sh 
  
  # Remove "chroot" script
  ${RM} ${DEST_PATH}/chroot.sh

  # Unbinding the virtual filesystems
  ${UMOUNT} ${DEST_PATH}/{dev,proc,sys}

  return 0  
}

#########################################
# Main function
#########################################
parse_command_line $@
if [ $? -ne 0 ]; then
  exit 1
fi

# Create DEST_PATH if not exists 
${MKDIR} -p ${DEST_PATH}
  
## Mount rootfs partition
#if [ -n "${VGNAME}" ]; then
#  # Activate Volume Group (LVM)
#  ${VGCHANGE} -a y ${VGNAME}
#
#  ${MOUNT} /dev/mapper/${VGNAME}-root ${DEST_PATH}
#else
#  ${MOUNT} $(${BLKID} -L root) ${DEST_PATH}
#fi
#
## Check if rootfs partition mounted succeeded
#if [ $? -ne 0 ]; then
#  exit 1   
#fi
#
## Reset FSTAB
#unset FSTAB
#  
## Get filesystem table
#get_filesystem_table
#if [ $? -ne 0 ]; then
#  exit 1
#fi
#
## Umount rootfs partition
#${UMOUNT} ${DEST_PATH}
#
## Mount all others partitions
#for fstab in "${FSTAB[@]}"; do
#  IFS=$' \t' read device mount type options dump pass uuid <<< "${fstab}"
#  
#  if [[ ${mount} =~ ^/$ ]]; then
#    ${MKDIR} -p ${DEST_PATH}${mount}
#    ${MOUNT} ${device} ${DEST_PATH}${mount}
#  fi
#done
  
# Build and install lxc
build_lxc
if [ $? -ne 0 ]; then
  exit 1   
fi

# Build root filesystem of guest
if [ "${COMMAND}" == "install" ] && [ -z "${DEB}" ]; then
  # Set HOSTNAME and root password of guest
  HOSTNAME=lxc
  ROOT_PASSWD=root

  # Update DEST_PATH
  DEST_PATH=${DEST_PATH}/var/lib/lxc/rootfs
  ${MKDIR} -p ${DEST_PATH}
  build_system
  if [ $? -ne 0 ]; then
    exit 1   
  fi
fi

## Binding the virtual filesystems
#${MOUNT} --bind /dev ${DEST_PATH}/dev
#${MOUNT} -t proc none ${DEST_PATH}/proc
#${MOUNT} -t sysfs none ${DEST_PATH}/sys
#
## Create "chroot" script
#${CAT} >> ${DEST_PATH}/chroot.sh << EOF
##!/bin/bash
#
## Quit the chroot environment
#exit
#EOF
#${CHMOD} +x ${DEST_PATH}/chroot.sh
#
## Entering the chroot environment
#${CHROOT} ${DEST_PATH} ./chroot.sh 
#
## Remove "chroot" script
#${RM} ${DEST_PATH}/chroot.sh
#
## Unbinding the virtual filesystems
#${UMOUNT} ${DEST_PATH}/{dev,proc,sys}
#
## Umount all partitions
#for (( index=${#FSTAB[@]}-1 ; index>=0 ; index-- )) ; do
#  IFS=$' \t' read device mount type options dump pass <<< "${FSTAB[index]}"
#
#  ${UMOUNT} ${DEST_PATH}${mount}
#done
#
## Deactivate Volume Group (LVM)
#if [ -n "${VGNAME}" ]; then
#  ${VGCHANGE} -a n ${VGNAME}
#fi

exit 0
