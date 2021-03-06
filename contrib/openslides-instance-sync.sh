#!/bin/bash

# This script is a simple way to keep local OpenSlides instances up to date
# with remote instances.  The purpose of this is to maintain backup instances
# to switch over to in case of problems on the remote.
#
# The synchronization process is very simple (ssh + rsync) and requires a cron
# setup.  The database is "synchronized" using SQL dumps; there is no streaming
# etc.  The synchronizing server needs to have SSH access to the main server.
#
# The local instances' states should be left up to this script as it has to
# drop and recreate the openslides table.
#
# In order to access synchronized local instances, e.g., in order to verify
# that the synchronization is working, do not start it.  Create and start
# a clone instead.

set -e
set -o pipefail

usage () {
cat << EOF
$0 <from hostname> <to hostname>

This is a one-way mirroring script for OpenSlides Docker instances.

It refuses to run if both hostnames resolve to localhost because it is assumed
that in such a case a failover event has happened.

Example:

  $0 production.openlides.example.com synctarget.server2.example.com
EOF
}

verbose() {
  printf "INFO: %s\n" "$*"
}

# check args
[[ $# -eq 2 ]] || { usage; exit 2; }

BASEDIR="/srv/openslides/docker-instances"
FROM="$1"
TO="$2"

[[ -n "$FROM" ]] || exit 23
[[ -n "$TO" ]] || exit 23

REMOTE="$(host "$FROM" |
  awk '/has address/ { print $4; exit; }
       /has IPv6 address/ { print $5; exit }'
)"

[[ -n "$REMOTE" ]] || exit 23

# check if remote is really (still) remote.  This may change
# in case of failover IPs.
ip address show | awk -v ip="$REMOTE" -v from="$FROM" '
  $1 ~ /^inet/ && $2 ~ ip {
    printf("ERROR: %s (%s) routes to this host.\n", from, ip)
    exit 3
  }'

FROM="${BASEDIR}/${FROM}/"
TO="${BASEDIR}/${TO}/"

cd "${TO}/"

verbose "linking volume in local instance"
if [[ ! -h personal_data ]]; then
  dir=$(
    docker inspect --format \
      "{{ range .Mounts }}{{ if eq .Destination \"/app/personal_data\" }}{{ .Source }}{{ end }}{{ end }}" \
      "$(docker-compose ps -q server)"
    )
  echo "Linking personal_data in $PWD."
  ln -s "$dir" personal_data
fi

verbose "Remote: dumping DB and linking personal_data"
ssh -T "${REMOTE}" bash << EOF
set -e
cd "${FROM}/"

# dump DB
docker exec -u postgres "\$(docker-compose ps -q postgres)" \
  /bin/bash -c "pg_dump --clean openslides" > latest.sql

# link personal_data
if [[ ! -h personal_data ]]; then
  dir=\$(
    docker inspect --format \
      "{{ range .Mounts }}{{ if eq .Destination \"/app/personal_data\" }}{{ .Source }}{{ end }}{{ end }}" \
      "\$(docker-compose ps -q server)"
    )
  echo "Linking personal_data in \$PWD."
  ln -s "\$dir" personal_data
fi
EOF

verbose "Downloading main instance files"
rsync -ax --compress --del \
  --exclude=settings.py \
  --exclude=personal_data \
  --exclude=metadata.txt \
  --exclude="*.swp" \
  "${REMOTE}:${FROM}/" ./

# personal_data sync (separate so we can use -x both times)
verbose "Creating instance (network, volumes)"
docker-compose up --no-start # Make sure volumes exist
verbose "Sync personal_data files"
rsync -ax "${REMOTE}:${FROM}/personal_data/" ./personal_data/

# prepare DB import
verbose "Starting/stopping services"
docker-compose stop server prioserver client
docker-compose up -d --no-deps postgres

verbose "Importing DB"
docker exec -i -u postgres "$(docker-compose ps -q postgres)" bash -c \
  "psql openslides" < latest.sql > import.log

verbose "Done."
