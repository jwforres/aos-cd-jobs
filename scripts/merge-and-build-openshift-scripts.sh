#!/bin/bash
set -o xtrace

MB_PATH=$(readlink -f $0)
SCRIPTS_DIR=$(dirname $MB_PATH)

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace


function get_version_fields {
    COUNT="$1"

    if [ "$COUNT" == "" ]; then
        echo "Invalid number of Version fields specified: $COUNT"
        return 1
    fi

    V="$(grep Version: openshift-scripts.spec | awk '{print $2}')"
    # e.g. "3.6.126" => "3 6 126" => wc + awk gives number of independent fields
    export CURRENT_COUNT="$(echo ${V} | tr . ' ' | wc | awk '{print $2}')"

    # If there are more fields than we expect, something has gone wrong and needs human attention.
    if [ "$CURRENT_COUNT" -gt "$COUNT" ]; then
        echo "Unexpected number of fields in current version: $CURRENT_COUNT ; expected less-than-or-equal to $COUNT"
        return 1
    fi

    if [ "$CURRENT_COUNT" -lt "$COUNT" ]; then
        echo -n "${V}"
        while [ "$CURRENT_COUNT" -lt "$COUNT" ]; do
            echo -n ".0"
            CURRENT_COUNT=$(($CURRENT_COUNT + 1))
        done
    else
        # Extract the value of the last field
        MINOREST_FIELD="$(echo -n ${V} | rev | cut -d . -f 1 | rev)"
        NEW_MINOREST_FIELD=$(($MINOREST_FIELD + 1))
        # Cut off the minorest version of the version and append the newly calculated patch version
        echo -n "$(echo ${V} | rev | cut -d . -f 1 --complement | rev).$NEW_MINOREST_FIELD"
    fi
}


# Use the directory relative to this Jenkins job.
BUILDPATH="${WORKSPACE}/go"
mkdir -p $BUILDPATH
cd $BUILDPATH
export GOPATH="$( pwd )"
WORKPATH="${BUILDPATH}/src/github.com/openshift/"
mkdir -p $WORKPATH
echo "GOPATH: ${GOPATH}"
echo "BUILDPATH: ${BUILDPATH}"
echo "WORKPATH ${WORKPATH}"

# Kerberos credeneitslf of ocp-build
kinit -k -t /home/jenkins/ocp-build.keytab ocp-build/atomic-e2e-jenkins.rhev-ci-vms.eng.rdu2.redhat.com@REDHAT.COM

rm -rf online
git clone git@github.com:openshift/online.git
cd online/

# Check to see if there have been any changes since the last tag
if git describe --abbrev=0 --tags --exact-match HEAD >/dev/null 2>&1 && [ "${FORCE_REBUILD}" != "true" ] ; then
    echo ; echo "No changes since last tagged build"
    echo "No need to build anything. Stopping."
else

    if [ "${BUILD_MODE}" == "online:int" ] ; then
        SPEC_VERSION_COUNT=4
    elif [ "${BUILD_MODE}" == "online:stg" ] ; then
        git checkout -q stage
        SPEC_VERSION_COUNT=5
    elif [ "${BUILD_MODE}" == "release" ] ; then
        exit 1  # TODO: release_version to build needs to be a parameter to this script
        git checkout -q "online-${RELEASE_VERSION}"
        SPEC_VERSION_COUNT=6
    fi

    export TITO_USE_VERSION="--use-version=$(get_version_fields ${SPEC_VERSION_COUNT})"

    #There have been changes, so rebuild
    echo
    echo "=========="
    echo "Tito Tagging"
    echo "=========="
    tito tag --accept-auto-changelog "${TITO_USE_VERSION}"
    export VERSION="$(grep Version: openshift-scripts.spec | awk '{print $2}')"
    
    git push
    git push --tags

    echo
    echo "=========="
    echo "Tito building in brew"
    echo "=========="
    TASK_NUMBER=`tito release --yes --test brew | grep 'Created task:' | awk '{print $3}'`
    echo "TASK NUMBER: ${TASK_NUMBER}"
    echo "TASK URL: https://brewweb.engineering.redhat.com/brew/taskinfo?taskID=${TASK_NUMBER}"
    echo
    brew watch-task ${TASK_NUMBER}

    echo
    echo "=========="
    echo "Tagging package in brew"
    echo "=========="
    TAG=`git describe --abbrev=0`
    COMMIT=`git log -n 1 --pretty=%h`
    if [ "${BUILD_MODE}" == "online:stg" ] ; then
        brew tag-pkg libra-rhel-7-stage ${TAG}.git.0.${COMMIT}.el7
    elif [ "${BUILD_MODE}" == "online:int" ] ; then
        brew tag-pkg libra-rhel-7-candidate ${TAG}.git.0.${COMMIT}.el7
    else
        echo "Work needs to be done for release BUILD_MODE"  # TODO
        exit 1
    fi

    # tag-pkg seems to work async even though we are not specifying the --nowait argument. 
    # We have seen the push which follows push the old build instead of the new, so
    # using a sleep below to allow brew to get into a consistent state.
    sleep 20

    echo
    echo "=========="
    echo "Build and Push libra repos"
    echo "=========="
    if [ "${BUILD_MODE}" == "online:stg" ] ; then
        ssh ocp-build@rcm-guest.app.eng.bos.redhat.com "/mnt/rcm-guest/puddles/RHAOS/scripts/libra-repo-to-mirrors.sh stage"
    elif [ "${BUILD_MODE}" == "online:int" ] ; then
        ssh ocp-build@rcm-guest.app.eng.bos.redhat.com "/mnt/rcm-guest/puddles/RHAOS/scripts/libra-repo-to-mirrors.sh candidate"
    else
        echo "Work needs to be done for release BUILD_MODE"  # TODO
        exit 1
    fi

    echo
    echo "=========="
    echo "Update Dockerfiles"
    echo "=========="ild
    ose_images.sh --user ocp-build update_docker --branch libra-rhel-7 --group oso --force --release 1 --version "v${VERSION}"

    echo
    echo "=========="
    echo "Sync distgit"
    echo "=========="
    ose_images.sh --user ocp-build compare_nodocker --branch libra-rhel-7 --group oso --force --message "MaxFileSize: 52428800"

    echo
    echo "=========="
    echo "Build Images"
    echo "=========="
    ose_images.sh --user ocp-build build_container --repo http://download-node-02.eng.bos.redhat.com/rcm-guest/puddles/RHAOS/repos/oso-building.repo --branch libra-rhel-7 --group oso

    echo
    echo "=========="
    echo "Push Images"
    echo "=========="
    sudo env "PATH=$PATH" ose_images.sh --user ocp-build push_images --branch libra-rhel-7 --group oso --release 1

fi

echo
echo "=========="
echo "Finished OpenShift scripts"
echo "=========="
