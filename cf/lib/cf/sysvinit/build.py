"""Rc (boot manager) service using system-V init scripts

$Id: build.py,v 1.18 2008-10-27 18:29:35 cvs Exp $
"""

from cfbuild import *
import string
class Service(DaemonService):
    """System V implementation of Daemon service
    """

    names = ('sysvinit', )

    parms = RecordParm(fields=make_map(
	service = RecordParm(repeatable=1, fields=make_map(
	    # Service name (name of the init script)
	    name = StringParm(required=1),

	    # Command to start the service
	    server_cmd = StringParm(required=1),

	    # Command to top the server (if blank, kill to stop)
	    stop_cmd = StringParm(default=""),

	    # Command to run after stopping the server (for extra clean up
	    # after kill).
	    stop_cmd2 = StringParm(default=""),

	    # Command to reload the service
	    reload_cmd = StringParm(default=""),

	    # Name of process - as seen in "ps -e"
	    procname = StringParm(default=""),

	    # User to run server as
	    user = StringParm(required=1),

	    # Where to direct std out/err (otherwise /dev/null)
	    logfile = StringParm(default=""),

	    # Doe the server_cmd fork itself? (if 0, init script will do
	    # the fork).
	    forks = BooleanParm(),

	    # Where pid file is kept (process with pid of current server)
	    pidfile = StringParm(),

	    # Should the init script generated the pid file?
	    write_pid = BooleanParm(),

	    # Signal to cause service reload - if not specified, reload is
	    # same as restart.
	    reload_signal = StringParm(default=""),

            # Delay between stopping and starting.  Java apps take a long time to shutdown.
            restart_delay = StringParm(),

	    # Environment settings for server_cmd
	    environ = RecordParm(repeatable=1, fields=make_map(
		name = StringParm(required=1),
		value = StringParm(required=1),
		)),
	    )),
        ))

    hostparms = RecordParm(repeatable=1, fields=make_map(
        service = StringParm(required=1),
        autostart = BooleanParm(default=1),
	))

    def get_script(self, service, user, procname, server_cmd, environ, forks,
	    stop_cmd, stop_cmd2, reload_cmd, stop_signal, reload_signal,
	    pidfile, write_pid, logfile, startnum, killnum, rc2, lockdir,
	    restart_delay,
	    ):
	"""Generate contents of init script based on options provided
	"""

	bg=""
	levels = "345"

	if rc2:
	    levels = "2345"

	envs=""
	for name, value in environ.items():
	    if value is None:
		envs += "unset %(name)s || xx=1 \n" % vars()
	    else:
		envs += "%(name)s='%(value)s'; export %(name)s\n" % vars()

	return _script_template % vars()

    def add_daemon(self, service, user,
	    init_contents=None,
	    procname="",
	    server_cmd=None,
	    environ={},
	    forks=0,
	    stop_cmd="",
	    stop_cmd2="",
	    reload_cmd="",
	    stop_signal="TERM",
	    reload_signal="HUP",
	    pidfile=None,
	    write_pid=0,
	    logfile="/dev/null",
	    startnum=99,
	    killnum=None,
	    rc2=0,
	    lockdir="/var/lock/subsys",
	    restart_delay="0",
	    ):
	"""Add rules to start server software at boot ... and now.
	"""

	# Set missing arguments to default
	if restart_delay is None:
	    restart_delay = 0
	if killnum is None:
	    killnum = 100 - startnum
	if pidfile is None:
	    pidfile = "/var/run/"+service+".pid"

	if init_contents is None:
	    init_contents = self.get_script(service, user,
		    procname, server_cmd, environ, forks,
		    stop_cmd, stop_cmd2, reload_cmd,
		    stop_signal, reload_signal,
		    pidfile, write_pid, logfile, startnum, killnum, rc2,
		    lockdir, restart_delay,
		    )

	self.add_file(service+".init", init_contents, executable=1)

    def assemble(self):
	"""Generate core configuration for service"""

	sitevars = self.auto_sitevars(
		services="",
		services_nostart="",
		)

	self.copy("configure.pl")

	for svcrec in self.args.service:
	    env = {}
	    for envrec in svcrec.environ:
		env[envrec.name] = envrec.value
	    self.add_daemon(svcrec.name, svcrec.user,
		    server_cmd = svcrec.server_cmd,
		    stop_cmd = svcrec.stop_cmd,
		    stop_cmd2 = svcrec.stop_cmd2,
		    reload_cmd = svcrec.reload_cmd,
		    procname = svcrec.procname,
		    forks = svcrec.forks,
		    write_pid = svcrec.write_pid,
		    reload_signal = svcrec.reload_signal,
		    logfile = svcrec.logfile,
		    pidfile = svcrec.pidfile,
                    restart_delay = svcrec.restart_delay,
		    environ = env
		    )

	for host, hargs in self.host_args.items():
	    hostvars = {}
	    services = []
	    services_nostart = []
	    for harg in hargs:
		svc = harg.service
		if harg.autostart:
		    services.append(svc)
		else:
		    services_nostart.append(svc)
	    hostvars["services"] = " ".join(services)
	    hostvars["services_nostart"] = " ".join(services_nostart)
	    self.set_hostvars(host, hostvars)


_script_template = """#!/bin/sh
#
# chkconfig: %(levels)s %(startnum)2.2d %(killnum)2.2d
# description: %(service)s

set -e

name="%(service)s"
procname="%(procname)s" # as seen in "ps -e"
server_cmd="%(server_cmd)s"
forks="%(forks)s"
stop_cmd="%(stop_cmd)s"
stop_cmd2="%(stop_cmd2)s"	# Also run this after kill server
reload_cmd="%(reload_cmd)s"
stop_signal="%(stop_signal)s"
reload_signal="%(reload_signal)s"
pidfile="%(pidfile)s"
write_pid="%(write_pid)s"
logfile="%(logfile)s"
lockdir="%(lockdir)s"
user="%(user)s"
restart_delay="%(restart_delay)s"
start_wait=10
stop_wait=10

%(envs)s

start() {
    # verify it isn't running already
    proccmd checkprocs && return

    cmd="$server_cmd"

    # See if we need to change users
    me=`id | sed 's/[^(]*(//;s/).*//'`
    if [ "$me" != "$user" ]
    then
	su=su
	if su --help 2>/dev/null | grep -- --shell >/dev/null
	then
	    su="$su --shell /bin/sh"
	fi
	cmd="$su $user -c '$cmd'"
    fi

    cd /
    trap "" HUP
    cmd="$cmd </dev/null"
    test -z "$logfile" || cmd="$cmd >$logfile 2>&1"
    test "$forks" = "0" && cmd="$cmd &"

    eval "$cmd"
    pid=$!
    test "$write_pid" = "1" && echo $pid >$pidfile

    # wait for start up
    rc=0
    i=0
    while [ $i -lt $start_wait ]
    do
	rc=0
	proccmd checkprocs && break
	rc=1
	sleep 1
	i=`expr $i + 1`
    done

    # redhat compatibility - needed?
    test -d "$lockdir" && touch "$lockdir/$name" || true
    return $rc
}

stop() {
    test -d "$lockdir" && rm -f "$lockdir/$name"
    if [ -z "$stop_cmd" ]
    then
	proccmd "kill -$stop_signal" || return 1
    else
	eval $stop_cmd || return 1
    fi
    if [ ! -z "$stop_cmd2" ]
    then
	eval $stop_cmd2 || return 1
    fi

    # wait for stop
    rc=0
    i=0
    while [ $i -lt $stop_wait ]
    do
	rc=0
	proccmd checkprocs || break
	rc=1
	sleep 1
	i=`expr $i + 1`
    done
    return $rc
}

reload() {
    if [ ! -z "$reload_cmd" ]
    then
	eval $reload_cmd && return
    elif [ ! -z "$reload_signal" ]
    then
	proccmd "kill -$reload_signal" && return
    fi
    restart
}

restart() {
    stop || true
    sleep $restart_delay
    start
}

checked_pids=""
checkprocs() {
    checked_pids="$*"
    kill -0 $* 2>/dev/null || return 1
}

status() {
    if proccmd checkprocs
    then
	echo "$name running: $checked_pids"
	return 0
    else
	echo "$name stopped"
	return 1
    fi
}

# Run command appending PIDs of all named processes.
# !Important! Do not redirect I/O when calling this proccmd - that will
# spawn another init script process that will likely be mistaken for the
# server process.

proccmd() {
    cmd=$1

    # First check for PID file.

    if [ -f "$pidfile" ]
    then
	pids=`head -1 "$pidfile"`
	if [ "$pids" != "" ]
	then
	    for pid in $pids
	    do
		$cmd $pid || return 1
	    done
	    return 0
	fi
    fi

    # Fall back to searching ps output - careful not to count myself.
    if [ "$procname" = "" ]
    then
	# No name to search for
	return 1
    fi

    if [ "$user" = "root" ]
    then
	# Process might have changed to any user - search them all
	psopts="-e"
    else
	psopts="-u $user"
    fi
    pids=""
    for pid in `ps $psopts | grep -w $procname | sed -e 's/^  *//' -e 's/ .*//'`
    do
	if [ "$pid" != "$$" ]
	then
	    # Not me
	    if kill -0 $pid 2>/dev/null
	    then
		# Not a temporary process
		pids="$pids $pid"
	    fi
	fi
    done
    if [ "$pids" != "" ]
    then
	$cmd $pids && return 0
    fi

    return 1
}

case "$1" in
start|stop|restart|reload|status)
    $1
    ;;
*)
    echo "Usage: $0 start|stop|restart|reload|status" 1>&2
    exit 1
    ;;
esac
"""

