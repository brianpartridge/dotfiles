#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

export PATH=/usr/local/bin:$PATH

BITBUCKET_DOMAIN='git.sqcorp.co'
SERVICE='sq-bitbucket'
PW=`security find-generic-password -ga $USER -s $SERVICE 2>&1 | grep "password:" | tail -n 1 | cut -d ' ' -f 2 | sed 's/"//g'`

JSON=`curl -s -X GET --user $USER:$PW https://$BITBUCKET_DOMAIN/rest/api/1.0/inbox/pull-requests`
SANITIZED=`echo "$JSON" | jq '[.values[] | {title: .title, by: .author.user.name, url: .links.self[0].href, state: .state, reviewers: [.reviewers[] | {user: .user.name, status: .status}], properties: .properties, from: .fromRef.displayId, to: .toRef.displayId}]'`
FILTERED=$SANITIZED # `echo $SANITIZED | jq '[.[] | select(.properties.mergeResult.outcome | contains("CONFLICTED"))]'`
FORMATTED=`echo "$FILTERED" | jq '.[] | "\(.title) | href=\(.url)"' | sed 's/^"//g' | sed 's/"$//g'`
COUNT=`echo "$FORMATTED" | wc -l | xargs`

echo "PR Inbox ($COUNT)"
echo '---'
echo "$FORMATTED"

# ideas
# - plugin that shows my currently open PRs and whether they are mergable

# distilled inbox PRs
#curl -X GET --user $USER:$PW https://git.sqcorp.co/rest/api/1.0/inbox/pull-requests | jq '[].values[] | {title: .title, by: .author.user.name, url: .links.self[0].href, state: .state, reviewers: [.reviewers[] | {user: .user.name, status: .status}], properties: .properties, from: .fromRef.displayId, to: .toRef.displayId}]'