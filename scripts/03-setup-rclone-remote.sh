#!/bin/bash
# Set up the rclone remote "gdrive" — read-only access to Google Drive.
# This backup device should NEVER need write access to the cloud, so the
# OAuth scope is deliberately restricted to drive.readonly: even if the
# client secret or token ever leaked, the worst case is someone can read
# your Drive, not modify or delete anything in it.
#
# Prerequisite: your own Google OAuth client (Desktop app type), with the
# OAuth consent screen set to "In production" (not "Testing" — Testing-mode
# refresh tokens expire after 7 days). See docs/setup-guide.md step 3.
#
# 1) On a machine WITH a browser (not the headless Pi), fetch a token:
#    rclone authorize "drive" --drive-scope drive.readonly "<CLIENT_ID>" "<CLIENT_SECRET>"
#    -> opens a browser; after login/consent, prints a token JSON blob.
#
# 2) On the Pi, do NOT create the remote interactively with `rclone config
#    create` — even with a token supplied, it still tries to open a browser
#    unless you pass --non-interactive, and hangs forever on a headless
#    machine (no xdg-open). Always pass --non-interactive:

CLIENT_ID='<CLIENT_ID>'
CLIENT_SECRET='<CLIENT_SECRET>'
TOKEN='<TOKEN_JSON_FROM_STEP_1>'

rclone config create gdrive drive \
  --non-interactive \
  client_id="$CLIENT_ID" \
  client_secret="$CLIENT_SECRET" \
  scope=drive.readonly \
  token="$TOKEN"

# 3) Verify:
rclone about gdrive:
rclone lsd gdrive: --max-depth 1
