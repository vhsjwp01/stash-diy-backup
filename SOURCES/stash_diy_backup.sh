#!/bin/bash
#set -x

################################################################################
#                    S C R I P T     D E S C R I P T I O N
################################################################################
# 20141028     Jason W. Plummer          Original.  This script uses the 
#                                        Atlassian Stash REST API to perform
#                                        backups using this DIY cookbook:
#                                        https://confluence.atlassian.com/display/STASH/Using+Stash+DIY+Backup#UsingStashDIYBackup-Advanced-writingyourownDIYBackupusingtheRESTAPIs
#

################################################################################
# DESCRIPTION
################################################################################
#
# This script performs the following tasks:
# 1.  Locks Stash via its REST API.  This process yields an unlock token which
#     gets stored in the variable ${stash_lock_token} and used throughout the
#     script
# 2.  Requests Stash to begin a vendor independent backup.  The script enters
#     a loop cycle whereby a REST call is made every 2 seconds to check the 
#     status of the scm-state and db-state variables.  Once both parameters 
#     return a value of "DRAINED", the next phase of backup can begin.
# 3.  Starts an rsync of directory ${src} to directory ${dest} via rsync.  The
#     rsync process is launched in the background with all output written to
#     a log.  This log is parsed every 2 seconds to compute the completion 
#     ratio.  This ratio is then normalized and reported via REST interface
#     to the Stash UI, for proper graphical representation of completion status
# 4.  Once the rsync process is completed, the rsync log is backed up
# 5.  Unlocks Stash

################################################################################
# CONSTANTS
################################################################################

TERM=vt100
PATH=/bin:/usr/bin:/usr/local/bin:/sbin:/usr/sbin:/usr/local/sbin
export TERM PATH

SUCCESS=0
ERROR=1

################################################################################
# VARIABLES
################################################################################

err_msg=""
exit_code=${SUCCESS}

################################################################################
# SUBROUTINES
################################################################################

# WHAT: Subroutine f__check_command
# WHY:  This subroutine checks the contents of lexically scoped ${1} and then
#       searches ${PATH} for the command.  If found, a variable of the form
#       my_${1} is created.
# NOTE: Lexically scoped ${1} should not be null, otherwise the command for
#       which we are searching is not present via the defined ${PATH} and we
#       should complain
#
f__check_command() {
    return_code=${SUCCESS}
    my_command="${1}"

    if [ "${my_command}" != "" ]; then
        my_command_check=`which ${1} 2> /dev/null`

        if [ "${my_command_check}" = "" ]; then
            return_code=${ERROR}
        else
            eval my_${my_command}="${my_command_check}"
        fi

    else
        err_msg="No command was specified"
        return_code=${ERROR}
    fi

    return ${return_code}
}

#-------------------------------------------------------------------------------

################################################################################
# MAIN
################################################################################

# WHAT: Make sure we have a some useful commands
# WHY:  Cannot proceed otherwise
#
if [ ${exit_code} -eq ${SUCCESS} ]; then

    for command in awk bc curl date egrep find jq ps rsync sed sleep tail wc ; do
        unalias ${command} > /dev/null 2>&1
        f__check_command "${command}"

        if [ ${?} -ne ${SUCCESS} ]; then
            let exit_code=${exit_code}+1
        fi

    done

fi

# WHAT: Process our arguments
# WHY:  Cannot proceed otherwise
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    err_msg="Not enough arguments provided"
    exit_code=${ERROR}

    #----------------------------
    # NOTE: We need the following
    #----------------------------
    # ${stash_user}                    # config file?
    # ${stash_user_password}           # config file?
    # ${stash_url}                     # fully qualified (with port if needed)

    for arg in ${*} ; do
        key=`echo "${arg}" | awk -F'=' '{print $1}'`
        value=`echo "${arg}" | awk -F'=' '{print $NF}'`

        case ${key} in

            stash_user|stash_user_password|stash_url)
                eval "${key}=\"${value}\""
            ;;

        esac

    done

    if [ "${stash_user}" != "" -a "${stash_user_password}" != "" -a "${stash_url}" != "" ]; then
        err_msg=""
        exit_code=${SUCCESS}
    fi

fi

# WHAT: Test the url
# WHY:  Cannot proceed otherwise
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    let is_valid_url=`${my_curl} -s -v ${stash_url}/projects 2>&1 | ${my_egrep} -c "Trying*.*connected$"`

    if [ ${is_valid_url} -eq 0 ]; then
        err_msg="There were problems connecting to Stash URL \"${stash_url}\""
        exit_code=${ERROR}
    fi

fi

# WHAT: Try to lock stash
# WHY:  If we get here then the Stash URL is valid
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    lock_url="mvc/maintenance/lock"
    stash_lock_token=`${my_curl} -s -u "${stash_user}:${stash_user_password}" -X POST -H "Content-type: application/json" "${stash_url}/${lock_url}" 2> /dev/null | ${my_jq} ".unlockToken" 2> /dev/null | ${my_sed} -e 's/"//g' 2> /dev/null`

    if [ "${stash_lock_token}" = "" ]; then
        err_msg="Failed to lock Stash instance \"${stash_url}\""
        exit_code=${ERROR}
    else
        echo "Successfully locked Stash instance \"${stash_url}\""
        echo "    Unlock Token: ${stash_lock_token}"
    fi

fi

# WHAT: Start Stash backup
# WHY:  If we get here then we have a stash lock token
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    backup_url="mvc/admin/backups"
    stash_backup_token=`${my_curl} -s -u "${stash_user}:${stash_user_password}" -X POST -H "X-Atlassian-Maintenance-Token: ${stash_lock_token}" -H "Accept: application/json" -H "Content-type: application/json" "${stash_url}/${backup_url}" 2> /dev/null | ${my_jq} ".id" 2> /dev/null | ${my_sed} -e 's/"//g' 2> /dev/null`

    if [ "${stash_backup_token}" = "" ]; then
        err_msg="    Failed to start backup of Stash instance \"${stash_url}\""
        exit_code=${ERROR}
    else
        echo "    Successfully started backup of Stash instance \"${stash_url}\""
        echo "        Backup Token: ${stash_backup_token}"
    fi

fi

# WHAT: Wait for Stash to finish backup
# WHY:  If we get here then we successfully started a 
#       vendor independent stash database backup
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    keyword="DRAINED"
    status_url="mvc/maintenance"
    let is_finished=0

    while [ ${is_finished} -eq 0 ]; do
        is_finished=`${my_curl} -s -u "${stash_user}:${stash_user_password}" -X GET -H "X-Atlassian-Maintenance-Token: ${stash_lock_token}" -H "Accept: application/json" -H "Content-type: application/json" "${stash_url}/${status_url}" 2> /dev/null | ${my_jq} "." | ${my_awk} -F':' '/db-state|scm-state/ {print $NF}' | ${my_sed} -e 's/[\ ",]//g' 2> /dev/null | ${my_egrep} -ic "^${keyword}$"`
        ${my_sleep} 2
    done

    echo "    Successfully completed backup of Stash instance \"${stash_url}\""
fi

# WHAT: Perform an rsync backup of Stash
# WHY:  If we get there then the databases have been drained
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    logfile="/tmp/rsync-stash.`${my_date} +%Y%m%d`.log"
    src="/var/atlassian/application-data/stash/"
    dest="/home/backup"
    rsync_status=0

    echo "    Starting rsync backup of \"${src}\" to \"${dest}\""
    ${my_rsync} -avHS --progress "${src}" "${dest}" > "${logfile}" 2>&1 &
    ${my_sleep} 1

    while [ ${rsync_status} -lt 100 ]; do
        let progress_ratio=`${my_awk} '/to-check/ {print $NF}' "${logfile}" | ${my_tail} -1 | ${my_awk} -F'=' '{print $2}' | ${my_sed} -e 's/)//g'`

        if [ "${progress_ratio}" != "" ]; then
            let rsync_status=`echo "50-50*${progress_ratio}+50" | bc`

            # Avoid round off errors while rsync is finishing plowing through a large number of files
            if [ ${rsync_status} -eq 100 ]; then
                let rsync_proc=`${my_ps} -aef | ${my_egrep} "${my_rsync}*.*${src}*.*${dest}" | ${my_egrep} -v grep | ${my_wc} -l`

                if [ ${rsync_proc} -gt 0 ]; then
                    rsync_status=99
                fi

            fi

            # Update the Stash interface
            echo "        Stash rsync backup status: ${rsync_status}%"
            ${my_curl} -s -u "${stash_user}:${stash_user_password}" -X POST -H "Accept: application/json" -H "Content-type: application/json" "${stash_url}/mvc/admin/backups/progress/client?token=${stash_lock_token}&percentage=${rsync_status}" > /dev/null 2>&1
        fi

        ${my_sleep} 2
    done

    # Copy over the rsync log to ${dest}/export
    mv "${logfile}" "${dest}/export"
    echo "    Completed rsync backup of \"${src}\" to \"${dest}\""
fi

# WHAT: Unlock Stash
# WHY:  If we get there then backup is done
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    is_unlocked=`${my_curl} -s -u "${stash_user}:${stash_user_password}" -X DELETE -H "Accept: application/json" -H "Content-type: application/json" "${stash_url}/mvc/maintenance/lock?token=${stash_lock_token}" | ${my_jq} "." | ${my_wc} -l`

    if [ ${is_unlocked} -gt 0 ]; then
        err_msg="An error occured unlocking Stash instance \"${stash_url}\""
        exit_code=${ERROR}
    else
        echo "Successfully unlocked Stash instance \"${stash_url}\""
    fi

fi

# WHAT: Complain if necessary and exit
# WHY:  Success or failure, either way we are through
#
if [ ${exit_code} -ne ${SUCCESS} ]; then

    if [ "${err_msg}" != "" ]; then
        echo
        echo "    ERROR:  ${err_msg} ... processing halted"
        echo
        echo "  Usage: ${0} [ stash_user=<stash user> | stash_user_password=<stash user password> | stash_url=<stash base url> ]"
        echo
    fi

fi

exit ${exit_code}
