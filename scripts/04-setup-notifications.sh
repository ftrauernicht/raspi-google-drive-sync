#!/bin/bash
# Set up msmtp for outgoing notification email.
#
# Recommendation: use a SEPARATE Google account dedicated only to sending
# these notifications — not the account being backed up. See
# docs/architecture.md for the reasoning (decoupling the alert channel from
# the thing being monitored, plus a note on Google's account-inactivity
# policy for accounts that are only ever used for outbound SMTP).
#
# Prerequisite on the sending account: 2-Step Verification enabled, and an
# App Password generated at myaccount.google.com/apppasswords (since May
# 2025, Google requires an App Password or OAuth for SMTP — a plain account
# password will not work). Also consider setting up that account's
# "Inactive Account Manager" (myaccount.google.com/inactive) at ~6-12
# months, action "notify only", pointed at your real address — a purely
# automated-sending account risks Google's 2-year inactivity deletion
# policy otherwise.
set -e

DEBIAN_FRONTEND=noninteractive apt-get install -y msmtp msmtp-mta ca-certificates

SENDER_EMAIL='<SENDER_GMAIL_ADDRESS>'
APP_PASSWORD='<APP_PASSWORD_NO_SPACES>'
RECIPIENT_ADDRESS='<RECIPIENT_ADDRESS>'

cat > /etc/msmtprc <<EOF
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        gmail-notify
host           smtp.gmail.com
port           587
from           $SENDER_EMAIL
user           $SENDER_EMAIL
password       $APP_PASSWORD

account default : gmail-notify
EOF

chown root:root /etc/msmtprc
chmod 600 /etc/msmtprc

mkdir -p /etc/drive-backup
echo "$RECIPIENT_ADDRESS" > /etc/drive-backup/recipients.txt

# Test:
printf 'Subject: Test\n\nTest mail from the backup device.\n' | msmtp "$RECIPIENT_ADDRESS"
