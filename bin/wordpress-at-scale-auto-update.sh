#!/bin/bash

MULTIDEV="updates"

UPDATES_APPLIED=true

# login to Terminus
echo -e "\nLogging into Terminus..."
terminus auth login --machine-token=${TERMINUS_MACHINE_TOKEN}

# delete the multidev environment
echo -e "\nDeleting the ${MULTIDEV} multidev environment..."
terminus site delete-env --remove-branch --yes

# recreate the multidev environment
echo -e "\nRe-creating the ${MULTIDEV} multidev environment..."
terminus site create-env --from-env=live --to-env=${MULTIDEV}

# check for upstream updates
echo -e "\nChecking for upstream updates on the ${MULTIDEV} multidev..."
# the output goes to stderr, not stdout
UPSTREAM_UPDATES=$(terminus site upstream-updates list  --format=bash  2>&1)

if [[ ${UPSTREAM_UPDATES} == *"No updates"* ]]
then
    # no upstream updates available
    echo -e "\nNo upstream updates found on the ${MULTIDEV} multidev..."
else
	# making sure the multidev is in git mode
	echo -e "\nSetting the ${MULTIDEV} multidev to git mode"
	terminus site set-connection-mode --mode=git
	
    # apply WordPress upstream updates
    echo -e "\nApplying upstream updates on the ${MULTIDEV} multidev..."
    terminus site upstream-updates apply --yes --updatedb --accept-upstream --env=${MULTIDEV}
    UPDATES_APPLIED=true
fi

# making sure the multidev is in SFTP mode
echo -e "\nSetting the ${MULTIDEV} multidev to SFTP mode"
terminus site set-connection-mode --mode=sftp

# check for WordPress plugin updates
echo -e "\nChecking for WordPress plugin updates on the ${MULTIDEV} multidev..."
PLUGIN_UPDATES=$(terminus wp "plugin list --field=update" --format=bash)

if [[ ${PLUGIN_UPDATES} == *"available"* ]]
then
    # update WordPress plugins
    echo -e "\nUpdating WordPress plugins on the ${MULTIDEV} multidev..."
    terminus wp "plugin update --all"

    # committing updated WordPress plugins
    echo -e "\nCommitting WordPress plugin updates on the ${MULTIDEV} multidev..."
    terminus site code commit --message="update WordPress plugins" --yes
    UPDATES_APPLIED=true
else
    # no WordPress plugin updates found
    echo -e "\nNo WordPress plugin updates found on the ${MULTIDEV} multidev..."
fi

# check for WordPress theme updates
echo -e "\nChecking for WordPress theme updates on the ${MULTIDEV} multidev..."
THEME_UPDATES=$(terminus wp "theme list --field=update" --format=bash)

if [[ ${THEME_UPDATES} == *"available"* ]]
then
    # update WordPress themes
    echo -e "\nUpdating WordPress plugins on the ${MULTIDEV} multidev..."
    terminus wp "theme update --all"

    # committing updated WordPress themes
    echo -e "\nCommitting WordPress theme updates on the ${MULTIDEV} multidev..."
    terminus site code commit --message="update WordPress themes" --yes
    UPDATES_APPLIED=true
else
    # no WordPress theme updates found
    echo -e "\nNo WordPress theme updates found on the ${MULTIDEV} multidev..."
fi

if [[ "${UPDATES_APPLIED}" = false ]]
then
    # no updates applied
    echo -e "\nNo updates to apply..."
    SLACK_MESSAGE="valet.io Circle CI update check #${CIRCLE_BUILD_NUM} by ${CIRCLE_PROJECT_USERNAME}. No updates to apply, nothing deployed."
    echo -e "\nSending a message to the ${SLACK_CHANNEL} Slack channel"
    # curl -X POST --data "payload={\"channel\": \"${SLACK_CHANNEL}\", \"username\": \"${SLACK_USERNAME}\", \"text\": \"${SLACK_MESSAGE}\"}" $SLACK_HOOK_URL
else
    # updates applied, carry on

    # install node dependencies
    echo -e "\nRunning npm install..."
    npm install

    # ping the multidev environment to wake it from sleep
    echo -e "\nPinging the ${MULTIDEV} multidev environment to wake it from sleep..."
    curl -I ${REF_HOST}

    # backstop visual regression
    echo -e "\nRunning BackstopJS tests..."

    cwd=$(pwd)
    export PATH="$(pwd)/node_modules/.bin:$PATH"

    backstop reference --configPath=backstop-settings.js --refhost=${REF_HOST} --paths=${REF_PATHS}

    VISUAL_REGRESSION_RESULTS=$(backstop test --configPath=backstop-settings.js --testhost=${TEST_HOST} --paths=${TEST_PATHS})

    echo "${VISUAL_REGRESSION_RESULTS}"
    
    echo "Rsyncing Backstop results to artifacts directory"
    rsync  -rlvz   /home/ubuntu/wordpress-at-scale-auto-update/backstop_data $CIRCLE_ARTIFACTS/backstop

    cd -
    if [[ ${VISUAL_REGRESSION_RESULTS} == *"Mismatch errors found"* ]]
    then
        # visual regression failed
        echo -e "\nVisual regression tests failed! Please manually check the ${MULTIDEV} multidev..."
        SLACK_MESSAGE="valet.io Circle CI update check #${CIRCLE_BUILD_NUM} by ${CIRCLE_PROJECT_USERNAME}. Visual regression tests failed on <https://dashboard.pantheon.io/sites/${SITE_UUID}#${MULTIDEV}/code|the ${MULTIDEV} environment>! Please test manually."
        echo -e "\nSending a message to the ${SLACK_CHANNEL} Slack channel"
        # curl -X POST --data "payload={\"channel\": \"${SLACK_CHANNEL}\", \"username\": \"${SLACK_USERNAME}\", \"text\": \"${SLACK_MESSAGE}\"}" $SLACK_HOOK_URL
        exit 1
    else
        # visual regression passed
        echo -e "\nVisual regression tests passed between the ${MULTIDEV} multidev and live."

        # enable git mode on dev
        echo -e "\nEnabling git mode on the dev environment..."
        terminus site set-connection-mode --env=dev --mode=git --yes

        # merge the multidev back to dev
        echo -e "\nMerging the ${MULTIDEV} multidev back into the dev environment (master)..."
        terminus site merge-to-dev
    fi
fi