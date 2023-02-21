#!/bin/bash
#  set shell options for more robust and reliable shell scripts.
set -euo pipefail


if [ "$#" -ne 1 ]; then
    echo "usage: <import|run>"
    echo "commands:"
    echo "    import: Set up the database and import /data/region.osm.pbf"
    echo "    run: Runs Apache and renderd to serve tiles at /tile/{z}/{x}/{y}.png"
    echo "environment variables:"
    echo "    THREADS: defines number of threads used for importing / tile rendering"
    echo "    UPDATES: consecutive updates (enabled/disabled)"
    echo "    NAME_LUA: name of .lua script to run as part of the style"
    echo "    NAME_STYLE: name of the .style to use"
    echo "    NAME_MML: name of the .mml file to render to mapnik.xml"
    echo "    NAME_SQL: name of the .sql file to use"
    exit 1
fi

set -x

# if there is no custom style mounted, then use osm-carto
if [ ! "$(ls -A /data/style/)" ]; then
    mv /home/renderer/src/openstreetmap-carto-backup/* /data/style/
fi

# carto build
if [ ! -f /data/style/mapnik.xml ]; then
    cd /data/style/
    carto ${NAME_MML:-project.mml} > mapnik.xml
fi


if [ "$1" == "run" ]; then
    # Clean /tmp
    rm -rf /tmp/*


    # Configure Apache CORS
    if [ "${ALLOW_CORS:-}" == "enabled" ] || [ "${ALLOW_CORS:-}" == "1" ]; then
        echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" >> /etc/apache2/envvars
    fi

    # Initialize PostgreSQL and Apache
    createPostgresConfig
    service postgresql start
    service apache2 restart
    setPostgresPassword

    # Configure renderd threads
    sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS:-4}/g" /etc/renderd.conf

    # start cron job to trigger consecutive updates
    if [ "${UPDATES:-}" == "enabled" ] || [ "${UPDATES:-}" == "1" ]; then
        /etc/init.d/cron start
        sudo -u renderer touch /var/log/tiles/run.log; tail -f /var/log/tiles/run.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/osmosis.log; tail -f /var/log/tiles/osmosis.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/expiry.log; tail -f /var/log/tiles/expiry.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/osm2pgsql.log; tail -f /var/log/tiles/osm2pgsql.log >> /proc/1/fd/1 &

    fi

    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sudo -u renderer renderd -f -c /etc/renderd.conf &
    child=$!
    wait "$child"

    service postgresql stop

    exit 0
fi

echo "invalid command"
exit 1
