#! /bin/sh

# Copyright (C) 2002, 2005, 2009, 2010 Colin Watson.
#
# This file is part of binfmt-support.
#
# binfmt-support is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; either version 3 of the License, or (at your
# option) any later version.
#
# binfmt-support is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General
# Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with binfmt-support; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA

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
