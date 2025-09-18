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

# BACKUP_ONLY mode (optional)
BACKUP_ONLY="${BACKUP_ONLY:-false}"
is_backup_only="false"
case "$BACKUP_ONLY" in
  [Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|1) is_backup_only="true" ;;
esac
if [ "$is_backup_only" = "true" ]; then
  write_ok "BACKUP_ONLY mode enabled: will perform backup snapshot only and skip restore"
fi

section "Checking RESTORE_RDB_PATH (optional)"
if [ -n "$RESTORE_RDB_PATH" ]; then
  write_ok "RESTORE_RDB_PATH detected: $RESTORE_RDB_PATH"
  if [ "$is_backup_only" = "true" ]; then
    write_warn "BACKUP_ONLY is enabled: RESTORE_RDB_PATH will be ignored"
  fi
fi

section "Checking if SOURCE_REDIS_URL is set and not empty"

# Validate SOURCE_REDIS_URL
if [ "$is_backup_only" = "true" ]; then
  if [ -z "$SOURCE_REDIS_URL" ]; then
    error_exit "BACKUP_ONLY is enabled, but SOURCE_REDIS_URL is not set."
  fi
  write_ok "SOURCE_REDIS_URL correctly set"
else
  if [ -z "$RESTORE_RDB_PATH" ]; then
    if [ -z "$SOURCE_REDIS_URL" ]; then
      error_exit "SOURCE_REDIS_URL environment variable is not set and RESTORE_RDB_PATH is not provided."
    fi
    write_ok "SOURCE_REDIS_URL correctly set"
  else
    write_warn "Skipping SOURCE_REDIS_URL validation because RESTORE_RDB_PATH is set"
  fi
fi

section "Checking if TARGET_REDIS_URL is set and not empty"

if [ "$is_backup_only" = "true" ]; then
  write_warn "Skipping TARGET_REDIS_URL validation because BACKUP_ONLY is enabled"
else
  # Validate that TARGET_REDIS_URL environment variable exists
  if [ -z "$TARGET_REDIS_URL" ]; then
      error_exit "TARGET_REDIS_URL environment variable is not set."
  fi

  write_ok "TARGET_REDIS_URL correctly set"
fi

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
  if [ "$is_backup_only" = "true" ]; then
    error_exit "BACKUP_ONLY mode requires BACKUP_ENABLED=true. Enable backups or disable BACKUP_ONLY."
  fi
  write_warn "Backups are disabled (BACKUP_ENABLED=$BACKUP_ENABLED)"
fi

# Compute timestamp
if [ "$BACKUP_TIMESTAMP_TZ" = "UTC" ]; then
  ts=$(date -u +%Y%m%d-%H%M%S)
else
  ts=$(date +%Y%m%d-%H%M%S)
fi

if [ "$is_backup_only" != "true" ]; then
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
else
  write_warn "Skipping target database state check because BACKUP_ONLY is enabled"
fi

dump_file="/data/redis_dump.rdb"
did_dump="false"

if [ "$is_backup_only" = "true" ]; then
  section "Dumping database from SOURCE_REDIS_URL (backup-only mode)"

  redis-cli -u $SOURCE_REDIS_URL --rdb "$dump_file" || error_exit "Failed to dump database from $SOURCE_REDIS_URL."

  write_ok "Successfully saved dump to $dump_file"
  did_dump="true"
elif [ -n "$RESTORE_RDB_PATH" ]; then
  section "Using provided RDB file (RESTORE_RDB_PATH)"
  src="$RESTORE_RDB_PATH"
  if [ ! -f "$src" ] && [ -f "${BACKUP_DIR%/}/$src" ]; then
    src="${BACKUP_DIR%/}/$src"
  fi
  if [ ! -f "$src" ]; then
    error_exit "RESTORE_RDB_PATH file not found: $RESTORE_RDB_PATH (also checked in $BACKUP_DIR)"
  fi
  case "$src" in
    *.rdb) cp -f "$src" "$dump_file" || error_exit "Failed to copy $src" ;;
    *.rdb.gz|*.gz) gunzip -c "$src" > "$dump_file" || error_exit "Failed to decompress $src" ;;
    *) error_exit "RESTORE_RDB_PATH must point to .rdb or .rdb.gz" ;;
  esac
  write_ok "Selected restore source: $src"
else
  section "Dumping database from SOURCE_REDIS_URL"

  redis-cli -u $SOURCE_REDIS_URL --rdb "$dump_file" || error_exit "Failed to dump database from $SOURCE_REDIS_URL."

  write_ok "Successfully saved dump to $dump_file"
  did_dump="true"
fi

dump_file_size=$(ls -lh "$dump_file" | awk '{print $5}')

write_ok "Dump file size: $dump_file_size"

# Save backup copy (compressed by policy)
if [ "$is_backup_enabled" = "true" ] && [ "$did_dump" = "true" ]; then
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

# In backup-only mode, skip restore and exit after listing backups
if [ "$is_backup_only" = "true" ]; then
  section "Backup-only mode: skipping restore steps"

  section "Cleaning up"
  if [ -f "$dump_file" ]; then
    write_ok "Removing $dump_file"
    rm -f "$dump_file"
    write_ok "Successfully removed $dump_file"
  fi

  section "Listing available backups in $BACKUP_DIR"
  pattern="${BACKUP_PREFIX}_*.rdb*"
  if [ -d "$BACKUP_DIR" ]; then
    files=$(ls -1t "$BACKUP_DIR"/$pattern 2>/dev/null || true)
    if [ -n "$files" ]; then
      ls -lh -t "$BACKUP_DIR"/$pattern 2>/dev/null
    else
      write_warn "No backups found matching ${pattern} in $BACKUP_DIR"
    fi
  else
    write_warn "BACKUP_DIR '$BACKUP_DIR' does not exist"
  fi

  printf "${_RESET}\n"
  printf "${_RESET}\n"
  echo "${_BOLD}${_GREEN}Backup completed successfully${_RESET}"
  printf "${_RESET}\n"
  printf "${_RESET}\n"
  exit 0
fi

section "Converting RDB to AOF (RESP)"

protocol_file="/data/redis_dump.protocol"

rdb -c aof -o "$protocol_file" "$dump_file" || error_exit "Failed to convert RDB to AOF (protocol)."

write_ok "Converted RDB to AOF protocol file"

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

section "Listing available backups in $BACKUP_DIR"
pattern="${BACKUP_PREFIX}_*.rdb*"
if [ -d "$BACKUP_DIR" ]; then
  files=$(ls -1t "$BACKUP_DIR"/$pattern 2>/dev/null || true)
  if [ -n "$files" ]; then
    ls -lh -t "$BACKUP_DIR"/$pattern 2>/dev/null
  else
    write_warn "No backups found matching ${pattern} in $BACKUP_DIR"
  fi
else
  write_warn "BACKUP_DIR '$BACKUP_DIR' does not exist"
fi

printf "${_RESET}\n"
printf "${_RESET}\n"
echo "${_BOLD}${_GREEN}Migration completed successfully${_RESET}"
printf "${_RESET}\n"
printf "${_RESET}\n"
