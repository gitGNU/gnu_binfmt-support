#! /bin/sh

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
NAME=binfmt-support
DESC="additional executable binary formats"

test -x /usr/sbin/update-binfmts || exit 0

. /lib/lsb/init-functions
. /etc/default/rcS

set -e
CODE=0

case "$1" in
  start)
    log_begin_msg "Enabling $DESC..."
    update-binfmts --enable || CODE=$?
    log_end_msg $CODE
    exit $CODE
    ;;

  stop)
    log_begin_msg "Disabling $DESC..."
    update-binfmts --disable || CODE=$?
    log_end_msg $CODE
    exit $CODE
    ;;

  restart|force-reload)
    $0 stop
    $0 start
    ;;

  *)
    N=/etc/init.d/$NAME
    echo "Usage: $N {start|stop|restart|force-reload}" >&2
    exit 1
    ;;
esac

exit 0
