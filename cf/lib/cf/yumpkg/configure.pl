# $Id: yumpkg.py,v 1.12 2008-09-22 12:28:40 cvs Exp $

use strict;
use File::Basename;

my $vardir = "/var/lib/$name";
my $rpmdir = "/var/lib/rpm";
my $now = sprintf "%02d:%02d.%02d%02d%02d", 
    ((localtime)[2], (localtime)[1], (localtime)[4]+1, (localtime)[3], (localtime)[5]%100);

# Hash key by package name - value is always 1. Has entry for each installed
# package.
my %installed = ();

# Timestamp when $isntalled was collected.
my $installed_mtime = -1;

my $major_ver = getos("version");
$major_ver =~ s/([0-9]+)\.?.*/$1/;

# Define translations for rpms that have changed names across versions. Each major
# OS version has a hash mapping common name to the name used on that version.
my %rpm_map = (
    '4'=> {
	'rpmbuild'=>'rpm-build',
	'dmidecode'=>'kernel-utils',
    },
    '5'=> {
    },
);

sub RealInstall {
    my ($o, @packages) = get_options({}, @_);

    my @wanted = ();
    my @groups_wanted = ();
    my @unwanted = ();
    my @groups_unwanted = ();
    my $aide = 0;

    foreach my $pkg (@packages) {
        if ($pkg =~ /^-(.*)/) {
            # Package remove request
            $pkg = TranslatePackage($1);
            if (is_installed($pkg)) {
                if ($pkg =~ /^@(.*)/) {
                    push(@groups_unwanted, $1);
                } else {
                    push(@unwanted, $pkg);
                }
            }
        } else {
            $pkg = TranslatePackage($pkg);
            if (!is_installed($pkg)) {
                if ($pkg =~ /^@(.*)/) {
                    push(@groups_wanted, $1);
                } else {
                    push(@wanted, $pkg);
                }
            }
        }
    }

    if (scalar(@wanted) || scalar(@groups_wanted)) {
        # Get list of installed packages.
        directory(-user=>'root', -group=>'root',
                   -mode=>"755", "/var/lib/yumpkg");
        `rpm -qa > /var/lib/yumpkg/pkgs.$now`;

        $aide = check_aide();

        # !!! divert warnings about unreachable servers?
        if (scalar(@wanted)) {
            run('yum', '-y', 'install', @wanted);
        }
        if (scalar(@groups_wanted)) {
            run('yum', '-y', 'groupinstall', @groups_wanted);
        }
        if (!updating()) {
            # Fake out rpm inventory.
            foreach my $pkg (@wanted) {
                $installed{$pkg} = 1;
            }
            foreach my $pkg (@groups_wanted) {
                $installed{"\@$pkg"} = 1;
            }
        }
    }
    if (scalar(@unwanted) || scalar(@groups_unwanted)) {
        if (!$aide) {
            $aide = check_aide();
        }
        # !!! divert warnings about unreachable servers?
        if (scalar(@unwanted)) {
            run('yum', '-y', 'remove', @unwanted);
        }
        if (scalar(@groups_unwanted)) {
            run('yum', '-y', 'groupremove', @groups_unwanted);
        }
        if (!updating()) {
            # Fake out rpm inventory.
            foreach my $pkg (@unwanted) {
                delete $installed{$pkg};
            }
            foreach my $pkg (@groups_unwanted) {
                delete $installed{"\@$pkg"};
            }
        }
    }

    if ($aide && updating()) {
        # End any running `aide reinit`'s (most likely from previous yumpkg)
        my $out = read_command("ps -eo pid,cmd");
        for(split(/\n/, $out)){
            if ( $_ =~ 'aidemgr.*reinit') {
                # A reinit is in progress, end it.
                my @parts = split(' ', $_);
                Cf::Info("Gracefully ending currently running 'aide reinit'");
                kill(10, $parts[0]); # aidemgr will take it from here
            }
        }

        Cf::Info("Resetting AIDE database (background process)");
        run('-sloppy_daemon', "aidemgr --nocheck reinit &");
    }
}

#----
# Public operations

sub install {
    $this_svc->require();
    RealInstall(@_);
}

sub configure {
    $svc_account->require();
    my ($o) = get_options({}, @_);
    if ($reltag ne "__UNMANAGED") {
        BaseInstall();
    }

    # Important to start with "--" - otherwise if the first required package
    # is a negation (-PACKAGENAME) it will be interpreted as an option to
    # install.
    RealInstall('--', split(':', $required));
}

sub is_installed {
    my ($o, $pkg) = get_options({}, @_);

    $pkg = TranslatePackage($pkg);

    my $rpm_mtime =  fileinfo("$rpmdir/Packages")->mtime;
    if ($installed_mtime != $rpm_mtime) {
        # Populate installed with installed packages
        my $out = read_command('rpm', '-qa', '--qf', "%{NAME}.%{ARCH}/");
        chomp($out);
        foreach my $line (split("/", $out)) {
	    # Flag installed with the architecture suffix
            $installed{$line} = 1;

	    # Flag installed without architecture suffix too (usually
	    # packages are requested without a specific architecture).
	    $line =~ s/\.\w+$//;
            $installed{$line} = 1;
        }

        # If groups are involved see what groups are installed
        if ($required =~ '@') {
            # Populate installed with installed groups
            # prepend an '@' to protect against collisions
            if ($major_ver == 4) {
                # CentOS 4 yum doesn't have group aliases
                $out = read_command("yum grouplist 2>/dev/null");
            } else {
                $out = read_command("yum -v grouplist 2>/dev/null");
            }
            my $start = 'Installed Groups:\n';
            my $end = 'Available Groups:';
            $out =~ s/.*$start(.*)$end.*/$1/sm;
            foreach my $line (split("\n", $out)) {
                if ($major_ver == 4) {
                    $line =~ s/\s*(.*)/\@$1/;
                    $installed{$line} = 1;
                } else {
                    $line =~ s/\s*(.*) \((.*)\)/\@$1|\@$2/;
                    my @names = split '\|', $line;
                    $installed{$names[0]} = 1;
                    $installed{$names[1]} = 1;
                }
            }
        }
        $installed_mtime = $rpm_mtime;
    }

    # Return true if package list has line matching desired packages.
    return ($installed{$pkg});
}
boolean_op('is_installed');

# Returns true if aide db can be reinitialized after pkg changes are made
sub check_aide {
    # Use result from previous check if available
    my $saved_aide = $ENV{CHECK_AIDE_RESULT};
    # Check if it's both present and sane
    if ($saved_aide eq 0 || $saved_aide eq 1 ) {
        return $saved_aide;
    }

    $ENV{CHECK_AIDE_RESULT} = 0;
    if (!fileinfo("/var/lib/cf/groups")->exist()) {
        return 0;
    }
    my $out = read_file("/var/lib/cf/groups");
    if (!updating() || !is_installed("aide") || $out !~ /^aide$/m) {
        return 0;
    }

    Cf::Info("Checking for AIDE alerts before yumpkg changes. This will take a few minutes.");
    Cf::Info("running aide --check");
    `aidemgr check > /dev/null 2>&1`;
    my $exit_val = $? >> 8;
    if ($exit_val != 0) {
        return 0;
    }
    $ENV{CHECK_AIDE_RESULT} = 1;
    return 1;
}

#--------
# Private routine

sub TranslatePackage($) {
    my ($pkg) = @_;

    my $newpkg = $rpm_map{$major_ver}->{$pkg} || $pkg;
    return $newpkg;
}

sub BaseInstall {
    copy(-user=>"root", -mode=>"644", '-newtime',
        "$this_dir/$environ-default/yum.conf",
        "/etc/yum.conf");

    copy(-user=>"root", -mode=>"644", -recurse=>1, '-newtime',
        "$this_dir/rpm-gpg",
        "/etc/pki/rpm-gpg");

    my $initial = changes();

    # Set release tag in repo files:
    # Since the repo files on cf with "<reltag>" in them are not going to
    # match the files on the host, they must be altered prior to copying
    # (writing) them so that they are not continually re-transferred.
    foreach my $file (<$this_dir/$environ-default/yum.repos.d/*>) {
        if (-f $file) { # it should always be, but check anyways
            my $body = read_file($file);
            $reltag = quotemeta($reltag); # prevent a very unlikely crash
            $body =~ s/<reltag>/$reltag/g;
            my $basename = basename($file);
            writefile('-follow', -user=>"root", -mode=>"644",
                "/etc/yum.repos.d/$basename", $body);
        }
    }

    # do the same as above for the plugin configuration files
    foreach my $file (<$this_dir/$environ-default/pluginconf.d/*>) {
        if (-f $file) { # it should always be, but check anyways
            my $body = read_file($file);
            $reltag = quotemeta($reltag); # prevent a very unlikely crash
            $body =~ s/<reltag>/$reltag/g;
            my $basename = basename($file);
            writefile('-follow', -user=>"root", -mode=>"644",
                "/etc/yum/pluginconf.d/$basename", $body);
        }
    }

    if (changes($initial)) {
       run("yum clean all");
    }
}
