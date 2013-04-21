# $Id:$

use strict;
use File::Basename;

my $name = $this_vars->{name} // "aptpkg";
my $required = $this_vars->{required} // "";
my $reltag = $this_vars->{reltag} // "__UNMANAGED";
my $vardir = "/var/lib/$name";
my $dpkgdir = "/var/lib/dpkg";
my $now = sprintf "%02d:%02d.%02d%02d%02d", 
    ((localtime)[2], (localtime)[1], (localtime)[4]+1, (localtime)[3], (localtime)[5]%100);

# Hash key by package name - value is always 1. Has entry for each installed
# package.
my %installed = ();

# Timestamp when $isntalled was collected.
my $installed_mtime = -1;

#----
# Public operations

sub install {
    my ($o, @packages) = get_options({}, @_);

    my @wanted = ();
    my @unwanted = ();

    foreach my $pkg (@packages) {
	if ($pkg =~ /^-(.*)/) {
	    # Package remove request
	    $pkg = $1;
	    if (is_installed($pkg)) {
		push(@unwanted, $1);
	    }
	} else {
	    if (!is_installed($pkg)) {
		push(@wanted, $pkg);
	    }
	}
    }

    if (scalar(@wanted)) {
      # Get list of installed packages.
      # `dpkg -l | awk '{ print $2,"-",$3 }' > $vardir/pkgs.$now`;

	# !!! divert warnings about unreachable servers?
	run('apt-get', '-y', 'install', @wanted);
	if (!updating()) {
	    foreach my $pkg (@wanted) {
		$installed{$pkg} = 1;
	    }
	}
    }
    if (scalar(@unwanted)) {
	# !!! divert warnings about unreachable servers?
	run('apt-get', '-y', '--purge', 'remove', @unwanted);
	run('apt-get', '-y', 'autoremove');
	run('apt-get', '-y', 'clean');
	if (!updating()) {
	    foreach my $pkg (@unwanted) {
		delete $installed{$pkg};
	    }
	}
    }

}

sub configure {
    my ($o) = get_options({}, @_);
    if ($reltag ne "__UNMANAGED") {
        baseInstall();
    }
    install('--', split(':', $required));
}

sub is_installed {
    my ($o, $pkg) = get_options({}, @_);

    my $dpkg_mtime =  fileinfo("$dpkgdir/status")->mtime;
    if ($installed_mtime != $dpkg_mtime) {
	my $out = read_command('dpkg', '-l', '\*', '|', 'grep', "'^ii'", '|', 'awk', '\'{ print $2 }\'');
	chomp($out);
	foreach my $line (split("\n", $out)) {
	    $installed{$line} = 1;
	}
	$installed_mtime = $dpkg_mtime;
    }

    # Return true if package list has line matching desired packages.
    return ($installed{$pkg});
}
boolean_op('is_installed');

sub baseInstall {
    my $initial = changes();

    copy(-user=>"root", -mode=>"644", '-newtime',
        "$this_dir/sources.list",
        "/etc/apt/sources.list");

    if (changes($initial)) {
       run('apt-get', 'clean');
       run('apt-get', 'update');
    }
}

