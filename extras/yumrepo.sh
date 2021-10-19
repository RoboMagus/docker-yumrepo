#!/usr/bin/env sh

# Set defaults for required ENV variables:
: ${REPO_PROTO:=http}
: ${REPO_PORT:=80}

: ${USE_UPDATE:=0}
: ${FIND_SYMLINKS:=0}


if [[ "$FIND_SYMLINKS" == 1 ]]; then
  find_L="-L"
else
  find_L=" "
fi


if [[ "$USE_UPDATE" == 1 ]]; then
  createrepo_arg="--update"
else
  createrepo_arg=" "
fi

trap '_exit' SIGINT SIGTERM EXIT

function _exit(){
    kill -- -$$
    exit 0
}

function importGpgKey(){
    if [ -n "${REPO_GPG_KEY_NAME}" ]; then
        [ -z ${REPO_GPG_PASSPHRASE} ] && echo "WARNING: GPG key provided with no passphrase! set REPO_GPG_PASSPHRASE environment variable"
	gpg --batch --import /var/repo.key
    fi
}


function createRepos(){
    echo -e "> Creating repository indexes... (repo maxdepth ${REPO_DEPTH})"

    # for gpg-signed repos, createrepo_c seems to call 'cp' for the repomd.xml.{asc,key} files using options not currently supported by busybox 'cp'
    # - as a workaround delete these files before calling createrepo_c - they will be recreated afterwards anyway
    [ -n "${REPO_GPG_KEY_NAME}" ] && find ${REPO_PATH} -name 'repomd.xml.*' -type f -exec rm {} \;

    find ${find_L} ${REPO_PATH} -type d -maxdepth ${REPO_DEPTH} -mindepth ${REPO_DEPTH} -exec echo "Creating repo for {}" \; -exec createrepo_c ${createrepo_arg} {} \;
    if [ -n "${REPO_GPG_KEY_NAME}" ]; then
        find ${REPO_PATH} -type f -name 'repomd.xml' -print |
        while read repomd; do
            rm -f ${repomd}.asc
            echo "${REPO_GPG_PASSPHRASE}" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 -a --detach-sign --default-key "${REPO_GPG_KEY_NAME}" ${repomd}
            cp -f /var/repo.key ${repomd}.key
        done
    fi
}

function serveRepos(){
    ssl=""
    [ "${REPO_PROTO}" = "https" ] && ssl=" ssl"
    echo -e "> Serving repositories... (on ${REPO_PROTO}://0.0.0.0:${REPO_PORT})"
    sed -i "s/listen.*;$/listen ${REPO_PORT}${ssl};/g" /etc/nginx/conf.d/repo.conf
    if [ -n "${REPO_CERT}" ]; then
        sed -i "/listen.*;$/a \ \ \ \ ssl_certificate ${REPO_CERT};" /etc/nginx/conf.d/repo.conf
    fi
    if [ -n "${REPO_KEY}" ]; then
        sed -i "/listen.*;$/a \ \ \ \ ssl_certificate_key ${REPO_KEY};" /etc/nginx/conf.d/repo.conf
    fi

    exec nginx &
}

importGpgKey
serveRepos
createRepos

LOCKFILE_DIR=/tmp/inotify
LOCKFILE=$LOCKFILE_DIR/.inotify.lock
mkdir -p $LOCKFILE_DIR
rm -rf $LOCKFILE

inotifywait -m -r -e create -e delete -e delete_self --excludei '(repodata|.*xml)' ${REPO_PATH}/ |
while read path action file; do
    echo -e "> Repository content was changed:   path: $path, action: $action, file: $file"
    
    if [ -e "$LOCKFILE" ]
    then
        continue
    else
        touch $LOCKFILE
        echo "Waiting for additional changes..." && sleep 1 && rm -rf $LOCKFILE && inotifywait -t 4 $LOCKFILE_DIR || createRepos &
    fi
done
