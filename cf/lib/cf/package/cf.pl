# $Id:$

use strict;

my $required = $this_vars->{required} // "";


my $osname = getos("name");
my $svc_realpkg;
if ($osname eq "rhel") {
    $svc_realpkg = get_module("yumpkg");
} elsif ($osname eq "debian") {
    $svc_realpkg = get_module("aptpkg");
} else {
    die "no package system for $osname";
}


#----
# Public operations

sub install {
    my ($o, @packages) = get_options({}, @_);
    $svc_realpkg->install(@packages);
}

sub remove {
    my ($o, @packages) = get_options({}, @_);
    $svc_realpkg->remove(@packages);
}

sub configure {
    my ($o) = get_options({}, @_);

    $svc_realpkg->configure();

    my @wanted = ();
    my @unwanted = ();
    foreach my $pkg ( split(':', $required)) {
        if ($pkg =~ /^-(.*)/) {
            # Package remove request
            push(@unwanted, $1);
        } else {
            push(@wanted, $pkg);
        }
    }
    $svc_realpkg->remove(@unwanted);
    $svc_realpkg->install(@wanted);
}

sub is_installed {
    my ($o, $pkg) = get_options({}, @_);

    return $svc_realpkg->is_installed($pkg);
}
boolean_op('is_installed');

