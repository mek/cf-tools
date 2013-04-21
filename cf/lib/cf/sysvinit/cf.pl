#
# $Id: configure.pl,v 1.11 2008-01-30 02:25:45 cvs Exp $

use strict;

my $services = $this_vars->{services} // "";
my $services_nostart = $this_vars->{services_nostart} // "";

my $os_class = getos('class');

# Determine location of init scripts
my $rcbase = "/etc";
foreach my $dir ("/etc/rc.d") {
    if (fileinfo(-follow, "$dir/init.d")->type eq 'DIR') {
	$rcbase = $dir;
    }
}

# List of all (possible) rc directories (some may not exist on this OS).
my @rcdirs = ();
foreach my $level (0..6, 'S') {
    push(@rcdirs, "$rcbase/rc$level.d");
}

#-------
# Public Methods

sub configure {
    foreach my $service (split(" ", $services)) {
	if ($service =~ /^-(.*)/) {
	    # Service prefixed with "-" - disable the service
	    $service = $1;
	    disable($service);
	} else {
	    enable($service);
	}
    }
    foreach my $service (split(" ", $services_nostart)) {
	enable(-autostart=>0, $service);
    }
}

# Perform a graceful restart of a service. The init script must support the
# "graceful" argument.
sub graceful {
    my ($o, $service) = get_options({}, @_);
    my $script = get_script($service);
    my $rh = is_redhat($script);

    # If service isnt running just return
    return if ($rh && !get_status($script));

    run($script, "graceful");
}


sub reload {
    my ($o, $service) = get_options({}, @_);
    resomething($service, "reload");
}

sub restart {
    my ($o, $service) = get_options({}, @_);
    resomething($service, "restart");
}


sub start {
    my ($o, $service) = get_options({}, @_);
    my $script = get_script($service);
    my $rh = is_redhat($script);

    return if ($rh && get_status($script));
    run($script, "start");
    die "can't start $service\n" if ($rh && !get_status($script));
}

sub stop {
    my ($o, $service) = get_options({}, @_);
    my $script = get_script($service);
    my $rh = is_redhat($script);

    return if ($rh && !get_status($script));
    eval { run($script, "stop"); };
    die "can't stop $service\n" if ($rh && get_status($script));
}

sub status {
    my ($o, $service) = get_options({}, @_);
    my $script = get_script($service);
    return get_status($script);
}
boolean_op('status');

# Disable daemon startup and stop right now (unless -letrun option
# specified).
my %disable_opts = (
    LETRUN => '',
);
sub disable {
    my ($o, $service) = get_options(\%disable_opts, @_);
    my $script = get_script($service);

    my $prelink = changes();

    # Remove links
    tidy(-recurse=>1, -follow, -i=>"[KS]??$service", @rcdirs);

    return if ($o->{LETRUN});

    # Check if daemon is running now.
    if (is_redhat($script)) {
	# stop if status succeeds
	run($script, 'stop') if get_status($script);
    } else {
	# Can't get status so try stop if we modified any links - it may
	# fail.
	eval { run($script, 'stop'); } if (changes() != $prelink);
    }
}

# Enable daemon at system boot, and make sure it is running right now.
my %enable_opts = (
    SCRIPT => \&parse_string,
    RESTART => '',
    STARTNUM => \&parse_int,
    KILLNUM => \&parse_int,
    AUTOSTART => \&parse_bool,
);
sub enable {
    my ($o, $service) = get_options(\%enable_opts, @_);
    my $script = get_script($service);
    my $status_script = $script;
    my $src = $o->{SCRIPT};
    my $autostart = defined $o->{AUTOSTART} ? $o->{AUTOSTART} : 1;

    # Install script
    if (!defined $src) {
	# Get source file name by replacing any .* suffix in service name
	# with ".init"
	my $srcbase = $service;
	$srcbase =~ s/\..*//;
	$srcbase .= ".init";

	foreach my $srcdir ($this_dir, "/opt/our/script/bin") {
	    if (fileinfo("$srcdir/$srcbase")->type ne 'NONE') {
		$src = "$srcdir/$srcbase";
		last;
	    }
	}
    }

    if (defined $src && length($src)) {
	copy(-mode=>'0755', $src, $script);

	# If this is a dry run, use the source script for status
	$status_script = $src if !updating();
    } elsif (fileinfo($script)->type eq 'NONE') {
	die "can't find script for $service\n";
    }

    # Install links
    my $startnum = get_startnum($script, $o->{STARTNUM});
    my $killnum = get_killnum($script, $o->{KILLNUM});
    # !!! get start level too?
    my $prelink = changes();
    if ($os_class eq 'linux') {
	# Linux wants a link in each run level
	setlink(0, "K$killnum", $service);
	setlink(1, "K$killnum", $service);
	setlink(2, "S$startnum", $service);
	setlink(3, "S$startnum", $service);
	setlink(4, "S$startnum", $service);
	setlink(5, "S$startnum", $service);
	setlink(6, "K$startnum", $service);
    } else {
	# Traditional sysv only wants a start link in one run level - but
	# kill in multiple.

	setlink(0, "K$killnum", $service);
	setlink(1, "K$killnum", $service);
	setlink('S', "K$killnum", $service);

	setlink(2, "S$startnum", $service);
	setlink(3, "-", $service);
	# !!! support other startlevels? - for 3:
	# setlink 2 K$killnum $service
	# setlink 3 S$startnum $service
    }

    return if !$autostart;

    if ($o->{RESTART}) {
	# Don't worry about checking current status - we need a restart
	# anyway
	resomething($service, "restart");
    } else {
	# Check if daemon is running now.
	my $needstart;
	if (is_redhat($status_script)) {
	    # start if status fails
	    run($script, 'start') unless get_status($status_script);
	} else {
	    # Can't get status so try start if we modified any links - it may
	    # fail.
	    eval { run($script, 'start'); } if (changes() != $prelink);
	}
    }
}


#--------
# Internals


sub get_script($) {
    my ($service) = @_;
    return "$rcbase/init.d/$service";
}

# Fix links for service in a single run-level
sub setlink($$$) {
    my ($level, $prefix, $service) = @_;

    # Don't do anything if the rc directory does not exist (assume this
    # runlevel is not supported on this OS).
    return if fileinfo("$rcbase/rc$level.d")->type eq 'NONE';

    if ($prefix ne "-") {
	makelink("../init.d/$service", "$rcbase/rc$level.d/$prefix$service");
    }
    tidy(-recurse=>1, -follow,
	    -exclude=>"$prefix$service",
	    -include=>"???$service",
	    "$rcbase/rc$level.d"
	    );
}

my %smart = ();
my %rhstart = ();
my %rhkill = ();

# Check is init script follows redhat extended style (supports args like
# status and restart).
sub is_redhat($) {
    my ($script) = @_;
    if (!defined $smart{$script}) {
	my $smart = 0;

	# If script exists check contents to see if it understands the
	# redhat/linux extended ops (like status).
	if (fileinfo(-follow, "$script")->type ne 'NONE') {
	    open(FILE, "<$script") or die $!;
	    while(<FILE>) {
		next if /^\s*$/;	# Ignore empty lines
		last unless /^#/;	# Stop at end of initial comments
		if (/^#\s*chkconfig:\s*(\S+)\s+(\S+)\s+(\S+)/) {
		    $smart = 1;
		    $rhstart{$script} = $2;
		    $rhkill{$script} = $3;
		    debug("$script is a redhat-style init script");
		    last;
		}
	    }
	    close(FILE) or die $!;
	}
	$smart{$script} = $smart;
    }
    return $smart{$script};
}

sub get_startnum($;$) {
    my ($script, $num) = @_;

    return sprintf("%02d", $num) if defined $num;
    is_redhat($script);
    return $rhstart{$script} if defined $rhstart{$script};
    return "99";
}

sub get_killnum($;$) {
    my ($script, $num) = @_;

    return sprintf("%02d", $num) if defined $num;
    is_redhat($script);
    return $rhkill{$script} if defined $rhkill{$script};
    return "01";
}

sub resomething($$) {
    my ($service, $op) = @_;
    my $script = get_script($service);
    if (is_redhat($script)) {
	run($script, $op);
    } else {
	eval { run($script, "stop"); };
	run($script, "start");
    }
}

sub get_status($) {
    my ($script) = @_;
    die "$script doesn't support status checking\n" unless is_redhat($script);
    eval { read_command($script, "status") };
    return $@ ? 0 : 1;
}

