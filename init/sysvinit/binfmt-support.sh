#! /bin/sh

# This is a simple generic SysV init script.  It may need adjustments for
# distribution policies, for example logging and LSB information.

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
NAME=binfmt-support
DESC="additional executable binary formats"

if [ "$(uname)" != Linux ]; then
  exit 0
fi

which update-binfmts >/dev/null 2>&1 || exit 0

set -e
CODE=0

case "$1" in
  start)
    echo -n "Enabling $DESC: "
    update-binfmts --enable || CODE=$?
    echo "$NAME."
    exit $CODE
    ;;

  stop)
    echo -n "Disabling $DESC: "
    update-binfmts --disable || CODE=$?
    echo "$NAME."
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
