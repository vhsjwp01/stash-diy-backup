#!/bin/bash
#set -x

################################################################################
#                    S C R I P T     D E S C R I P T I O N
################################################################################
# 20141028     Jason W. Plummer          Original.  This script uses the 
#                                        Atlassian Stash REST API to perform
#                                        backups
# 20150129     Jason W. Plummer          Added support for passing a config
#                                        file.  Standardized output
# 20150130     Jason W. Plummer          Added command line options to the 
#                                        DESCRIPTION section
# 20150316     Jason W. Plummer          Added trap to unlock stash on non-zero
#                                        exit status

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
# 3.  Starts a data copy of path ${rsync_src} to path ${rsync_dest} via rsync.
#     The rsync process is launched in the background with all output written
#     to a log.  This log is parsed every 2 seconds to compute the completion
#     ratio.  This ratio is then normalized and reported via REST interface to
#     the Stash UI, for proper graphical representation of completion status
# 4.  Once the rsync process is completed, the rsync log is backed up to 
#     ${rsync_dest}
# 5.  Unlocks Stash
#
# Theory of operations developed using this web resource:
#
#     https://confluence.atlassian.com/display/STASH/Using+Stash+DIY+Backup#UsingStashDIYBackup-Advanced-writingyourownDIYBackupusingtheRESTAPIs
#
# OPTIONS:
#
# config=<configuration file>              - The full path to a config file 
#                                            which will be used to provide
#                                            mandatory runtime key=value pairs.
#                                            Must be in Bourne shell syntax
# stash_user=<username>                    - A stash username that has the 
#                                            proper permissions to perform a
#                                            backup
# stash_user_password=<plaintext password> - The password associated with the
#                                            ${stash_user}
# stash_url=<fully qualified URL>          - The fully qualified URL to a stash
#                                            server REST API
# 

################################################################################
# CONSTANTS
################################################################################

TERM=vt100
PATH=/bin:/usr/bin:/usr/local/bin:/sbin:/usr/sbin:/usr/local/sbin
export TERM PATH

SUCCESS=0
ERROR=1

STDOUT_OFFSET="    "

SCRIPT_NAME="${0}"

USAGE_ENDLINE="\n${STDOUT_OFFSET}${STDOUT_OFFSET}${STDOUT_OFFSET}${STDOUT_OFFSET}"
USAGE="${SCRIPT_NAME}${USAGE_ENDLINE}"
USAGE="${USAGE}[ config=<path to config file> ]${USAGE_ENDLINE}"
USAGE="${USAGE}[ stash_user=<stash user> ]${USAGE_ENDLINE}"
USAGE="${USAGE}[ stash_user_password=<stash user password> ]${USAGE_ENDLINE}"
USAGE="${USAGE}[ stash_url=<stash base url> ]"

################################################################################
# VARIABLES
################################################################################

err_msg=""
exit_code=${SUCCESS}

stash_trap_dir="/tmp/stash-diy-backup/$$"
trap_script="unlock.sh"
trap "if [ -e \"${stash_trap_dir}/${trap_script}\" ]; then sh \"${stash_trap_dir}/${trap_script}\" ; rm -rf \"${stash_trap_dir}\" ; fi" 0 1 2 3 15

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
    my_command=`echo "${1}" | sed -e 's?\`??g'`

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

    for command in awk bc chmod curl date egrep find jq ps rsync sed sleep tail wc ; do
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
    # ${stash_user}                    # command line or config file
    # ${stash_user_password}           # command line or config file
    # ${stash_url}                     # fully qualified (with port if needed)
    #                                    command line or config file
    # ${rsync_src}}                    # A path (file or rsync share) from which
    #                                    data will be copied
    #                                    command line or config file
    # ${rsync_dest}}                   # A path (file or rsync share) to which
    #                                    data will be copied
    #                                    command line or config file

    for arg in ${*} ; do
        key=`echo "${arg}" | ${my_awk} -F'=' '{print $1}' | ${my_sed} -e 's?\`??g'`
        value=`echo "${arg}" | ${my_awk} -F'=' '{print $NF}' | ${my_sed} -e 's?\`??g'`

        case ${key} in

            config|stash_user|stash_user_password|stash_url|rsync_src|rsync_dest)
                eval "${key}=\"${value}\""
            ;;

            *)
                # Exit quietly, peacefully, and enjoy it
                exit
            ;;

        esac

    done

    # If we were given a config file, then make sure it has in it
    # the pieces we need
    #
    if [ "${config}" != "" -a -r "${config}" ]; then

        for key in stash_user stash_user_password stash_url rsync_src rsync_dest ; do
            value=`${my_egrep} "^${key}=" "${config}" | ${my_awk} -F'=' '{print $NF}' | ${my_sed} -e 's?\"??g' -e 's?\`??g'`
            eval "${key}=\"${value}\""
        done

    fi 

    if [ "${stash_user}" != "" -a "${stash_user_password}" != "" -a "${stash_url}" != "" -a "${rsync_src}" != "" -a "${rsync_dest}" != "" ]; then
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
        echo "${STDOUT_OFFSET}Unlock Token: ${stash_lock_token}"

        # Generate unlock script /tmp/stash-diy-backup/$$/unlock.sh
        # that can be called via trap should this script exit unexpectedly
        if [ ! -d "${stash_trap_dir}" ]; then
            mkdir -p "${stash_trap_dir}"
            touch "${stash_trap_dir}/${trap_script}"
            echo "#!/bin/bash"                                                                  > "${stash_trap_dir}/${trap_script}"
            echo "set -x"                                                                      >> "${stash_trap_dir}/${trap_script}"
            echo "echo \"Attempting to unlock stash ...\""                                     >> "${stash_trap_dir}/${trap_script}"
            echo "is_unlocked=\`${my_curl} -s -u \"${stash_user}:${stash_user_password}\" -X DELETE -H \"Accept: application/json\" -H \"Content-type: application/json\" \"${stash_url}/mvc/maintenance/lock?token=${stash_lock_token}\" | ${my_jq} \".\" | ${my_wc} -l | ${my_awk} '{print \$1}'\`" >> "${stash_trap_dir}/${trap_script}"
            echo "if [ \${is_unlocked} -gt 0 ]; then"                                          >> "${stash_trap_dir}/${trap_script}"
            echo "    echo \"An error occured unlocking Stash instance \\\"${stash_url}\\\"\"" >> "${stash_trap_dir}/${trap_script}"
            echo "fi"                                                                          >> "${stash_trap_dir}/${trap_script}"
            chmod 400 "${stash_trap_dir}/${trap_script}"
        fi

    fi

fi

# WHAT: Start Stash backup
# WHY:  If we get here then we have a stash lock token
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    backup_url="mvc/admin/backups"
    stash_backup_token=`${my_curl} -s -u "${stash_user}:${stash_user_password}" -X POST -H "X-Atlassian-Maintenance-Token: ${stash_lock_token}" -H "Accept: application/json" -H "Content-type: application/json" "${stash_url}/${backup_url}" 2> /dev/null | ${my_jq} ".id" 2> /dev/null | ${my_sed} -e 's/"//g' 2> /dev/null`

    if [ "${stash_backup_token}" = "" ]; then
        err_msg="${STDOUT_OFFSET}Failed to start backup of Stash instance \"${stash_url}\""
        exit_code=${ERROR}
    else
        echo "${STDOUT_OFFSET}Successfully started backup of Stash instance \"${stash_url}\""
        echo "${STDOUT_OFFSET}${STDOUT_OFFSET}Backup Token: ${stash_backup_token}"
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

    echo "${STDOUT_OFFSET}Successfully completed backup of Stash instance \"${stash_url}\""
fi

# WHAT: Perform an rsync backup of Stash
# WHY:  If we get there then the databases have been drained
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    logfile="/tmp/rsync-stash.`${my_date} +%Y%m%d`.log"
    rsync_status=0

    echo "${STDOUT_OFFSET}Starting rsync backup of \"${rsync_src}\" to \"${rsync_dest}\""
    ${my_rsync} -avHS --progress "${rsync_src}" "${rsync_dest}" > "${logfile}" 2>&1 &
    ${my_sleep} 1

    while [ ${rsync_status} -lt 100 ]; do
        let progress_ratio=`${my_awk} '/to-check/ {print $NF}' "${logfile}" | ${my_tail} -1 | ${my_awk} -F'=' '{print $2}' | ${my_sed} -e 's/)//g'`

        if [ "${progress_ratio}" != "" ]; then
            let rsync_status=`echo "50-50*${progress_ratio}+50" | bc`

            # Avoid round off errors while rsync is finishing plowing through a large number of files
            if [ ${rsync_status} -eq 100 ]; then
                let rsync_proc=`${my_ps} -aef | ${my_egrep} "${my_rsync}*.*${rsync_src}*.*${rsync_dest}" | ${my_egrep} -v grep | ${my_wc} -l | ${my_awk} '{print $1}'`

                if [ ${rsync_proc} -gt 0 ]; then
                    rsync_status=99
                fi

            fi

            # Update the Stash interface
            echo "${STDOUT_OFFSET}${STDOUT_OFFSET}Stash rsync backup status: ${rsync_status}%"
            ${my_curl} -s -u "${stash_user}:${stash_user_password}" -X POST -H "Accept: application/json" -H "Content-type: application/json" "${stash_url}/mvc/admin/backups/progress/client?token=${stash_lock_token}&percentage=${rsync_status}" > /dev/null 2>&1
        fi

        ${my_sleep} 2
    done

    # Copy over the rsync log to ${rsync_dest}
    ${my_rsync} "${logfile}" "${rsync_dest}"
    echo "${STDOUT_OFFSET}Completed rsync backup of \"${rsync_src}\" to \"${rsync_dest}\""
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
        rm -rf "${stash_trap_dir}"
    fi

fi

# WHAT: Complain if necessary and exit
# WHY:  Success or failure, either way we are through
#
if [ ${exit_code} -ne ${SUCCESS} ]; then

    if [ "${err_msg}" != "" ]; then
        echo
        echo "${STDOUT_OFFSET}ERROR:  ${err_msg} ... processing halted"
        echo
    fi

    echo 
    echo -ne "${STDOUT_OFFSET}USAGE:  ${USAGE}\n"
    echo
fi

exit ${exit_code}
