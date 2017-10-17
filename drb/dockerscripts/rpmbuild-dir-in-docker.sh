#!/bin/bash
set -ex

EXIT_STATUS="FAIL"

function log {
    echo "[$(date --rfc-3339=seconds)]: $*"
}

function finish {
  chown -R "${CALLING_UID}":"${CALLING_GID}" "${RPMS_DIR}" /tmp || /bin/true
  umount -f "${SOURCE_DIR}" || /bin/true
  log "${0}: exiting. Outcome: ${EXIT_STATUS}"
}
trap finish EXIT

log "${0}: starting"

[ -z "${CALLING_UID}" ] && { log "Missing CALLING_UID"; /bin/false; }
[ -z "${CALLING_GID}" ] && { log "Missing CALLING_GID"; /bin/false; }
[ -z "${BASH_ON_FAIL}" ] && { log "Missing BASH_ON_FAIL. Won't drop into interactive shell if errors are found"; }
[ -n "${ENABLE_SOURCE_OVERLAY}" ] && { log "Source overlay is unsupported"; /bin/false; }

RPMS_DIR="$(rpm --eval %\{_rpmdir\})"
SRPMS_DIR="$(rpm --eval %\{_srcrpmdir\})"
SOURCE_DIR="$(rpm --eval %\{_sourcedir\})"
SPECS_DIR="$(rpm --eval %\{_specdir\})"
ARCH="$(rpm --eval %\{_arch\})"

SPEC="$(ls "${SPECS_DIR}"/*.spec | head -n 1)"
/dockerscripts/rpm-setup-deps.sh

#rpmbuild complains if it can't find a proper user for uid/gid of the source files;
#we should add all uid/gids for source files.
for gid in $(stat -c '%g' "${SOURCE_DIR}"/*); do
    groupadd -g "$gid" "group$gid" >/dev/null 2>&1 || /bin/true
done

for uid in $(stat -c '%u' "${SOURCE_DIR}"/*); do
    useradd -u "$uid" "user$uid" >/dev/null 2>&1 || /bin/true
done

if [ -r "/rpmmacros" ]
then
    cp /rpmmacros "${HOME}/.rpmmacros"
    echo -e "\n" >> "${HOME}/.rpmmacros"
fi

if [ -r "/private.key" ]
then
    log "Running with RPM signing"
    GPGBIN="$(command -v gpg || command -v gpg2)"
    ${GPGBIN} --import /private.key
    [[ $(${GPGBIN} --list-secret-keys) =~ uid(.*) ]]
    KEYNAME="${BASH_REMATCH[1]}"
    [ -n "${KEYNAME}" ] || { log "could not find key for signing purpose"; exit 1; }
    echo -e "%_gpg_name ${KEYNAME}\n%_signature gpg" >> "${HOME}/.rpmmacros"
    ${GPGBIN} --armor --export "${KEYNAME}" > /tmp/public.gpg
    rpm --import /tmp/public.gpg
	
	exitcode=0
    rpmbuild_out="$(rpmbuild ${RPMBUILD_EXTRA_OPTIONS} -bb "$SPEC" 2>&1)" || { exitcode="$?" ; /bin/true ; }
    if [ "${exitcode}" -ne 0 ]; then
			if [ "bashonfail" == "${BASH_ON_FAIL}" ]; then
				# if the build is interactive, we can see what's printed in the current log, no need to reprint.
				log "Build failed, spawning a shell. The build will terminate after such shell is closed."
				/bin/bash
			else 
				log -e "${rpmbuild_out}\n\nrpmbuild command failed."
			fi
		exit ${exitcode}
	fi
    
	files="$(sed -n -e '/Checking for unpackaged file/,$p' <<< "${rpmbuild_out}" | grep 'Wrote:' | cut -d ':' -f 2)"
	
	exitcode=0
    echo -e "\n" | setsid rpmsign --addsign "${files}" ||  /bin/true
    rpm -K "${files}" || { log "Signing failed." ; exitcode=1 ; }
    if [ "${exitcode}" -ne 0 ]; then
			if [ "bashonfail" == "${BASH_ON_FAIL}" ]; then
				# if the build is interactive, we can see what's printed in the current log, no need to reprint.
				log "Signing failed, spawning a shell. The build will terminate after such shell is closed."
				/bin/bash
			else
				log -e "${rpmbuild_out}\n\nrpmsign command failed. FOREVER AND EVER"
			fi
		# don't accidentally retain unsigned files
		rm -f "${files}"
		exit "${exitcode}"
	fi
else
    log "Running without RPM signing"
    rpmbuild ${RPMBUILD_EXTRA_OPTIONS} -bb "$SPEC" || { [ "bashonfail" == "${BASH_ON_FAIL}" ] && { log "Build failed, spawning a shell" ; /bin/bash ; exit 1; } || exit 1 ; }
fi

EXIT_STATUS="SUCCESS"
