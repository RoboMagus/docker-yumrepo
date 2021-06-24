#!/usr/bin/env sh

CONTAINER_IP=$(ip addr show eth0 | awk '$1 == "inet" {gsub(/\/.*$/, "", $2); print $2}')
NGINX_PID=undef

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

function printRepoConf(){
    echo -e "------------------------------------------------------\nAdd this config to '/etc/yum.repos.d/container.repo' on the Client:\n------------------------------------------------------"
    gpgcheck=0
    [ -n "${REPO_GPG_KEY_NAME}" ] && gpgcheck=1
    echo -e "\n\ncat << EOF > /etc/yum.repos.d/container.repo\n\
[container]\n\
name=Container Repo\n\
baseurl=${REPO_PROTO}://${CONTAINER_IP}/\\\$releasever/\\\$basearch/\n\
gpgcheck=${gpgcheck}\n\
EOF\n\n\n------------------------------------------------------"
    echo -e "Then run: yum --disablerepo=* --enablerepo=container <action> <package>\n------------------------------------------------------\n"
}

function createRepos(){
    echo -e "> Creating repository indexes... (repo maxdepth ${REPO_DEPTH})"

    # for gpg-signed repos, createrepo_c seems to call 'cp' for the repomd.xml.{asc,key} files using options not currently supported by busybox 'cp'
    # - as a workaround delete these files before calling createrepo_c - they will be recreated afterwards anyway
    [ -n "${REPO_GPG_KEY_NAME}" ] && find ${REPO_PATH} -name 'repomd.xml.*' -type f -exec rm {} \;

    find ${REPO_PATH} -type d -maxdepth ${REPO_DEPTH} -mindepth ${REPO_DEPTH} -exec createrepo_c {} \;

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
printRepoConf
createRepos
serveRepos

inotifywait -m -r -e create -e delete -e delete_self --excludei '(repodata|.*xml)' ${REPO_PATH}/ |
while read path action file; do
    echo -e "> Repository content was changed..."
    createRepos
done
