#!/bin/bash

set -o pipefail

export TERM=ansi
_GREEN=$(tput setaf 2)
_BLUE=$(tput setaf 4)
_MAGENTA=$(tput setaf 5)
_CYAN=$(tput setaf 6)
_RED=$(tput setaf 1)
_YELLOW=$(tput setaf 3)
_RESET=$(tput sgr0)
_BOLD=$(tput bold)

# Function to print error messages and exit
error_exit() {
    printf "[ ${_RED}ERROR${_RESET} ] ${_RED}$1${_RESET}\n" >&2
    # Keeping exit code 0 to preserve existing behavior with external cron/CI
    exit 0
}

section() {
  printf "${_RESET}\n"
  echo "${_BOLD}${_BLUE}==== $1 ====${_RESET}"
}

write_ok() {
  echo "[$_GREEN OK $_RESET] $1"
}

write_warn() {
  echo "[$_YELLOW WARN $_RESET] $1"
}

trap 'echo "An error occurred. Exiting..."; exit 0;' ERR

printf "${_BOLD}${_MAGENTA}"
echo "+----------------------------------+"
echo "|                                  |"
echo "|  Railway Redis Migrator Script   |"
echo "|                                  |"
echo "+----------------------------------+"
printf "${_RESET}\n"

section "Validating environment variables"

section "Checking if SOURCE_REDIS_URL is set and not empty"

# Validate that SOURCE_REDIS_URL environment variable exists
if [ -z "$SOURCE_REDIS_URL" ]; then
    error_exit "SOURCE_REDIS_URL environment variable is not set."
fi

write_ok "SOURCE_REDIS_URL correctly set"

section "Checking if TARGET_REDIS_URL is set and not empty"

# Validate that TARGET_REDIS_URL environment variable exists
if [ -z "$TARGET_REDIS_URL" ]; then
    error_exit "TARGET_REDIS_URL environment variable is not set."
fi

write_ok "TARGET_REDIS_URL correctly set"

# Backup configuration (with defaults)
section "Preparing backup configuration"

BACKUP_ENABLED="${BACKUP_ENABLED:-true}"
BACKUP_DIR="${BACKUP_DIR:-/backup}"
BACKUP_PREFIX="${BACKUP_PREFIX:-redis-backup}"
BACKUP_COMPRESS="${BACKUP_COMPRESS:-gzip}"        # gzip | none
BACKUP_RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-7}" # keep last N backups (set empty to disable)
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-}"   # delete older than D days (set empty to disable)
BACKUP_TIMESTAMP_TZ="${BACKUP_TIMESTAMP_TZ:-UTC}"    # UTC | local

# Normalize boolean
is_backup_enabled="false"
case "$BACKUP_ENABLED" in
  [Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|1) is_backup_enabled="true" ;;
esac

if [ "$is_backup_enabled" = "true" ]; then
  mkdir -p "$BACKUP_DIR" || error_exit "Failed to create BACKUP_DIR '$BACKUP_DIR'."
  if [ ! -w "$BACKUP_DIR" ]; then
    error_exit "BACKUP_DIR '$BACKUP_DIR' is not writable."
  fi
  write_ok "Backups enabled. Directory: $BACKUP_DIR"
  write_ok "Compression: $BACKUP_COMPRESS"
  if [ -n "$BACKUP_RETENTION_DAYS" ]; then
    write_ok "Retention (days): $BACKUP_RETENTION_DAYS"
  else
    write_warn "Retention (days) not set"
  fi
  if [ -n "$BACKUP_RETENTION_COUNT" ]; then
    write_ok "Retention (count): $BACKUP_RETENTION_COUNT"
  else
    write_warn "Retention (count) not set"
  fi
else
  write_warn "Backups are disabled (BACKUP_ENABLED=$BACKUP_ENABLED)"
fi

# Compute timestamp
if [ "$BACKUP_TIMESTAMP_TZ" = "UTC" ]; then
  ts=$(date -u +%Y%m%d-%H%M%S)
else
  ts=$(date +%Y%m%d-%H%M%S)
fi

# Query to check if there are any tables in the new database
output=$(echo 'DBSIZE' | redis-cli -u $TARGET_REDIS_URL)

if [[ "$output" == *"0"* ]]; then
  write_ok "The new database is empty. Proceeding with restore."
else
  if [ -z "$OVERWRITE_DATABASE" ]; then
    error_exit "The new database is not empty. Aborting migration.
Set the OVERWRITE_DATABASE environment variable to overwrite the new database."
  fi
  write_warn "The new database is not empty. Found OVERWRITE_DATABASE environment variable. Proceeding with restore."
fi

section "Dumping database from SOURCE_REDIS_URL"

dump_file="/data/redis_dump.rdb"

redis-cli -u $SOURCE_REDIS_URL --rdb "$dump_file" || error_exit "Failed to dump database from $SOURCE_REDIS_URL."

write_ok "Successfully saved dump to $dump_file"

dump_file_size=$(ls -lh "$dump_file" | awk '{print $5}')

write_ok "Dump file size: $dump_file_size"

# Save backup copy (compressed by policy)
if [ "$is_backup_enabled" = "true" ]; then
  section "Saving backup snapshot to $BACKUP_DIR"

  # Base backup filename (without compression suffix)
  backup_base="${BACKUP_DIR%/}/${BACKUP_PREFIX}_${ts}.rdb"

  # Copy RDB to backup directory first
  cp -f "$dump_file" "$backup_base" || error_exit "Failed to copy dump to backup path '$backup_base'."
  chmod 640 "$backup_base" 2>/dev/null || true

  backup_path="$backup_base"
  case "$BACKUP_COMPRESS" in
    gzip|GZIP)
      gzip -f -9 "$backup_base" || error_exit "Failed to gzip backup '$backup_base'."
      backup_path="${backup_base}.gz"
      ;;
    none|NONE)
      ;;
    *)
      write_warn "Unknown BACKUP_COMPRESS '$BACKUP_COMPRESS', defaulting to gzip"
      gzip -f -9 "$backup_base" || error_exit "Failed to gzip backup '$backup_base'."
      backup_path="${backup_base}.gz"
      ;;
  esac

  if [ -f "$backup_path" ]; then
    backup_size=$(ls -lh "$backup_path" | awk '{print $5}')
    write_ok "Backup saved: $backup_path (size: $backup_size)"
  else
    error_exit "Backup file '$backup_path' not found after save."
  fi

  section "Applying retention policy"

  pattern="${BACKUP_PREFIX}_*.rdb*"

  # Retention by days (delete strictly older than D days)
  if [ -n "$BACKUP_RETENTION_DAYS" ]; then
    write_ok "Deleting backups older than $BACKUP_RETENTION_DAYS day(s) matching ${pattern}"
    # -maxdepth 1 to avoid subdirs
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "$pattern" -mtime +"$BACKUP_RETENTION_DAYS" -print -delete 2>/dev/null | while read -r removed; do
      [ -n "$removed" ] && write_ok "Removed (by days): $removed"
    done
  fi

  # Retention by count (keep N newest)
  if [ -n "$BACKUP_RETENTION_COUNT" ] && [ "$BACKUP_RETENTION_COUNT" -gt 0 ] 2>/dev/null; then
    # List matching files sorted by mtime descending, drop first N, delete the rest
    del_list=$(ls -1t "$BACKUP_DIR"/${BACKUP_PREFIX}_*.rdb* 2>/dev/null | tail -n +$((BACKUP_RETENTION_COUNT + 1)))
    if [ -n "$del_list" ]; then
      echo "$del_list" | while read -r f; do
        rm -f "$f" && write_ok "Removed (by count): $f"
      done
    else
      write_ok "No excess backups to remove by count"
    fi
  fi
fi

section "Converting RDB to Redis protocol"

protocol_file="/data/redis_dump.protocol"

rdb -c protocol "$dump_file" > "$protocol_file" || error_exit "Failed to convert RDB to protocol."

write_ok "Converted rdb to protocol file"

section "Restoring database to TARGET_REDIS_URL"

# Restore that data to the new database
redis-cli -u $TARGET_REDIS_URL --pipe < "$protocol_file" || error_exit "Failed to restore to $TARGET_REDIS_URL."

write_ok "Successfully restored database to TARGET_REDIS_URL"

section "Cleaning up"

if [ -f "$dump_file" ]; then
  write_ok "Removing $dump_file"
  rm -f "$dump_file"
  write_ok "Successfully removed $dump_file"
fi

if [ -f "$protocol_file" ]; then
  write_ok "Removing $protocol_file"
  rm -f "$protocol_file"
  write_ok "Successfully removed $protocol_file"
fi

write_ok "Successfully cleaned up"

printf "${_RESET}\n"
printf "${_RESET}\n"
echo "${_BOLD}${_GREEN}Migration completed successfully${_RESET}"
printf "${_RESET}\n"
printf "${_RESET}\n"
