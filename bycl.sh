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
FIND=/usr/bin/find
GIT=/usr/bin/git
GPG=/usr/bin/gpg
LOCALE_GEN=/usr/sbin/locale-gen
LOCALE_UPDATE=/usr/sbin/update-locale
MAKE=/usr/bin/make
WGET=/usr/bin/wget

NB_CORES=$(grep -c '^processor' /proc/cpuinfo)

# Default value 
DEST_PATH=bycl
LXC_VERSION=2.0.0
TMP_PATH=/tmp

USAGE="$(basename "${0}") [options] <COMMAND> DEVICE\n\n
\tDEVICE\tTarget device or path name\n\n
\tCOMMAND:\n
\t--------\n
\t\tinstall\tInstall lxc\n
\t\tupdate\tUpdate lxc container\n\n
\tinstall options:\n
\t--------------\n
\t\t-d, --deb\t\tCreate Debian package archive\n
\t\t-g=PATH, --git=PATH\tGit path to get the lxc archive\n
\t\t-l=PATH, --local=PATH\tPath to get the lxc archive (instead of official LXC Archives URL)\n
\t\t-p=PATH, --path=PATH\tPath to install system (default=${DEST_PATH})\n
\t\t-t=PATH, --temp=PATH\tTemporary folder (default=${TMP_PATH})\n\n
\t\t-v=VERSION, --version=VERSION\tVersion of lxc (default=${LXC_VERSION})\n\n
\tupdate options:\n
\t--------------\n
\t\t-d, --deb\t\tCreate Debian package archive\n\n
\toptions:\n
\t--------\n
\t\t-f=FILE, --file=FILE\tConfiguration file\n
\t\t-h, --help\t\tDisplay this message"

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
      -d|--deb)
        DEB=1
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
  
      -p=*|--path=*)
        DEST_PATH="${i#*=}"
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
  
  ## Define and create output directory
  #KBUILD_OUTPUT=${TMP_PATH}/kernel-build-${KERNEL_VERSION}
  #${MKDIR} -p ${KBUILD_OUTPUT}
    
  # Define install folder
  if [ -n "${DEB}" ]; then
    INSTALL_PATH=${TMP_PATH}/lxc-deb-${LXC_VERSION}
  else
    INSTALL_PATH=${DEST_PATH}
  fi
 
  # Set lxc configuration
  CONFIGURE_OPTS="--disable-doc --disable-api-docs --disable-examples --with-init-script=systemd --prefix=${INSTALL_PATH}"
  ./configure ${CONFIGURE_OPTS}

  # Build and install lxc
  ${MKDIR} -p ${INSTALL_PATH}
  ${MAKE} --jobs=$((NB_CORES+1)) --load-average=${NB_CORES}
  ${MAKE} install
  
  popd > /dev/null
#  
#  # Create Debian package 
#  if [ -n "${DEB}" ]; then
#    ${MKDIR} -p kernel-${KERNEL_VERSION}/DEBIAN
#      
#    ${CAT} > kernel-${KERNEL_VERSION}/DEBIAN/control << EOF
#Package: kernel
#Version: ${KERNEL_VERSION}
#Section: kernel
#Priority: optional
#Essential: no
#Architecture: amd64
#Maintainer: David DIALLO
#Provides: linux-image
#Description: Linux kernel, version ${KERNEL_VERSION}
#This package contains the Linux kernel, modules and corresponding other
#files, version: ${KERNEL_VERSION}
#EOF
#      
#    ${CAT} > kernel-${KERNEL_VERSION}/DEBIAN/postinst << EOF
#rm -f /boot/initrd.img-${KERNEL_VERSION}
#update-initramfs -c -k ${KERNEL_VERSION}
#EOF
#      
#    ${CAT} > kernel-${KERNEL_VERSION}/DEBIAN/postrm << EOF
#rm -f /boot/initrd.img-${KERNEL_VERSION}
#EOF
#     
#    ${CAT} > kernel-${KERNEL_VERSION}/DEBIAN/triggers << EOF
#interest update-initramfs
#EOF
#      
#    ${CHMOD} 755 kernel-${KERNEL_VERSION}/DEBIAN/postinst kernel-${KERNEL_VERSION}/DEBIAN/postrm
#      
#    ${FAKEROOT} ${DPKG_DEB} --build kernel-${KERNEL_VERSION}
#      
#    # Copy Debian package 
#    ${CP} kernel-${KERNEL_VERSION}.deb ${DEST_PATH}
#  
#    # Delete Debian package and install folder
#    if [ -z "${NO_DELETE}" ]; then
#      ${RM} kernel-${KERNEL_VERSION}.deb
#      ${RM} -rf kernel-${KERNEL_VERSION}
#    fi
#  fi
#  
#  # Delete temporary files
#  if [ -z "${NO_DELETE}" ]; then
#    # Delete kernel archive and decompressed kernel archive
#    if [ -n "${GIT_PATH}" ]; then
#      ${RM} ${KERNEL_TAR}
#      ${RM} ${KERNEL_TAR}.sign
#    fi
#  
#    ${RM} -rf ${KERNEL_NAME}
#    ${RM} -rf ${KBUILD_OUTPUT}
#  fi
  
  popd > /dev/null

  return 0
}

#########################################
# Build distribution (system)
#########################################
build_system() {
  # Add Systemd and locale packages
  INCLUDE=${INCLUDE},systemd,systemd-sysv,locales
  
  # Install Debian base system
  DEBOOTSTRAP_OPTIONS="--arch=${ARCH} --include=${INCLUDE} --variant=${VARIANT}"
  if [ -n "${EXCLUDE}" ]; then
    DEBOOTSTRAP_OPTIONS="${DEBOOTSTRAP_OPTIONS} --exclude=${EXCLUDE}"
  fi
  ${DEBOOTSTRAP} ${DEBOOTSTRAP_OPTIONS} ${SUITE} ${DEST_PATH} ${MIRROR}
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

## Build system
#if [ "${COMMAND}" == "build" ]; then
#  build_system
#  if [ $? -ne 0 ]; then
#    exit 1   
#  fi
#fi
#
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
