#!/bin/sh

command -v getarg >/dev/null || . /lib/dracut-lib.sh
command -v getargbool >/dev/null || {
    # Compatibility with older Dracut versions.
    # With apologies to the Dracut developers.
    getargbool() {
        if ! [ -z "$_b" ]; then
                unset _b
        fi
        _default="$1"; shift
        _b=$(getarg "$@")
        [ $? -ne 0 ] &&  [ -z "$_b" ] && _b="$_default"
        if [ -n "$_b" ]; then
            [ "$_b" = "0" ] && return 1
            [ "$_b" = "no" ] && return 1
            [ "$_b" = "off" ] && return 1
        fi
        return 0
    }
}

OLDIFS="${IFS}"
NEWLINE="
"

ZPOOL_IMPORT_OPTS=""
if getargbool 0 zfs_force -y zfs.force -y zfsforce ; then
    warn "ZFS: Will force-import pools if necessary."
    ZPOOL_IMPORT_OPTS="${ZPOOL_IMPORT_OPTS} -f"
fi

# find_bootfs
#   returns the first dataset with the bootfs attribute.
find_bootfs() {
    IFS="${NEWLINE}"
    for dataset in $(zpool list -H -o bootfs); do
        case "${dataset}" in
            "" | "-")
                continue
                ;;
            "no pools available")
                IFS="${OLDIFS}"
                return 1
                ;;
            *)
                IFS="${OLDIFS}"
                echo "${dataset}"
                return 0
                ;;
        esac
    done

    IFS="${OLDIFS}"
    return 1
}

# import_pool POOL
#   imports the given zfs pool if it isn't imported already.
import_pool() {
        pool="${1}"

    if ! zpool list -H "${pool}" > /dev/null 2>&1; then
        info "ZFS: Importing pool ${pool}..."
        if ! zpool import -N ${ZPOOL_IMPORT_OPTS} "${pool}" ; then
            warn "ZFS: Unable to import pool ${pool}"
            return 1
        fi
    fi

    return 0
}

# mount_dataset DATASET
#   mounts the given zfs dataset.
mount_dataset() {
        dataset="${1}"
    mountpoint="$(zfs get -H -o value mountpoint "${dataset}")"

    # We need zfsutil for non-legacy mounts and not for legacy mounts.
    if [ "${mountpoint}" = "legacy" ] ; then
        mount -t zfs "${dataset}" "${NEWROOT}"
    else
        mount -o zfsutil -t zfs "${dataset}" "${NEWROOT}"
    fi

    return $?
}

# export_all OPTS
#   exports all imported zfs pools.
export_all() {
        opts="${@}"
    ret=0

    IFS="${NEWLINE}"
    for pool in $(zpool list -H -o name) ; do
        if zpool list -H "${pool}" > /dev/null 2>&1; then
            zpool export "${pool}" ${opts} || ret=$?
        fi
    done
    IFS="${OLDIFS}"

    return ${ret}
}

# ask_for_password
#
# Wraps around plymouth ask-for-password and adds fallback to tty password ask
# if plymouth is not present.
#
# --cmd command
#   Command to execute. Required.
# --prompt prompt
#   Password prompt. Note that function already adds ':' at the end.
#   Recommended.
# --tries n
#   How many times repeat command on its failure.  Default is 3.
# --ply-[cmd|prompt|tries]
#   Command/prompt/tries specific for plymouth password ask only.
# --tty-[cmd|prompt|tries]
#   Command/prompt/tries specific for tty password ask only.
# --tty-echo-off
#   Turn off input echo before tty command is executed and turn on after.
#   It's useful when password is read from stdin.
ask_for_password() {
    ply_tries=3
    tty_tries=3
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --cmd) ply_cmd="$2"; tty_cmd="$2"; shift;;
            --ply-cmd) ply_cmd="$2"; shift;;
            --tty-cmd) tty_cmd="$2"; shift;;
            --prompt) ply_prompt="$2"; tty_prompt="$2"; shift;;
            --ply-prompt) ply_prompt="$2"; shift;;
            --tty-prompt) tty_prompt="$2"; shift;;
            --tries) ply_tries="$2"; tty_tries="$2"; shift;;
            --ply-tries) ply_tries="$2"; shift;;
            --tty-tries) tty_tries="$2"; shift;;
            --tty-echo-off) tty_echo_off=yes;;
        esac
        shift
    done

    { flock -s 9;
        # Prompt for password with plymouth, if installed and running.
        if whereis plymouth >/dev/null 2>&1 && plymouth --ping 2>/dev/null; then
            plymouth ask-for-password \
                --prompt "$ply_prompt" --number-of-tries="$ply_tries" \
                --command="$ply_cmd"
            ret=$?
        else
            if [ "$tty_echo_off" = yes ]; then
                stty_orig="$(stty -g)"
                stty -echo
            fi

            i=1
            while [ "$i" -le "$tty_tries" ]; do
                [ -n "$tty_prompt" ] && \
                    printf "%s [%i/%i]:" "$tty_prompt" "$i" "$tty_tries" >&2
                eval "$tty_cmd" && ret=0 && break
                ret=$?
                i=$((i+1))
                [ -n "$tty_prompt" ] && printf '\n' >&2
            done
            unset i
            [ "$tty_echo_off" = yes ] && stty "$stty_orig"
        fi
    } 9>/.console_lock

    [ $ret -ne 0 ] && echo "Wrong password" >&2
    return $ret
}
