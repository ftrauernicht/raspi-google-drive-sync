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
# Without this, every mail the *system* sends goes to the local user it was
# addressed to - almost always "root" - and a real mail server rejects that
# as not being an address at all. On the device this was written for,
# apt-listchanges mailed a package's NEWS entry to root and the provider
# answered "553 The recipient address <root> is not a valid RFC 5321
# address". Nothing noticed, because the only trace is one line in
# /var/log/msmtp.log. Everything that reports by mail the Unix way -
# apt-listchanges, cron, logrotate, mdadm, unattended-upgrades - lands in
# that same hole until root is mapped to a real address.
aliases        /etc/aliases

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

# "default" is msmtp's catch-all, so a mail to any other local name is
# delivered too instead of being refused by the server.
cat > /etc/aliases <<EOF
root: $RECIPIENT_ADDRESS
default: $RECIPIENT_ADDRESS
EOF
chmod 644 /etc/aliases

mkdir -p /etc/drive-backup
echo "$RECIPIENT_ADDRESS" > /etc/drive-backup/recipients.txt

# Test both paths: a mail addressed directly, and one addressed the way the
# system addresses its own - the second is the one that used to vanish.
printf 'Subject: Test\n\nTest mail from the backup device.\n' | msmtp "$RECIPIENT_ADDRESS"
printf 'Subject: Test (system mail to root)\n\nIf this one arrives, the alias works and system mail is no longer lost.\n' | msmtp root
echo "Both test mails sent. Check /var/log/msmtp.log for 'exitcode=EX_OK' twice."
