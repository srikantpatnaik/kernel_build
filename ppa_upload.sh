#!/bin/bash
#-------------------------------------------------------------------------
# Following are plain filenames - expected in same dir as this script
#-------------------------------------------------------------------------
# Patch directory - all patches are expected to be in files in this dir
# Can be overridden by KERNEL_PATCH_DIR env var
# - Each file in directory can contain one or more patches
# - Patches are applied in file (lexicographic order)
# - Patch filenames ending in '.optional' are applied if possible.
#   Failures are ignored
# - Patch filenames NOT ending in '.optional' are considered mandatory.
#   Kernel build FAILS if patch does not apply.
PATCH_DIR=patches

#-------------------------------------------------------------------------
# Following are debug outputs - will be created in DEB_DIR
# Filenames cannot be overridden by environment vars
#-------------------------------------------------------------------------
# Output of build_kernel (ONLY)
COMPILE_OUT_FILENAME=compile.out
# File containing time taken for different steps
START_END_TIME_FILE=start_end.out

#-------------------------------------------------------------------------
# Probably don't have to change anything below this
#-------------------------------------------------------------------------

SCRIPT_DIR="$(readlink -f $(dirname $0))"

#-------------------------------------------------------------------------
# Following are requried scripts - must be in same dir as this script
# Cannot be overridden by environment vars
#-------------------------------------------------------------------------
CHECK_REQD_PKGS_SCRIPT=upload_required_pkgs.sh

#-------------------------------------------------------------------------
# functions
#-------------------------------------------------------------------------

function read_config {
    #-------------------------------------------------------------------------
    # Use KBUILD_CONFIG to get environment variables
    # Use KERNEL_BUILD_CONFIG if set to choose config file - defaults to
    # ~/.kernel_build.config
    #-------------------------------------------------------------------------
    KBUILD_CONFIG=~/.kernel_build.config

    if [ -n "$KERNEL_BUILD_CONFIG" ]; then
        KBUILD_CONFIG=$KERNEL_BUILD_CONFIG
    fi
    if [ -f "$KBUILD_CONFIG" ]; then
        if [ -r "$KBUILD_CONFIG" ]; then
            . "$KBUILD_CONFIG"
            if [ $? -ne 0 ]; then
                echo "Error sourcing KERNEL_BUILD_CONFIG : $KBUILD_CONFIG"
                return 1
            fi
        else
            echo "Ignoring unreadable KERNEL_BUILD_CONFIG : $KBUILD_CONFIG"
        fi
    else
        echo "Ignoring missing KERNEL_BUILD_CONFIG : $KBUILD_CONFIG"
    fi
}

function check_deb_dir {
    # Everything in this script depends on DEB_DIR being set, existing
    # and containing exactly one filename ending in .dsc
    # The rest of the checks are done by dpkg-source -x

    if [ -z "$DEB_DIR" ]; then
        echo "DEB_DIR not set, cannot proceed"
        return 1
    fi
    DEB_DIR=$(readlink -f "${DEB_DIR}")
    if [ ! -d "$DEB_DIR" ]; then
        echo "DEB_DIR not a directory: $DEB_DIR"
        return 1
    fi
    local num_dsc_files=$(ls $DEB_DIR/*.dsc 2>/dev/null | wc -l)
    if [ $num_dsc_files -lt 1 ]; then
        echo "No DSC file found in $DEB_DIR"
        return 1
    elif [ $num_dsc_files -gt 1 ]; then
        echo "More than one DSC file found in $DEB_DIR"
        ls -1 $DEB_DIR/*.dsc | sed -e 's/^/    /'
        return 1
    fi
    return 0
}

function set_vars {
    #-------------------------------------------------------------------------
    # Strip off directory path components if we expect only filenames
    #-------------------------------------------------------------------------
    CONFIG_FILE=$(basename "$CONFIG_FILE")
    PATCH_DIR=$(basename "$PATCH_DIR")
    CHECK_REQD_PKGS_SCRIPT=$(basename "$CHECK_REQD_PKGS_SCRIPT")

    COMPILE_OUT_FILENAME=$(basename "$COMPILE_OUT_FILENAME")
    START_END_TIME_FILE=$(basename "$START_END_TIME_FILE")

    # Required scripts can ONLY be in the same dir as this script
    CHECK_REQD_PKGS_SCRIPT="${SCRIPT_DIR}/${CHECK_REQD_PKGS_SCRIPT}"

    # Debug outputs are always in DEB_DIR
    COMPILE_OUT_FILEPATH="${DEB_DIR}/${COMPILE_OUT_FILENAME}"
    START_END_TIME_FILEPATH="${DEB_DIR}/$START_END_TIME_FILE"

    # CONFIG_FILE, PATCH_DIR and KERNEL_CONFIG_PREFS can be overridden by
    #  environment variables
    PATCH_DIR_PATH="${SCRIPT_DIR}/${PATCH_DIR}"
    if [ -n "${KERNEL_PATCH_DIR}" ]; then
        KERNEL_PATCH_DIR=$(readlink -f "${KERNEL_PATCH_DIR}")
        if [ -d "${KERNEL_PATCH_DIR}" ] ; then
            PATCH_DIR_PATH="${KERNEL_PATCH_DIR}"
        else
            echo "Ignoring non-existent patch directory : ${KERNEL_PATCH_DIR}"
            unset PATCH_DIR_PATH
        fi
    fi
    if [ -n "${KERNEL_CONFIG_PREFS}" ]; then
        KERNEL_CONFIG_PREFS=$(readlink -f "${KERNEL_CONFIG_PREFS}")
        if [ ! -f "${KERNEL_CONFIG_PREFS}" ] ; then
            echo "Ignoring non-existent config prefs : ${KERNEL_CONFIG_PREFS}"
            unset KERNEL_CONFIG_PREFS
        fi
    else
        KERNEL_CONFIG_PREFS="${SCRIPT_DIR}/config.prefs"
    fi

    INDENT="    "
    cd "${DEB_DIR}"

    DSC_FILE=$(ls -1 *.dsc | head -1)
    TAR_FILE=$(ls -1 *.orig.tar.gz | head -1)
    DEBIAN_TAR_FILE=$(ls -1 *.debian.tar.gz | head -1)
    DSC_FILE=$(basename $DSC_FILE)
    TAR_FILE=$(basename $TAR_FILE)
    DEBIAN_TAR_FILE=$(basename $DEBIAN_TAR_FILE)

    # Print what we are using
    printf "%-24s : %s\n" "Patch dir" "${PATCH_DIR_PATH}"
    printf "%-24s : %s\n" "Config prefs" "${KERNEL_CONFIG_PREFS}"
    printf "%-24s : %s\n" "DEBS built in" "${DEB_DIR}"
    printf "%-24s : %s\n" "DSC_FILE" "$DSC_FILE"
    printf "%-24s : %s\n" "TAR_FILE" "$TAR_FILE"
    printf "%-24s : %s\n" "DEBIAN_TAR_FILE" "$DEBIAN_TAR_FILE"
    printf "%-24s : %s\n" "Build output" "$COMPILE_OUT_FILEPATH"
}

function get_hms {
    # Converts a variable like SECONDS to hh:mm:ss format and echoes it
    # $1: value to convert - if not set defaults to using $SECONDS
    if [ -n "$1" ]; then
        duration=$1
    else
        duration=$SECONDS
    fi
    printf "%02d:%02d:%02d" "$(($duration / 3600))" "$(($duration / 60))" "$(($duration % 60))"
}

function show_timing_msg {
    # $1: Message
    # $2: tee or not: 'yestee' implies tee
    # $3 (optional): elapsed time (string)
    if [ "$2" = "yestee" ]; then
        if [ -n "$3" ]; then
            printf "%-39s: %-28s (%s)\n" "$1" "$(date)" "$3" | tee -a "$START_END_TIME_FILEPATH"
        else
            printf "%-39s: %-28s\n" "$1" "$(date)" | tee -a "$START_END_TIME_FILEPATH"
        fi
    else
        if [ -n "$3" ]; then
            printf "%-39s: %-28s (%s)\n" "$1" "$(date)" "$3" >> "$START_END_TIME_FILEPATH"
        else
            printf "%-39s: %-28s\n" "$1" "$(date)" >> "$START_END_TIME_FILEPATH"
        fi
    fi
}

function build_src_changes {
    # (If we used 'make deb-pkg' and not 'make bindeb-pkg') we look for .dsc file
    # If .dsc file exists, we do the following:
    #   - Build-Depends field is updated - we KNOW what it should be
    #   - If BOTH DEBEMAIL and DEBFULLNAME are set, PPA_MAINTAINER is constructed
    #     from DEB_EMAIL and DEBFULLNAME and Maintainer field is replaced with that
    #   - We extract the source package and build using debuild (WITH signing)
    #   - IFF dpkg-source -x and debuild was successful:
    #       - If DPUT_PPA_NAME exists, dput is called using DPUT_PPA_NAME as repository name
    #           ASSUMING ~/.dput.cf is setup correctly

    local PPA_MAINTAINER=""
    if [ -n "$DEBEMAIL" -a -n "$DEBFULLNAME" ]; then
        PPA_MAINTAINER="$DEBFULLNAME <${DEBEMAIL}>"
    fi

    show_timing_msg "Source package build start" "yestee" ""; SECONDS=0
    local HOST_ARCH=$(dpkg-architecture | grep '^DEB_BUILD_ARCH=' | cut -d= -f2)
    # Put a divider in compile.out
    echo "" >> "${COMPILE_OUT_FILEPATH}"
    echo "--------------------------------------------------------------------------" >> "${COMPILE_OUT_FILEPATH}"

    # All the action from now is in ${DEB_DIR}
    cd "${DEB_DIR}"

    # Make a new directory for source build
    SRC_BUILD_DIR=$(mktemp -d -p .)
    cd ${SRC_BUILD_DIR}
    for f in ${DSC_FILE} ${TAR_FILE} ${DEBIAN_TAR_FILE}
    do
        cp ../$f .
    done
    dpkg-source -x ${DSC_FILE} linux 1>>"${COMPILE_OUT_FILEPATH}" 2>&1
    if [ $? -ne 0 ]; then
        echo "dpkg-source -x failed " >> "${COMPILE_OUT_FILEPATH}"
        cd "$DEB_DIR"
        return 1
    fi
    for f in ${DSC_FILE} linux/debian/control
    do
        # Update Build-depends
        sed -i '/^Build-Depends: / s/$/, libelf-dev, libncurses5-dev, libssl-dev, libfile-fcntllock-perl, fakeroot/' $f
        # Update Maintainer
        if [ -n "$PPA_MAINTAINER" ]; then
            sed -i "s/^Maintainer: .*$/Maintainer: $PPA_MAINTAINER/" $f
        fi
    done

    BUILD_OPTS="-S -a $HOST_ARCH "
    if [ -n "$GPG_KEYID" -o -n "$GPG_DEFAULT_KEY_SET" ]; then
        if [ -n "$GPG_KEYID" ]; then
            echo "Using GPG KeyID ${GPG_KEYID}"
        else
            echo "Assuming default-key is set in gpg.conf"
        fi
    else
        BUILD_OPTS="$BUILD_OPTS -us -uc"
        echo "GPG_KEYID not set. Not signing source or changes. This cannot be uploaded to Launchpad.net"
    fi
    cd linux
    if [ -n "$PPA_MAINTAINER" ]; then
        dpkg-buildpackage $BUILD_OPTS -e"$PPA_MAINTAINER" -m"$PPA_MAINTAINER" 1>>"${COMPILE_OUT_FILEPATH}" 2>&1
    else
        dpkg-buildpackage $BUILD_OPTS 1>>"${COMPILE_OUT_FILEPATH}" 2>&1
    fi
    if [ $? -ne 0 ]; then
        echo "dpkg-buildpackage -x failed " >> "${COMPILE_OUT_FILEPATH}"
        cd "$DEB_DIR"
        return 1
    fi
    cd ..

    show_timing_msg "Source package build finished" "yestee" "$(get_hms)"
    return 0
}

function upload_src_to_ppa {
    if [ -z "$DPUT_PPA_NAME" ]; then
        return 0
    fi
    show_timing_msg "Source package upload start" "yestee" ""; SECONDS=0
    # Put a divider in compile.out
    echo "" >> "${COMPILE_OUT_FILEPATH}"
    echo "--------------------------------------------------------------------------" >> "${COMPILE_OUT_FILEPATH}"
    cd "${DEB_DIR}"/"${SRC_BUILD_DIR}"
    SRC_CHANGE_FILE=$(ls -1 *_source.changes | head -1)
    SRC_CHANGE_FILE=$(basename $SRC_CHANGE_FILE)
    if [ -z "$SRC_CHANGE_FILE" ]; then          # Unexpected
        echo "SRC_CHANGE_FILE not found" >> "${COMPILE_OUT_FILEPATH}"
        show_timing_msg "Source package upload abandoned" "yestee" ""
        return 1
    fi
    cat "$SRC_CHANGE_FILE" >>"${COMPILE_OUT_FILEPATH}"
    echo "dput $DPUT_PPA_NAME $SRC_CHANGE_FILE" >>"${COMPILE_OUT_FILEPATH}"
    dput "$DPUT_PPA_NAME" "$SRC_CHANGE_FILE"
    show_timing_msg "Source package upload finished" "yestee" "$(get_hms)"
    return 0
}


#-------------------------------------------------------------------------
# Actual build steps after this
#-------------------------------------------------------------------------
read_config || exit 1
check_deb_dir || exit 1
set_vars
$CHECK_REQD_PKGS_SCRIPT || exit 1

build_src_changes || exit 1
upload_src_to_ppa || exit 1



echo "-------------------------- Kernel compile time -------------------------------"
cat $START_END_TIME_FILEPATH
echo "------------------------------------------------------------------------------"
echo "Kernel DEBS: (in $(readlink -f $DEB_DIR))"
cd "${DEB_DIR}"
ls -1 *.deb | sed -e "s/^/${INDENT}/"
echo "------------------------------------------------------------------------------"

\rm -f "${COMPILE_OUT_FILEPATH}" "$START_END_TIME_FILEPATH"
