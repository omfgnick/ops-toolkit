#!/bin/bash

# Set the source and destination directories
SRC_DIR="/path/to/source/directory"
DST_DIR="/path/to/destination/directory"

# Set the email recipient
EMAIL_RECIPIENT="example@example.com"

# Set the email subject
EMAIL_SUBJECT="Backup Status"

# Create a temporary directory for the backup
TMP_DIR=$(mktemp -d)

# Create a log file for the backup
LOG_FILE="$TMP_DIR/backup.log"

# Function to send an email
send_email() {
  echo "Sending email to $EMAIL_RECIPIENT..."
  echo "Subject: $EMAIL_SUBJECT"
  echo "Backup executed with status: $1"
  echo "Log file: $LOG_FILE"
  /usr/sbin/sendmail -t -i $EMAIL_RECIPIENT < /dev/null
}

# Create a hash file for the source directory
echo "Creating hash file for source directory..."
find "$SRC_DIR" -type f -exec md5sum {} \; > "$TMP_DIR/source.hash"

# Create a hash file for the destination directory
echo "Creating hash file for destination directory..."
find "$DST_DIR" -type f -exec md5sum {} \; > "$TMP_DIR/destination.hash"

# Compare the hash files
echo "Comparing hash files..."
diff "$TMP_DIR/source.hash" "$TMP_DIR/destination.hash" > /dev/null
if [ $? -eq 0 ]; then
  echo "Hash files match, proceeding with backup..."
else
  echo "Hash files do not match, aborting backup..."
  send_email "Failed"
  exit 1
fi

# Create the backup file
echo "Creating backup file..."
tar -czf "$DST_DIR/backup-$(date +'%Y-%m-%d').tar.gz" "$SRC_DIR"

# Verify the integrity of the backup file
echo "Verifying integrity of backup file..."
md5sum "$DST_DIR/backup-$(date +'%Y-%m-%d').tar.gz" > "$TMP_DIR/backup.hash"
diff "$TMP_DIR/backup.hash" "$TMP_DIR/source.hash" > /dev/null
if [ $? -eq 0 ]; then
  echo "Backup file integrity verified..."
else
  echo "Backup file integrity failed..."
  send_email "Failed"
  exit 1
fi

# Send a success email
echo "Backup executed successfully..."
send_email "Success"

# Clean up
rm -rf "$TMP_DIR"
